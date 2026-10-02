import CoreGraphics
import Foundation
import Observation

@Observable
final class Photo: Identifiable {
    let url: URL
    let sidecarURL: URL
    var settings: EditSettings {
        didSet {
            let edited = !settings.isDefault
            if edited != isEdited { isEdited = edited }
        }
    }
    /// Stored rather than derived from `settings`, so views and menus that only show whether a
    /// photo is edited aren't updated on every step of a slider drag.
    private(set) var isEdited: Bool
    var thumbnail: CGImage?
    var metadata: PhotoMetadata?
    /// Oriented size of the developed image, used for crop geometry.
    var imageSize: CGSize?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isRaw: Bool { PhotoFile.isRaw(url) }

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
        isEdited = !settings.isDefault
    }
}
