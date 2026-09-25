import CoreImage
import Foundation

nonisolated struct PreviewResult: @unchecked Sendable {
    let image: CGImage
    /// Size of the developed image before crop, used for crop geometry.
    let baseSize: CGSize
}

nonisolated struct DetailResult: @unchecked Sendable {
    /// Full-resolution pixels for `rect`, or nil when only the size was requested.
    let image: CGImage?
    /// Rendered area in full-resolution output pixels, top-left origin.
    let rect: CGRect
    /// Size of the full-resolution output (after crop and straighten).
    let fullSize: CGSize
}

/// Renders screen-sized previews. Keeps a few decoded sources around so revisiting
/// recent photos and dragging sliders stays fast.
actor PreviewRenderer {
    private let context = CIContext(options: [.name: "Silver.Preview"])
    private var sources: [SourceImage] = []
    private let cacheLimit = 3
    /// Last preview render with geometry applied, for `thumbnail()`.
    private var lastRender: CIImage?

    func render(url: URL, settings: EditSettings, geometry: Bool, maxPixelSize: CGFloat, colorSpace: CGColorSpace) -> PreviewResult? {
        guard let source = source(for: url, maxPixelSize: maxPixelSize) else { return nil }
        // A crop is enlarged to fill the screen, so decode enough pixels for the cropped area.
        // The crop tool shows the whole image; keep the current resolution there to avoid re-decoding.
        if geometry {
            source.ensureLongEdge(source.longEdgeNeeded(for: settings.crop, outputPixelSize: maxPixelSize))
        }
        guard let (image, baseSize) = ImagePipeline.render(source, settings: settings, geometry: geometry),
              let cgImage = ImagePipeline.bitmap(image, from: image.extent, context: context, colorSpace: colorSpace)
        else { return nil }
        lastRender = geometry ? image : nil
        return PreviewResult(image: cgImage, baseSize: baseSize)
    }

    /// Thumbnail of the last preview render, if it applied crop and straighten.
    func thumbnail() -> CGImage? {
        lastRender.flatMap { Thumbnails.downscale($0, maxPixelSize: Thumbnails.maxPixelSize, context: context) }
    }

    /// Renders part of the photo at full resolution, for viewing at 100%. `rect` is in
    /// full-resolution output pixels with a top-left origin and is clipped to the image; pass
    /// nil to only get the full-resolution size.
    func renderDetail(url: URL, settings: EditSettings, geometry: Bool, rect: CGRect?, colorSpace: CGColorSpace) -> DetailResult? {
        guard let source = source(for: url, maxPixelSize: .infinity) else { return nil }
        source.ensureLongEdge(.infinity)
        guard let (image, _) = ImagePipeline.render(source, settings: settings, geometry: geometry) else { return nil }
        let extent = image.extent
        let fullSize = extent.size
        guard let rect else { return DetailResult(image: nil, rect: .zero, fullSize: fullSize) }

        let clipped = rect.integral.intersection(CGRect(origin: .zero, size: fullSize))
        guard !clipped.isEmpty else { return nil }
        // Top-left origin → Core Image's bottom-left origin.
        let region = CGRect(x: extent.minX + clipped.minX, y: extent.maxY - clipped.maxY, width: clipped.width, height: clipped.height)
        let cgImage = ImagePipeline.bitmap(image, from: region, context: context, colorSpace: colorSpace)
        return DetailResult(image: cgImage, rect: clipped, fullSize: fullSize)
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
