import CoreImage
import Foundation

nonisolated struct PreviewResult: @unchecked Sendable {
    let image: CGImage
    /// Size of the developed image before crop, used for crop geometry.
    let baseSize: CGSize
}

nonisolated struct DetailResult: @unchecked Sendable {
    /// Full-resolution pixels for each requested area, in the same order.
    let pieces: [(image: CGImage, rect: CGRect)]
    /// Size of the full-resolution output (after crop and straighten).
    let fullSize: CGSize
}

/// Hands a decoded source between the renderer and a prefetch running outside it. Only one side
/// uses it at a time.
private nonisolated struct SourceBox: @unchecked Sendable {
    let source: SourceImage
}

/// Renders screen-sized previews. Keeps a few decoded sources around so revisiting
/// recent photos and dragging sliders stays fast.
actor PreviewRenderer {
    private let context = CIContext(options: [.name: "Silver.Preview"])
    /// A context runs one render at a time, so prefetching has its own: decoding the next photo
    /// doesn't hold up renders of the one being edited. It renders each photo once, so it keeps
    /// no intermediates, and it gives way to the preview on the GPU.
    private nonisolated let prefetchContext = CIContext(options: [
        .name: "Silver.Prefetch",
        .cacheIntermediates: false,
        .priorityRequestLow: true,
    ])
    private var sources: [SourceImage] = []
    /// About 190 MB each for M11 files: the photo shown, the ones next to it and recent ones.
    private let cacheLimit = 5
    /// Last preview render with crop and straighten of the most recent photos, for
    /// `thumbnail(url:settings:)`, which runs once edits pause, possibly after moving on.
    private var lastRenders: [(url: URL, settings: EditSettings, image: CIImage)] = []

    func render(url: URL, settings: EditSettings, geometry: Bool, maxPixelSize: CGFloat, colorSpace: CGColorSpace) -> PreviewResult? {
        guard let source = source(for: url, maxPixelSize: maxPixelSize),
              let (result, image) = Self.renderPreview(source, settings: settings, geometry: geometry, maxPixelSize: maxPixelSize, context: context, colorSpace: colorSpace)
        else { return nil }
        if geometry {
            lastRenders.removeAll { $0.url == url }
            lastRenders.append((url, settings, image))
            if lastRenders.count > 3 { lastRenders.removeFirst() }
        }
        return result
    }

    /// Decodes a photo and renders its preview ahead of time, without holding up the renderer,
    /// then keeps the decoded source so later renders of the photo skip the decode (about 0.6 s
    /// of a 0.8 s open for M11 files).
    @concurrent nonisolated func prefetch(url: URL, settings: EditSettings, maxPixelSize: CGFloat, colorSpace: CGColorSpace) async -> PreviewResult? {
        guard let box = await take(url) ?? SourceImage(url: url, maxPixelSize: maxPixelSize).map(SourceBox.init) else { return nil }
        let result = Self.renderPreview(box.source, settings: settings, geometry: true, maxPixelSize: maxPixelSize, context: prefetchContext, colorSpace: colorSpace)
        await adopt(box)
        return result?.0
    }

    private nonisolated static func renderPreview(
        _ source: SourceImage, settings: EditSettings, geometry: Bool, maxPixelSize: CGFloat, context: CIContext, colorSpace: CGColorSpace
    ) -> (PreviewResult, CIImage)? {
        // A crop is enlarged to fill the screen, so decode enough pixels for the cropped area.
        // The crop tool shows the whole image; keep the current resolution there to avoid re-decoding.
        if geometry {
            source.ensureLongEdge(source.longEdgeNeeded(for: settings.crop, outputPixelSize: maxPixelSize))
        }
        guard let (image, baseSize) = ImagePipeline.render(source, settings: settings, geometry: geometry, context: context),
              let cgImage = ImagePipeline.bitmap(image, from: image.extent, context: context, colorSpace: colorSpace)
        else { return nil }
        return (PreviewResult(image: cgImage, baseSize: baseSize), image)
    }

    /// Thumbnail of the last preview render of `url` with crop and straighten, if it had `settings`.
    func thumbnail(url: URL, settings: EditSettings) -> CGImage? {
        guard let render = lastRenders.last(where: { $0.url == url }), render.settings == settings else { return nil }
        return Thumbnails.downscale(render.image, maxPixelSize: Thumbnails.maxPixelSize, context: context)
    }

    func removeAll() {
        sources.removeAll()
        lastRenders.removeAll()
    }

    /// Renders parts of the photo at full resolution, for viewing at 100%. `rects` are in
    /// full-resolution output pixels with a top-left origin and are clipped to the image; pass
    /// none to only get the full-resolution size.
    func renderDetail(url: URL, settings: EditSettings, geometry: Bool, rects: [CGRect], colorSpace: CGColorSpace) -> DetailResult? {
        guard let source = source(for: url, maxPixelSize: .infinity) else { return nil }
        source.ensureLongEdge(.infinity)
        guard let (image, _) = ImagePipeline.render(source, settings: settings, geometry: geometry, context: context) else { return nil }
        let extent = image.extent
        let fullSize = extent.size
        let pieces = rects.compactMap { rect -> (CGImage, CGRect)? in
            let clipped = rect.integral.intersection(CGRect(origin: .zero, size: fullSize))
            guard !clipped.isEmpty else { return nil }
            // Top-left origin → Core Image's bottom-left origin.
            let region = CGRect(x: extent.minX + clipped.minX, y: extent.maxY - clipped.maxY, width: clipped.width, height: clipped.height)
            return ImagePipeline.bitmap(image, from: region, context: context, colorSpace: colorSpace).map { ($0, clipped) }
        }
        return DetailResult(pieces: pieces, fullSize: fullSize)
    }

    private func source(for url: URL, maxPixelSize: CGFloat) -> SourceImage? {
        if let index = sources.firstIndex(where: { $0.url == url }) {
            let source = sources.remove(at: index)
            sources.append(source)
            return source
        }
        guard let source = SourceImage(url: url, maxPixelSize: maxPixelSize) else { return nil }
        insert(source)
        return source
    }

    private func insert(_ source: SourceImage) {
        sources.append(source)
        if sources.count > cacheLimit { sources.removeFirst() }
    }

    /// Lends a cached source to a prefetch; `adopt` gives it back.
    private func take(_ url: URL) -> SourceBox? {
        guard let index = sources.firstIndex(where: { $0.url == url }) else { return nil }
        return SourceBox(source: sources.remove(at: index))
    }

    private func adopt(_ box: SourceBox) {
        // A render may have decoded the photo meanwhile; keep that one, its intermediates are cached.
        guard !sources.contains(where: { $0.url == box.source.url }) else { return }
        insert(box.source)
    }
}
