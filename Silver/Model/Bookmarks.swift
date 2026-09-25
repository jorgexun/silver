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
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else { return nil }
        return (url, isStale)
    }

    /// The location a bookmark points to, read without resolving it (works while its volume is offline).
    static func location(of data: Data) -> URL? {
        let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)
        return values?.path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func save(_ url: URL, forKey key: String) {
        guard let data = data(for: url) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Returns nil while the location is unavailable (e.g. its drive is disconnected); the
    /// bookmark is kept so a later call can succeed.
    static func resolve(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let (url, isStale) = resolve(data)
        else { return nil }
        if isStale { save(url, forKey: key) }
        return url
    }
}
