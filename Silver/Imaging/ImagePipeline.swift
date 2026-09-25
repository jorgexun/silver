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

    var isRaw: Bool { rawFilter != nil }

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
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: decodedLongEdge,
            ]
            bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { CIImage(cgImage: $0) }
        }
        return bitmap
    }

    /// The developed image with light and color adjustments applied (no geometry).
    func developed(with settings: EditSettings) -> CIImage? {
        var image: CIImage
        if let raw = rawFilter {
            // Temperature is adjusted in mired space so the slider feels even across the range.
            let asShotMired = 1_000_000 / Double(max(asShotTemperature, 1000))
            let mired = max(asShotMired - settings.temperature * 0.8, 20)
            raw.neutralTemperature = Float(1_000_000 / mired)
            raw.neutralTint = asShotTint + Float(settings.tint)
            guard let output = raw.outputImage else { return nil }
            // Exposure as a linear gain: unlike the RAW filter's own exposure it is not capped,
            // so the tone curve can roll bright areas off instead of clipping them.
            image = output
            if settings.exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
            }
            image = ToneMapping.raw(image, highlights: settings.highlights)
        } else {
            guard let bitmap = loadBitmap() else { return nil }
            image = bitmap
            if settings.exposure != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
            }
            if settings.temperature != 0 || settings.tint != 0 {
                let targetMired = 1_000_000 / 6500 + settings.temperature * 0.8
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = image
                filter.neutral = CIVector(x: 6500, y: 0)
                filter.targetNeutral = CIVector(x: 1_000_000 / max(targetMired, 20), y: -settings.tint)
                image = filter.outputImage ?? image
            }
            if settings.exposure > 0 {
                image = ToneMapping.shoulder(image)
            }
        }
        return ImagePipeline.applyTone(settings, to: image, highlightsApplied: rawFilter != nil)
    }
}

nonisolated enum ImagePipeline {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Contrast, highlights, shadows, vibrance and saturation.
    /// `highlightsApplied`: Highlights was already applied by RAW tone mapping.
    static func applyTone(_ settings: EditSettings, to input: CIImage, highlightsApplied: Bool = false) -> CIImage {
        var image = input
        let highlights = highlightsApplied ? 0 : settings.highlights

        if highlights < 0 || settings.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.radius = 0  // Scale independent, so previews match full-size exports.
            filter.highlightAmount = Float(1 + min(highlights, 0) / 100 * 0.7)
            filter.shadowAmount = Float(settings.shadows / 100 * 0.6)
            image = filter.outputImage ?? image
        }

        if settings.contrast != 0 || highlights > 0 {
            // Tone curve in a perceptual (sRGB gamma) space.
            let c = settings.contrast / 100
            let h = max(highlights, 0) / 100
            let curve = CIFilter.toneCurve()
            curve.inputImage = image.applyingFilter("CILinearToSRGBToneCurve")
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.25 - 0.075 * c)
            curve.point2 = CGPoint(x: 0.5, y: 0.5 + 0.02 * h)
            curve.point3 = CGPoint(x: 0.75, y: min(0.75 + 0.075 * c + 0.08 * h, 0.99))
            curve.point4 = CGPoint(x: 1, y: 1)
            curve.extrapolate = true
            if let output = curve.outputImage {
                image = output.applyingFilter("CISRGBToneCurveToLinear")
            }
        }

        if settings.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(settings.vibrance / 100)
            image = filter.outputImage ?? image
        }

        if settings.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(1 + settings.saturation / 100)
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

        let crop = settings.crop
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

    /// Full rendering recipe.
    static func render(_ source: SourceImage, settings: EditSettings, geometry: Bool) -> (image: CIImage, baseSize: CGSize)? {
        guard let developed = source.developed(with: settings) else { return nil }
        let baseSize = developed.extent.size
        let image = geometry ? applyGeometry(settings, to: developed) : developed
        return (image, baseSize)
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
