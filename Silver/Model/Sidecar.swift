import Foundation

/// Reads and writes `.edit.json` sidecar files next to the originals.
nonisolated enum Sidecar {
    static let suffix = ".edit.json"

    /// The sidecar of each photo in a folder, in the same order: `L1001234.DNG` → `L1001234.edit.json`.
    /// When a DNG and a JPG share a base name (RAW+JPG shooting), the DNG keeps the short
    /// name and the other file uses `L1001234.JPG.edit.json`. A long name in `existing` (the folder's
    /// file names, lowercased) is kept, so a JPG keeps its edits while its DNG is in the Trash.
    static func urls(for folderFiles: [URL], existing: Set<String>) -> [URL] {
        // Grouped by base name: comparing every photo with every other took 4.4 s for 2,000 photos.
        let groups = Dictionary(grouping: folderFiles) { $0.deletingPathExtension().lastPathComponent.lowercased() }
        return folderFiles.map { photoURL in
            let base = photoURL.deletingPathExtension().lastPathComponent
            let siblings = groups[base.lowercased(), default: []].filter { $0 != photoURL }
            let longName = photoURL.lastPathComponent + suffix
            let ownsShortName = !existing.contains(longName.lowercased())
                && (siblings.isEmpty || (PhotoFile.isRaw(photoURL) && !siblings.contains(where: { PhotoFile.isRaw($0) })))
            return photoURL.deletingLastPathComponent().appendingPathComponent(ownsShortName ? base + suffix : longName)
        }
    }

    static func load(from url: URL) -> EditSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditSettings.self, from: data)
    }

    /// Writes the settings, or removes the sidecar when the settings are back to default.
    static func save(_ settings: EditSettings, to url: URL) throws {
        if settings.isDefault {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
