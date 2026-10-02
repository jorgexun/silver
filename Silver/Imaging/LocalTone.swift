import CoreImage
import Foundation

/// The edge-aware local average that Highlights and Shadows act on (see research.md appendix B).
///
/// A self-guided filter on log2 luminance, computed at low resolution: its coefficients (a, b)
/// are scaled up to the image, where `a · L + b` with the full-resolution luminance L gives an
/// average that follows edges at full resolution. Regions are adjusted as a whole, so detail
/// inside them keeps its contrast, without the halos of a plain blur.
///
/// The coefficients depend only on the photo and its white balance, not on exposure (which
/// only shifts L by a constant) or on the Highlights and Shadows amounts, so they are rendered
/// once and reused while those sliders move.
nonisolated enum LocalTone {
    /// Long edge RAW files are decoded at to compute the coefficients. Fixed, so previews,
    /// thumbnails, 100% views and exports of a photo all get the same coefficients.
    static let decodeLongEdge: CGFloat = 1024
    /// Long edge the filter runs at.
    private static let filterLongEdge: CGFloat = 512
    /// Box radius at `filterLongEdge`, about 2% of the long edge.
    private static let radius = 10
    /// Variation below about √ε stops is treated as detail within a region, larger steps as edges.
    private static let epsilon: Float = 1

    private static let kernels: (luminance: CIColorKernel, deviation: CIColorKernel, coefficients: CIColorKernel)? = {
        guard let luminance = ToneMapping.colorKernel("logLuminanceImage"),
              let deviation = ToneMapping.colorKernel("squaredDeviation"),
              let coefficients = ToneMapping.colorKernel("guidedCoefficients")
        else { return nil }
        return (luminance, deviation, coefficients)
    }()

    /// Renders the filter coefficients of `image` (white-balanced, linear, the whole frame) now,
    /// with `context`. The result is a small image with a in red and b in green, and an extent
    /// that `ToneMapping` maps onto the image's.
    static func coefficients(of image: CIImage, context: CIContext) -> CIImage? {
        guard let kernels else {
            assertionFailure("Local tone kernels are missing from the Metal library")
            return nil
        }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 0 else { return nil }
        let width = max((extent.width * filterLongEdge / longEdge).rounded(), 1)
        let height = max((extent.height * filterLongEdge / longEdge).rounded(), 1)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Averaging linear values, then taking the log, gives nearly the same result from any
        // decode size; the other way round depends on the noise at that size.
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: width / extent.width, y: height / extent.height), highQualityDownsample: true)
            .cropped(to: rect)

        func boxMean(_ image: CIImage) -> CIImage {
            image.clampedToExtent()
                .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: rect)
        }
        guard let luminance = kernels.luminance.apply(extent: rect, arguments: [small]) else { return nil }
        let mean = boxMean(luminance)
        // The mean of squared deviations from the local mean, not E[L²] − E[L]²: that difference
        // loses most of its precision in the half-float intermediates of the default context.
        guard let deviation = kernels.deviation.apply(extent: rect, arguments: [luminance, mean]),
              let coefficients = kernels.coefficients.apply(extent: rect, arguments: [mean, boxMean(deviation), epsilon])
        else { return nil }
        let output = boxMean(coefficients)

        let rowBytes = Int(width) * 16
        var data = Data(count: rowBytes * Int(height))
        data.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: rect, format: .RGBAf, colorSpace: nil)
        }
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: rect.size, format: .RGBAf, colorSpace: nil)
    }
}

/// Highlights and Shadows with the local average they act on.
nonisolated struct LocalAdjustment {
    let coefficients: CIImage
    let highlights: Double
    let shadows: Double
}
