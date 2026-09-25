import Foundation
import Observation

/// A folder in the sidebar tree. Subfolders are listed lazily when the folder is first expanded.
@Observable
final class FolderNode: Identifiable {
    let url: URL
    let name: String
    let hasSubfolders: Bool
    /// False for a root whose volume is not connected; it stays in the sidebar until it returns.
    let isAvailable: Bool
    var children: [FolderNode]?
    var isExpanded = false

    var id: URL { url }

    init(url: URL, hasSubfolders: Bool, isAvailable: Bool = true) {
        self.url = url
        self.name = isAvailable ? FileManager.default.displayName(atPath: url.path) : url.lastPathComponent
        self.hasSubfolders = hasSubfolders
        self.isAvailable = isAvailable
    }
}

/// Root folders added by the user, with persisted sandbox access and expansion state.
@Observable
final class SourceFolders {
    struct Row: Identifiable {
        let node: FolderNode
        let depth: Int
        let isRoot: Bool
        var id: URL { node.url }
    }

    private(set) var roots: [FolderNode] = []
    private var bookmarks: [URL: Data] = [:]
    private var expandedPaths: Set<String>

    private static let bookmarksKey = "SourceFolderBookmarks"
    private static let expandedKey = "ExpandedFolderPaths"

    init() {
        expandedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
    }

    /// Visible rows in display order: roots and the subfolders of expanded folders.
    var rows: [Row] {
        var result: [Row] = []
        func append(_ nodes: [FolderNode], depth: Int) {
            for node in nodes {
                result.append(Row(node: node, depth: depth, isRoot: depth == 0))
                if node.isExpanded, let children = node.children {
                    append(children, depth: depth + 1)
                }
            }
        }
        append(roots, depth: 0)
        return result
    }

    // MARK: - Roots

    /// Resolves saved bookmarks and starts accessing them. Folders that can't be reached
    /// (e.g. on a disconnected drive) are kept as unavailable roots.
    func restore() {
        var saved = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        if saved.isEmpty, let legacy = UserDefaults.standard.data(forKey: Bookmarks.legacyLibraryFolderKey) {
            saved = [legacy]
            UserDefaults.standard.removeObject(forKey: Bookmarks.legacyLibraryFolderKey)
        }
        for data in saved {
            if let (url, isStale) = Bookmarks.resolve(data) {
                let key = Self.normalized(url)
                guard bookmarks[key] == nil else { continue }
                bookmarks[key] = isStale ? (Bookmarks.data(for: url) ?? data) : data
                roots.append(makeNode(key))
            } else if let location = Bookmarks.location(of: data) {
                let key = Self.normalized(location)
                guard bookmarks[key] == nil else { continue }
                bookmarks[key] = data
                roots.append(FolderNode(url: key, hasSubfolders: false, isAvailable: false))
            }
        }
        saveBookmarks()
        roots.forEach(restoreExpansion)
    }

    /// Re-checks roots after volumes are mounted or ejected. Returns true if any root changed.
    @discardableResult
    func refreshAvailability() -> Bool {
        var changed = false
        for (index, root) in roots.enumerated() {
            if root.isAvailable {
                guard !FileManager.default.fileExists(atPath: root.url.path) else { continue }
                root.url.stopAccessingSecurityScopedResource()
                roots[index] = FolderNode(url: root.url, hasSubfolders: false, isAvailable: false)
                changed = true
            } else if let data = bookmarks[root.url], let (url, isStale) = Bookmarks.resolve(data) {
                if isStale, let fresh = Bookmarks.data(for: url) { bookmarks[root.url] = fresh }
                let node = makeNode(root.url)
                roots[index] = node
                restoreExpansion(of: node)
                changed = true
            }
        }
        if changed { saveBookmarks() }
        return changed
    }

    /// Adds folders chosen by the user. Returns the added (or already present) roots.
    @discardableResult
    func add(_ urls: [URL]) -> [URL] {
        var added: [URL] = []
        for url in urls {
            let key = Self.normalized(url)
            added.append(key)
            let existing = roots.firstIndex { $0.url == key }
            guard existing.map({ !roots[$0].isAvailable }) ?? true, let data = Bookmarks.data(for: url) else { continue }
            bookmarks[key] = data
            if let existing {
                roots[existing] = makeNode(key)  // Re-added while it was shown as unavailable.
            } else {
                roots.append(makeNode(key))
            }
        }
        roots.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        saveBookmarks()
        return added
    }

    func remove(_ root: FolderNode) {
        roots.removeAll { $0 === root }
        bookmarks[root.url] = nil
        if root.isAvailable { root.url.stopAccessingSecurityScopedResource() }
        expandedPaths = expandedPaths.filter { !Self.url(URL(fileURLWithPath: $0), isInside: root.url) }
        saveBookmarks()
        saveExpansion()
    }

    func root(containing url: URL) -> FolderNode? {
        roots.first { Self.url(url, isInside: $0.url) }
    }

    /// Canonical form used for identity: standardized, no trailing slash differences.
    nonisolated static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    static func url(_ url: URL, isInside folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        return path == folderPath || path.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
    }

    // MARK: - Expansion

    func setExpanded(_ node: FolderNode, _ expanded: Bool) {
        guard node.isAvailable else { return }
        node.isExpanded = expanded
        if expanded {
            expandedPaths.insert(node.url.path)
            loadChildren(of: node)
        } else {
            expandedPaths.remove(node.url.path)
        }
        saveExpansion()
    }

    /// Expands the ancestors of `url` so it is visible in the sidebar.
    func reveal(_ url: URL) {
        guard let root = root(containing: url), root.isAvailable else { return }
        let target = Self.normalized(url)
        Task {
            var node = root
            while node.url != target {
                if !node.isExpanded { setExpanded(node, true) }
                if node.children == nil { await loadChildrenNow(of: node) }
                guard let next = node.children?.first(where: { Self.url(target, isInside: $0.url) }) else { return }
                node = next
            }
        }
    }

    /// Relists the subfolders of `node`, keeping the expansion state of those that still exist.
    func refresh(_ node: FolderNode) {
        guard node.children != nil else { return }
        Task { await loadChildrenNow(of: node) }
    }

    private func restoreExpansion(of node: FolderNode) {
        guard node.isAvailable, expandedPaths.contains(node.url.path) else { return }
        node.isExpanded = true
        loadChildren(of: node)
    }

    private func loadChildren(of node: FolderNode) {
        guard node.children == nil else { return }
        Task { await loadChildrenNow(of: node) }
    }

    private func loadChildrenNow(of node: FolderNode) async {
        let url = node.url
        let listing = await Task.detached(priority: .userInitiated) { Self.subfolders(of: url) }.value
        let existing = Dictionary((node.children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        node.children = listing.map { entry in
            if let old = existing[entry.url], old.hasSubfolders == entry.hasSubfolders { return old }
            return FolderNode(url: entry.url, hasSubfolders: entry.hasSubfolders)
        }
        node.children?.forEach(restoreExpansion)
    }

    private func makeNode(_ url: URL) -> FolderNode {
        FolderNode(url: url, hasSubfolders: !Self.subfolderURLs(of: url).isEmpty)
    }

    // MARK: - File system

    nonisolated private struct Entry: Sendable {
        let url: URL
        let hasSubfolders: Bool
    }

    nonisolated private static func subfolders(of url: URL) -> [Entry] {
        subfolderURLs(of: url).map { Entry(url: $0, hasSubfolders: !subfolderURLs(of: $0).isEmpty) }
    }

    /// Visible, non-package subdirectories sorted by name.
    nonisolated private static func subfolderURLs(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return contents
            .filter { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .map { normalized($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Persistence

    private func saveBookmarks() {
        let data = roots.compactMap { bookmarks[$0.url] }
        UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
    }

    private func saveExpansion() {
        UserDefaults.standard.set(Array(expandedPaths), forKey: Self.expandedKey)
    }
}
