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
            if settings.crop != oldValue.crop || settings.straighten != oldValue.straighten { updateFullSize() }
        }
    }
    /// Stored rather than derived from `settings`, so views and menus that only show whether a
    /// photo is edited aren't updated on every step of a slider drag.
    private(set) var isEdited: Bool
    var thumbnail: CGImage?
    var metadata: PhotoMetadata?
    /// Oriented size of the developed image, used for crop geometry.
    var imageSize: CGSize?
    /// Oriented full-resolution size, known once the photo has been rendered.
    var nativeSize: CGSize? {
        didSet { if nativeSize != oldValue { updateFullSize() } }
    }
    /// Full-resolution size of the output, with crop and straighten. Stored, like `isEdited`, so
    /// views that zoom by it aren't updated on every step of a slider drag.
    private(set) var fullSize: CGSize?

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

    /// Pixel size of an exported JPEG: `fullSize`, or before the photo has been rendered, the
    /// file's size through the crop.
    var exportSize: CGSize? {
        fullSize ?? metadata?.pixelSize.map { ImagePipeline.outputSize(settings, imageSize: $0) }
    }

    private func updateFullSize() {
        let size = nativeSize.map { ImagePipeline.outputSize(settings, imageSize: $0) }
        if size != fullSize { fullSize = size }
    }

    init(url: URL, sidecarURL: URL, settings: EditSettings) {
        self.url = url
        self.sidecarURL = sidecarURL
        self.settings = settings
        isEdited = !settings.isDefault
    }
}
