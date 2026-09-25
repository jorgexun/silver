import CoreGraphics
import Foundation
import Observation

@Observable
final class Photo: Identifiable {
    let url: URL
    let sidecarURL: URL
    var settings: EditSettings
    var thumbnail: CGImage?
    var metadata: PhotoMetadata?
    /// Oriented size of the developed image, used for crop geometry.
    var imageSize: CGSize?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isRaw: Bool { PhotoFile.isRaw(url) }
    var isEdited: Bool { !settings.isDefault }

    /// Size used by the crop tool; falls back to metadata and then to the thumbnail.
    var geometrySize: CGSize? {
        if let imageSize { return imageSize }
        if let size = metadata?.pixelSize { return size }
        if let thumbnail { return CGSize(width: thumbnail.width, height: thumbnail.height) }
        return nil
    }

    init(url: URL, sidecarURL: URL, settings: EditSettings) {
        self.url = url
        self.sidecarURL = sidecarURL
        self.settings = settings
    }
}
