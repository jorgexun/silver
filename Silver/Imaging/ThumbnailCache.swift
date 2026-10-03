import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails kept on disk between launches, as Lightroom keeps its previews. Without it, every
/// folder opened shows the camera's previews and then re-renders each edited photo, about 0.9 s
/// apiece for M11 files; with it, a folder shows its thumbnails as last seen at once.
///
/// One entry per photo, keyed by its path, size and modification date. An entry holds the
/// settings it was rendered with (the default ones for the camera's preview), so a stale entry
/// is recognized and can stand in until the new render is done.
nonisolated enum ThumbnailCache {
    /// Bump when a rendering change alters how edited photos look, so cached renders aren't reused.
    static let version = 1
    /// Least recently written entries are removed beyond this size.
    static let sizeLimit = 512 * 1024 * 1024

    struct Entry {
        let image: CGImage
        let settings: EditSettings
    }

    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func fileURL(for photoURL: URL) -> URL? {
        guard let directory,
              let values = try? photoURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate
        else { return nil }
        let key = "\(version)\n\(photoURL.standardizedFileURL.path)\n\(size)\n\(date.timeIntervalSinceReferenceDate)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg")
    }

    /// The cached thumbnail of `photoURL`, decoded the way rendered thumbnails are, in sRGB BGRA.
    static func load(for photoURL: URL) -> Entry? {
        guard let url = fileURL(for: photoURL),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let json = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String,
              let settings = try? JSONDecoder().decode(EditSettings.self, from: Data(json.utf8)),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let image = Thumbnails.displayReady(jpeg, colorSpace: ImagePipeline.sRGB)
        else { return nil }
        return Entry(image: image, settings: settings)
    }

    /// Writes a JPEG with the settings it shows as its EXIF user comment. (A TIFF image description
    /// comes back from ImageIO as an IPTC caption instead.)
    static func store(_ image: CGImage, settings: EditSettings, for photoURL: URL) {
        let data = NSMutableData()
        guard let url = fileURL(for: photoURL),
              let json = (try? JSONEncoder().encode(settings)).flatMap({ String(data: $0, encoding: .utf8) }),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: json],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        // Atomically, so a load at the same time never reads half a file.
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }

    /// Removes the least recently written entries once the cache is over `sizeLimit`.
    static func prune() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.totalFileAllocatedSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > sizeLimit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > sizeLimit * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
