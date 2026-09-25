import CoreImage
import Foundation
import Synchronization

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

    private struct Curve: Sendable {
        let ratio: Data
        let white: Data
        let mask: Data
    }

    /// Curve for RAW files: follows Core Image's default RAW tone curve (measured from its
    /// output on Leica M11 files) through shadows and midtones, so the default look is unchanged,
    /// then continues into a long shoulder where the default curve would clip at 1.
    private static let raw = makeCurve(blendFrom: rawTone(rawKnee), rawTone)
    private static let rawKnee = 0.46

    private static func rawTone(_ x: Double) -> Double {
        guard x > rawKnee else { return interpolate(appleCurve, at: x) }
        let kneeValue = interpolate(appleCurve, at: rawKnee)
        let slope = 0.86
        let t = slope * (x - rawKnee) / (1 - kneeValue)
        return kneeValue + (1 - kneeValue) * t / (1 + t)
    }

    /// Recently used RAW curves with a Highlights adjustment, most recent last.
    private static let highlightCurves = Mutex<[(key: HighlightKey, curve: Curve)]>([])
    private static let highlightCacheLimit = 32

    private struct HighlightKey: Equatable {
        let highlights: Int
        /// `log2(top)` in 1/50 stop steps.
        let top: Int
    }

    private static func rawCurve(highlights: Double, top: Double) -> Curve {
        let highlights = highlights.isFinite ? min(max(highlights, -100), 100) : 0
        let amount = highlightAmount(highlights)
        guard amount != 0, top.isFinite, top > highlightPivot * 1.2 else { return raw }
        let key = HighlightKey(highlights: Int(highlights.rounded()), top: Int((log2(min(top, domain)) * 50).rounded()))
        let cached = highlightCurves.withLock { cache -> Curve? in
            guard let index = cache.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.curve
        }
        if let cached { return cached }

        let roundedTop = pow(2, Double(key.top) / 50)
        let curve = makeCurve(blendFrom: rawTone(rawKnee)) { rawTone(shiftHighlights($0, amount: amount, top: roundedTop)) }
        highlightCurves.withLock { cache in
            cache.append((key, curve))
            if cache.count > highlightCacheLimit { cache.removeFirst() }
        }
        return curve
    }

    /// Slider value (-100...100) to reshaping strength. Limits keep the curve monotonic:
    /// the log-space slope is `1 - amount * bump'`, and `bump'` ranges from -6.75 to 2.25.
    private static func highlightAmount(_ highlights: Double) -> Double {
        let h = highlights / 100
        return h < 0 ? -h * 0.4 : -h * 0.13
    }

    /// Scene value where Highlights starts; midtones below it are never touched.
    private static let highlightPivot = 0.3

    /// Reshapes tones between the pivot and `top` (the brightest level in the image), in stops.
    /// Positive `amount` darkens the upper highlights and spreads out the tones just below `top`,
    /// which the shoulder would otherwise squeeze together; negative brightens them. The pivot
    /// and `top` map to themselves, and the change fades in with zero slope at the pivot, so
    /// midtones and the white level stay exactly as they are.
    private static func shiftHighlights(_ x: Double, amount: Double, top: Double) -> Double {
        let range = log2(top / highlightPivot)
        guard x > highlightPivot, x < top, range > 0 else { return x }
        let stops = log2(x / highlightPivot)
        let t = stops / range
        let bump = 6.75 * t * t * (1 - t)  // 0 at both ends, 1 at t = 2/3, flat at the pivot
        return highlightPivot * pow(2, stops - amount * range * bump)
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
    private static let shoulder = makeCurve(blendFrom: 0.75) { x in
        let knee = 0.75
        return x <= knee ? x : knee + (1 - knee) * (1 - exp(-(x - knee) / (1 - knee)))
    }

    /// - Parameter top: Brightest scene value in the image (after exposure); Highlights keeps it fixed.
    static func raw(_ image: CIImage, highlights: Double, top: Double) -> CIImage {
        apply(rawCurve(highlights: highlights, top: top), to: image)
    }
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

    /// Samples `f` on a grid that is uniform in `m^(1/4)`. Colors are eased toward white only
    /// where the output is above `blendFrom`, which is where the shoulder compresses them.
    private static func makeCurve(blendFrom: Double, _ f: (Double) -> Double) -> Curve {
        let maxEncoded = pow(domain, encodePower)
        var ratio: [Float] = [], white: [Float] = [], mask: [Float] = []
        for i in 0..<samples {
            let x = max(pow(maxEncoded * Double(i) / Double(samples - 1), 1 / encodePower), 1e-6)
            let y = min(max(f(x), 0), 1)
            ratio += Array(repeating: Float(y / x), count: 3)
            white += Array(repeating: Float(y), count: 3)
            mask += Array(repeating: Float(pow(max(y - blendFrom, 0) / (1 - blendFrom), 2)), count: 3)
        }
        func data(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
        return Curve(ratio: data(ratio), white: data(white), mask: data(mask))
    }
}
