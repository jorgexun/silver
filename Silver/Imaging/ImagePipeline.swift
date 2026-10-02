import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded source image. RAW files keep their `CIRAWFilter` so exposure and white balance
/// are applied during RAW development.
///
/// Not thread-safe: use one instance from one task at a time.
nonisolated final class SourceImage {
    let url: URL
    private let rawFilter: CIRAWFilter?
    private var bitmap: CIImage?
    private let asShotTemperature: Float
    private let asShotTint: Float
    /// Oriented full-resolution size.
    private let nativeSize: CGSize
    /// Long edge the image is currently decoded at.
    private(set) var decodedLongEdge: CGFloat
    /// Local tone coefficients (see `LocalTone`) and the white balance they were computed with.
    private var localCoefficients: (temperature: Double, tint: Double, image: CIImage)?

    /// Loads `url`, downscaled so the long edge is at most `maxPixelSize` (nil = full resolution).
    init?(url: URL, maxPixelSize: CGFloat?) {
        self.url = url
        if PhotoFile.isRaw(url), let raw = CIRAWFilter(imageURL: url) {
            // Scene-linear output with highlight headroom; tone mapping happens in ToneMapping.
            raw.boostAmount = 0
            raw.extendedDynamicRangeAmount = 2
            guard let extent = raw.outputImage?.extent else { return nil }  // Lazy: no decoding yet.
            rawFilter = raw
            asShotTemperature = raw.neutralTemperature
            asShotTint = raw.neutralTint
            nativeSize = extent.size
        } else {
            guard let size = Self.bitmapSize(url: url) else { return nil }
            rawFilter = nil
            asShotTemperature = 6500
            asShotTint = 0
            nativeSize = size
        }
        decodedLongEdge = max(nativeSize.width, nativeSize.height)
        setLongEdge(maxPixelSize)
    }

    /// Long edge to decode at so that `crop` comes out with a long side of at least `outputPixelSize`.
    func longEdgeNeeded(for crop: CropRect, outputPixelSize: CGFloat) -> CGFloat {
        let longEdge = max(nativeSize.width, nativeSize.height)
        let fraction = max(crop.width * nativeSize.width / longEdge, crop.height * nativeSize.height / longEdge, 0.02)
        return (outputPixelSize / fraction).rounded(.up)
    }

    /// Changes the decode resolution when the current one is too small, or much larger than needed.
    func ensureLongEdge(_ needed: CGFloat) {
        let target = min(needed, max(nativeSize.width, nativeSize.height))
        if decodedLongEdge < target - 1 || decodedLongEdge > target * 1.5 {
            setLongEdge(target)
        }
    }

    private func setLongEdge(_ maxPixelSize: CGFloat?) {
        let nativeLongEdge = max(nativeSize.width, nativeSize.height)
        let longEdge = min(maxPixelSize ?? nativeLongEdge, nativeLongEdge)
        guard longEdge != decodedLongEdge else { return }
        decodedLongEdge = longEdge
        if let rawFilter {
            rawFilter.scaleFactor = Float(longEdge / nativeLongEdge)
        } else {
            bitmap = nil  // Reloaded at the new size on next use.
        }
    }

    private static func bitmapSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private func loadBitmap() -> CIImage? {
        if let bitmap { return bitmap }
        let nativeLongEdge = max(nativeSize.width, nativeSize.height)
        if decodedLongEdge >= nativeLongEdge {
            bitmap = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        } else {
            bitmap = loadBitmap(longEdge: decodedLongEdge)
        }
        return bitmap
    }

    private func loadBitmap(longEdge: CGFloat) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { CIImage(cgImage: $0) }
    }

    /// The developed image with light and color adjustments applied (no geometry). `context`
    /// renders the local tone coefficients when Highlights or Shadows need them.
    func developed(with settings: EditSettings, context: CIContext) -> CIImage? {
        let usesLocal = settings.highlights != 0 || settings.shadows != 0
        var image: CIImage
        if let raw = rawFilter {
            // Temperature is adjusted in mired space so the slider feels even across the range.
            let asShotMired = 1_000_000 / Double(max(asShotTemperature, 1000))
            let mired = max(asShotMired - settings.temperature * 0.8, 20)
            raw.neutralTemperature = Float(1_000_000 / mired)
            raw.neutralTint = asShotTint + Float(settings.tint)
            // Before taking the output: computing coefficients changes the decode scale for a moment.
            let local = usesLocal ? localAdjustment(settings, context: context) : nil
            guard let output = raw.outputImage else { return nil }
            image = ToneMapping.raw(output, exposure: settings.exposure, contrast: settings.contrast, local: local)
        } else {
            guard let bitmap = loadBitmap() else { return nil }
            let local = usesLocal ? localAdjustment(settings, context: context) : nil
            image = ToneMapping.bitmap(
                whiteBalanced(bitmap, settings), exposure: settings.exposure, contrast: settings.contrast, local: local
            )
        }
        return ImagePipeline.applyColor(vibrance: settings.vibrance, saturation: settings.saturation, to: image)
    }

    private func whiteBalanced(_ bitmap: CIImage, _ settings: EditSettings) -> CIImage {
        guard settings.temperature != 0 || settings.tint != 0 else { return bitmap }
        let targetMired = 1_000_000 / 6500 + settings.temperature * 0.8
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = bitmap
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 1_000_000 / max(targetMired, 20), y: -settings.tint)
        return filter.outputImage ?? bitmap
    }

    /// Highlights and Shadows with this photo's local tone coefficients, computed for the
    /// current white balance on first use. They come from a decode of a fixed size, so every
    /// output of the photo gets the same ones.
    private func localAdjustment(_ settings: EditSettings, context: CIContext) -> LocalAdjustment? {
        if localCoefficients?.temperature != settings.temperature || localCoefficients?.tint != settings.tint {
            let image: CIImage?
            if let rawFilter {
                let scale = rawFilter.scaleFactor
                rawFilter.scaleFactor = Float(min(LocalTone.decodeLongEdge / max(nativeSize.width, nativeSize.height), 1))
                image = rawFilter.outputImage.flatMap { LocalTone.coefficients(of: $0, context: context) }
                rawFilter.scaleFactor = scale
            } else {
                image = loadBitmap(longEdge: LocalTone.decodeLongEdge)
                    .flatMap { LocalTone.coefficients(of: whiteBalanced($0, settings), context: context) }
            }
            guard let image else { return nil }
            localCoefficients = (settings.temperature, settings.tint, image)
        }
        return localCoefficients.map { LocalAdjustment(coefficients: $0.image, highlights: settings.highlights, shadows: settings.shadows) }
    }
}

nonisolated enum ImagePipeline {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Vibrance and saturation.
    static func applyColor(vibrance: Double, saturation: Double, to input: CIImage) -> CIImage {
        var image = input

        if vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(vibrance / 100)
            image = filter.outputImage ?? image
        }

        if saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(1 + saturation / 100)
            filter.brightness = 0
            filter.contrast = 1
            image = filter.outputImage ?? image
        }

        return image
    }

    /// Applies straighten and crop. The result has its origin at (0, 0).
    static func applyGeometry(_ settings: EditSettings, to input: CIImage) -> CIImage {
        let extent = input.extent
        var image = input

        if settings.straighten != 0 {
            let center = CGPoint(x: extent.midX, y: extent.midY)
            // Core Image is y-up, so a clockwise rotation on screen is a negative angle.
            let angle = -settings.straighten * .pi / 180
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: -center.x, y: -center.y)
            image = image.transformed(by: transform, highQualityDownsample: true)
        }

        // No-op for crops made in the crop tool; keeps pasted or hand-edited crops inside the
        // straightened image so the output never has empty corners.
        let crop = CropGeometry.fitted(settings.crop, angle: settings.straighten, imageSize: extent.size)
        let minX = (extent.minX + crop.minX * extent.width).rounded(.up)
        let maxX = (extent.minX + crop.maxX * extent.width).rounded(.down)
        // Flip y: crop is top-left based, Core Image is bottom-left based.
        let minY = (extent.minY + (1 - crop.maxY) * extent.height).rounded(.up)
        let maxY = (extent.minY + (1 - crop.minY) * extent.height).rounded(.down)
        let rect = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))

        return image
            .cropped(to: rect)
            .settingAlphaOne(in: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Full rendering recipe. `context` is the one that will render the result.
    static func render(_ source: SourceImage, settings: EditSettings, geometry: Bool, context: CIContext) -> (image: CIImage, baseSize: CGSize)? {
        guard let developed = source.developed(with: settings, context: context) else { return nil }
        let baseSize = developed.extent.size
        let image = geometry ? applyGeometry(settings, to: developed) : developed
        return (image, baseSize)
    }

    /// Renders `rect` of `image` now, unlike `CIContext.createCGImage`, which may defer the
    /// render until the image is drawn on the main thread. The layout is Core Animation's native
    /// BGRA; pass the screen's color space for images shown on screen, so Core Animation doesn't
    /// convert them on the CPU (see "Showing rendered images" in CLAUDE.md).
    static func bitmap(_ image: CIImage, from rect: CGRect, context: CIContext, colorSpace: CGColorSpace = sRGB) -> CGImage? {
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0 else { return nil }
        let rowBytes = (width * 4 + 63) / 64 * 64
        guard let data = NSMutableData(length: rowBytes * height) else { return nil }
        context.render(image, toBitmap: data.mutableBytes, rowBytes: rowBytes, bounds: rect, format: .BGRA8, colorSpace: colorSpace)
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

nonisolated enum PhotoFile {
    static let supportedExtensions: Set<String> = ["dng", "jpg", "jpeg"]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isRaw(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "dng"
    }
}
