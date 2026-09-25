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
    private let bitmap: CIImage?
    private let asShotTemperature: Float
    private let asShotTint: Float

    var isRaw: Bool { rawFilter != nil }

    /// Loads `url`, downscaled so the long edge is at most `maxPixelSize` (nil = full resolution).
    init?(url: URL, maxPixelSize: CGFloat?) {
        self.url = url
        if PhotoFile.isRaw(url), let raw = CIRAWFilter(imageURL: url) {
            let native = raw.nativeSize
            let longEdge = max(native.width, native.height)
            if let maxPixelSize, longEdge > maxPixelSize {
                raw.scaleFactor = Float(maxPixelSize / longEdge)
            }
            rawFilter = raw
            bitmap = nil
            asShotTemperature = raw.neutralTemperature
            asShotTint = raw.neutralTint
        } else {
            guard let image = Self.loadBitmap(url: url, maxPixelSize: maxPixelSize) else { return nil }
            rawFilter = nil
            bitmap = image
            asShotTemperature = 6500
            asShotTint = 0
        }
    }

    private static func loadBitmap(url: URL, maxPixelSize: CGFloat?) -> CIImage? {
        guard let maxPixelSize else {
            return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// The developed image with light and color adjustments applied (no geometry).
    func developed(with settings: EditSettings) -> CIImage? {
        var image: CIImage
        if let raw = rawFilter {
            raw.exposure = Float(settings.exposure)
            // Temperature is adjusted in mired space so the slider feels even across the range.
            let asShotMired = 1_000_000 / Double(max(asShotTemperature, 1000))
            let mired = max(asShotMired - settings.temperature * 0.8, 20)
            raw.neutralTemperature = Float(1_000_000 / mired)
            raw.neutralTint = asShotTint + Float(settings.tint)
            guard let output = raw.outputImage else { return nil }
            image = output
        } else {
            guard let bitmap else { return nil }
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
        }
        return ImagePipeline.applyTone(settings, to: image)
    }
}

nonisolated enum ImagePipeline {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Contrast, highlights, shadows, vibrance and saturation.
    static func applyTone(_ settings: EditSettings, to input: CIImage) -> CIImage {
        var image = input

        if settings.highlights < 0 || settings.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.radius = 0  // Scale independent, so previews match full-size exports.
            filter.highlightAmount = Float(1 + min(settings.highlights, 0) / 100 * 0.7)
            filter.shadowAmount = Float(settings.shadows / 100 * 0.6)
            image = filter.outputImage ?? image
        }

        if settings.contrast != 0 || settings.highlights > 0 {
            // Tone curve in a perceptual (sRGB gamma) space.
            let c = settings.contrast / 100
            let h = max(settings.highlights, 0) / 100
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
