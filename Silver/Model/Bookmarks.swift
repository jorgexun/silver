import Foundation

/// Persists sandbox access to user-chosen folders across launches.
enum Bookmarks {
    static let exportFolderKey = "ExportFolderBookmark"
    /// Single library folder used before the sidebar existed; migrated into the source folder list.
    static let legacyLibraryFolderKey = "LibraryFolderBookmark"

    static func data(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves bookmark data and starts accessing it. Callers balance with `stopAccessingSecurityScopedResource()`.
    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else { return nil }
        return (url, isStale)
    }

    static func save(_ url: URL, forKey key: String) {
        guard let data = data(for: url) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func resolve(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard let (url, isStale) = resolve(data) else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        if isStale { save(url, forKey: key) }
        return url
    }
}
