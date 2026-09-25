import Foundation

/// Reads and writes `.edit.json` sidecar files next to the originals.
nonisolated enum Sidecar {
    static let suffix = ".edit.json"

    /// `L1001234.DNG` → `L1001234.edit.json`.
    /// When a DNG and a JPG share a base name (RAW+JPG shooting), the DNG keeps the short
    /// name and the other file uses `L1001234.JPG.edit.json`.
    static func url(for photoURL: URL, in folderFiles: [URL]) -> URL {
        let base = photoURL.deletingPathExtension().lastPathComponent
        let siblings = folderFiles.filter {
            $0 != photoURL && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(base) == .orderedSame
        }
        let ownsShortName = siblings.isEmpty || (PhotoFile.isRaw(photoURL) && !siblings.contains(where: { PhotoFile.isRaw($0) }))
        let name = ownsShortName ? base + suffix : photoURL.lastPathComponent + suffix
        return photoURL.deletingLastPathComponent().appendingPathComponent(name)
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
