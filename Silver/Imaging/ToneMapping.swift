import CoreImage
import Foundation

/// Maps scene-linear values (which may exceed 1 after exposure) to display range with a soft
/// highlight shoulder, instead of clipping each channel at 1.
///
/// The curve is applied to the brightest channel and RGB is scaled by the same ratio, so hues
/// stay put; pixels are then blended toward white as they approach the top of the range.
/// Built from stock Core Image filters so it runs on the GPU without custom kernels.
nonisolated enum ToneMapping {
    /// Largest scene value handled; brighter values map to white.
    private static let domain = 64.0
    /// Lookups use `m^(1/4)` so the table has most of its samples in the shadows.
    private static let encodePower = 0.25
    private static let samples = 1024

    private struct Curve {
        let ratio: Data
        let white: Data
        let mask: Data
    }

    /// Curve for RAW files: follows Core Image's default RAW tone curve (measured from its
    /// output on Leica M11 files) through shadows and midtones, so the default look is unchanged,
    /// then continues into a long shoulder where the default curve would clip at 1.
    private static let raw = makeCurve(knee: 0.46) { x in
        let knee = 0.46
        guard x > knee else { return interpolate(appleCurve, at: x) }
        let kneeValue = interpolate(appleCurve, at: knee)
        let slope = 0.86
        let t = slope * (x - knee) / (1 - kneeValue)
        return kneeValue + (1 - kneeValue) * t / (1 + t)
    }

    /// (scene-linear input, output) pairs of Core Image's default RAW rendering (`boostAmount` 1).
    private static let appleCurve: [(Double, Double)] = [
        (0, 0), (0.00027, 0.0001), (0.00053, 0.0003), (0.00107, 0.0007), (0.00214, 0.0015),
        (0.00428, 0.0033), (0.00855, 0.0072), (0.01208, 0.0109), (0.01708, 0.0169),
        (0.02417, 0.0270), (0.03424, 0.0437), (0.04832, 0.0711), (0.06812, 0.1156),
        (0.09654, 0.1870), (0.13648, 0.2877), (0.19258, 0.4140), (0.27256, 0.5534),
        (0.38555, 0.7004), (0.46016, 0.7722), (0.53864, 0.8326),
    ]

    private static func interpolate(_ points: [(Double, Double)], at x: Double) -> Double {
        guard let upper = points.firstIndex(where: { $0.0 >= x }) else { return points.last!.1 }
        guard upper > 0 else { return points[0].1 }
        let (x0, y0) = points[upper - 1], (x1, y1) = points[upper]
        return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    }

    /// Identity up to a knee, then a smooth shoulder. For already-rendered images (JPEG).
    private static let shoulder = makeCurve(knee: 0.75) { x in
        let knee = 0.75
        return x <= knee ? x : knee + (1 - knee) * (1 - exp(-(x - knee) / (1 - knee)))
    }

    static func raw(_ image: CIImage) -> CIImage { apply(raw, to: image) }
    static func shoulder(_ image: CIImage) -> CIImage { apply(shoulder, to: image) }

    private static func apply(_ curve: Curve, to image: CIImage) -> CIImage {
        let brightest = image
            .applyingFilter("CIMaximumComponent")
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": encodePower])
        let ratio = lookup(brightest, curve.ratio)
        let scaled = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ratio])
        return lookup(brightest, curve.white).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: scaled,
            kCIInputMaskImageKey: lookup(brightest, curve.mask),
        ])
    }

    private static func lookup(_ image: CIImage, _ table: Data) -> CIImage {
        image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table,
            "inputCurvesDomain": CIVector(x: 0, y: pow(domain, encodePower)),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        ])
    }

    /// Colors are eased toward white only above `knee`, where the shoulder compresses them.
    private static func makeCurve(knee: Double, _ f: @escaping (Double) -> Double) -> Curve {
        let mapped = { (x: Double) in min(max(f(x), 0), 1) }
        let kneeValue = mapped(knee)
        return Curve(
            ratio: table { x in x > 1e-6 ? mapped(x) / x : mapped(1e-6) / 1e-6 },
            white: table(mapped),
            mask: table { x in pow(max(mapped(x) - kneeValue, 0) / (1 - kneeValue), 2) }
        )
    }

    /// Samples `f(m)` on a grid that is uniform in `m^(1/4)`.
    private static func table(_ f: (Double) -> Double) -> Data {
        let maxEncoded = pow(domain, encodePower)
        var values: [Float] = []
        values.reserveCapacity(samples * 3)
        for i in 0..<samples {
            let encoded = maxEncoded * Double(i) / Double(samples - 1)
            let value = Float(f(pow(encoded, 1 / encodePower)))
            values += [value, value, value]
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
