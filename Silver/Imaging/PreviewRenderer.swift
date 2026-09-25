import CoreImage
import Foundation

nonisolated struct PreviewResult: @unchecked Sendable {
    let image: CGImage
    /// Size of the developed image before crop, used for crop geometry.
    let baseSize: CGSize
    /// Small copy of a geometry-applied render, used to refresh the thumbnail.
    let thumbnail: CGImage?
}

/// Renders screen-sized previews. Keeps a few decoded sources around so revisiting
/// recent photos and dragging sliders stays fast.
actor PreviewRenderer {
    private let context = CIContext(options: [.name: "Silver.Preview"])
    private var sources: [SourceImage] = []
    private let cacheLimit = 3

    func render(url: URL, settings: EditSettings, geometry: Bool, maxPixelSize: CGFloat, makeThumbnail: Bool) -> PreviewResult? {
        guard let source = source(for: url, maxPixelSize: maxPixelSize),
              let (image, baseSize) = ImagePipeline.render(source, settings: settings, geometry: geometry),
              let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: ImagePipeline.sRGB)
        else { return nil }

        var thumbnail: CGImage?
        if makeThumbnail {
            thumbnail = Thumbnails.downscale(image, maxPixelSize: Thumbnails.maxPixelSize, context: context)
        }
        return PreviewResult(image: cgImage, baseSize: baseSize, thumbnail: thumbnail)
    }

    func evict(url: URL) {
        sources.removeAll { $0.url == url }
    }

    func removeAll() {
        sources.removeAll()
    }

    private func source(for url: URL, maxPixelSize: CGFloat) -> SourceImage? {
        if let index = sources.firstIndex(where: { $0.url == url }) {
            let source = sources.remove(at: index)
            sources.append(source)
            return source
        }
        guard let source = SourceImage(url: url, maxPixelSize: maxPixelSize) else { return nil }
        sources.append(source)
        if sources.count > cacheLimit { sources.removeFirst() }
        return source
    }
}
