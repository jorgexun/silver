import Foundation

/// Persists sandbox access to user-chosen folders across launches.
enum Bookmarks {
    static let libraryFolderKey = "LibraryFolderBookmark"
    static let exportFolderKey = "ExportFolderBookmark"

    static func save(_ url: URL, forKey key: String) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Resolves the bookmark and starts accessing it. Callers balance with `stopAccessingSecurityScopedResource()`.
    static func resolve(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        if isStale { save(url, forKey: key) }
        return url
    }
}
