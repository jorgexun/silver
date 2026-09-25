import CoreImage
import Foundation
import Synchronization

/// Tone mapping: exposure, the base tone curve, Highlights and Contrast, combined into one
/// curve that `ToneKernels.metal` applies with Adobe's hue-preserving `RGBTone` method.
///
/// The curve is evaluated on the CPU into a lookup table (an image one pixel high), so any
/// combination of settings costs a single kernel pass on the GPU.
nonisolated enum ToneMapping {
    // MARK: Lookup table

    /// Largest scene value handled; brighter values map to the curve's end value.
    private static let domain = 64.0
    /// Tables are sampled uniformly in `x^(1/4)` so most entries are spent in the shadows.
    /// Must match `toneLookup` in ToneKernels.metal.
    private static let encodePower = 0.25
    private static let samples = 1024

    /// Where the compiled Core Image kernels live. Command-line harnesses point this at a
    /// separately built `.metallib` before first use.
    nonisolated(unsafe) static var metalLibraryURL = Bundle.main.url(forResource: "default", withExtension: "metallib")

    private static let kernel: CIKernel? = {
        guard let url = metalLibraryURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? CIKernel(functionName: "rgbTone", fromMetalLibraryData: data)
    }()

    private static func apply(_ table: CIImage, to image: CIImage) -> CIImage {
        guard let kernel else {
            assertionFailure("rgbTone kernel is missing from the Metal library")
            return image
        }
        let tableExtent = table.extent
        return kernel.apply(
            extent: image.extent,
            roiCallback: { index, rect in index == 0 ? rect : tableExtent },
            arguments: [image, table, Float(pow(domain, encodePower)), Float(samples)]
        ) ?? image
    }

    private static func makeTable(_ f: (Double) -> Double) -> CIImage {
        let maxEncoded = pow(domain, encodePower)
        var values: [Float] = []
        values.reserveCapacity(samples * 4)
        for i in 0..<samples {
            let x = pow(maxEncoded * Double(i) / Double(samples - 1), 1 / encodePower)
            let y = Float(min(max(f(x), 0), 1))
            values += [y, y, y, 1]
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        // No color space: the values are used as-is, without color management.
        return CIImage(bitmapData: data, bytesPerRow: samples * 16, size: CGSize(width: samples, height: 1), format: .RGBAf, colorSpace: nil)
    }

    /// Recently used tables, most recent last.
    private static let tables = Mutex<[(key: TableKey, table: CIImage)]>([])
    private static let tableCacheLimit = 32

    private enum TableKey: Hashable {
        case raw(exposure: Int, highlights: Int, contrast: Int)
        case bitmap(exposure: Int, highlights: Int, contrast: Int)
    }

    private static func table(for key: TableKey, _ f: () -> (Double) -> Double) -> CIImage {
        let cached = tables.withLock { cache -> CIImage? in
            guard let index = cache.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.table
        }
        if let cached { return cached }
        let table = makeTable(f())
        tables.withLock { cache in
            cache.append((key, table))
            if cache.count > tableCacheLimit { cache.removeFirst() }
        }
        return table
    }

    // MARK: - RAW

    /// Develops scene-linear RAW output (white balance applied, highlight headroom kept) for display.
    static func raw(_ image: CIImage, exposure: Double, highlights: Double, contrast: Double) -> CIImage {
        // Quantize to the cache key so equal keys always produce equal tables.
        let exposureKey = Int((clamp(exposure, -5, 5) * 100).rounded())
        let highlightsKey = Int(clamp(highlights, -100, 100).rounded())
        let contrastKey = Int(clamp(contrast, -100, 100).rounded())
        let key = TableKey.raw(exposure: exposureKey, highlights: highlightsKey, contrast: contrastKey)
        let table = table(for: key) {
            rawCurve(exposure: Double(exposureKey) / 100, highlights: Double(highlightsKey), contrast: Double(contrastKey))
        }
        return apply(table, to: image)
    }

    /// Scene value (at exposure 0) that becomes display white. Fixed rather than measured per image:
    /// measuring costs about 0.12 s per photo opened or exported. 6 covers the brightest levels seen
    /// in M11 files (sensor clipping lands between about 1.3 and 5.9 depending on the image and white
    /// balance), so Highlights can still recover that headroom; clipped areas render at 249–254.
    static let sceneWhite = 6.0

    /// Scene value → display value for RAW files.
    private static func rawCurve(exposure: Double, highlights: Double, contrast: Double) -> (Double) -> Double {
        let white = sceneWhite
        let gain = pow(2, max(exposure, 0))
        // Positive exposure moves the white point up with the image; negative exposure keeps it,
        // so clipped highlights stay white while the rest darkens (as in Adobe's DNG SDK).
        let top = white * gain
        let amount = highlightAmount(highlights)
        let midGray = encode(base(0.18, white: baseWhite))
        return { x in
            var v = exposure < 0 ? white * negativeExposure(x / white, exposure) : x * gain
            v = shiftHighlights(v, amount: amount, top: top)
            return applyContrast(base(v, white: top), contrast, pivot: midGray)
        }
    }

    /// Base tone curve: Core Image's default RAW curve (≈ Adobe's ACR3 default) through shadows
    /// and midtones, then a shoulder that reaches display white exactly at `white`.
    private static func base(_ x: Double, white: Double) -> Double {
        guard x > baseKnee else { return interpolate(appleCurve, at: x) }
        guard x < white else { return 1 }
        // Rational shoulder r(u) = (1 + c)u / (u + c) on u ∈ [0, 1]: r(0) = 0, r(1) = 1, and
        // r'(0) continues the base curve's slope at the knee.
        let kneeValue = interpolate(appleCurve, at: baseKnee)
        let span = white - baseKnee
        let startSlope = baseKneeSlope * span / (1 - kneeValue)  // > 1 for any white ≥ baseWhite
        let c = 1 / (startSlope - 1)
        let u = (x - baseKnee) / span
        return kneeValue + (1 - kneeValue) * (1 + c) * u / (u + c)
    }

    private static let baseKnee = 0.46
    private static let baseKneeSlope = 0.86
    /// Where Core Image's default curve itself reaches white; the smallest allowed white point.
    static let baseWhite = 1.0746

    /// (scene-linear input, output) pairs of Core Image's default RAW rendering (`boostAmount` 1),
    /// measured on Leica M11 files. Matches Adobe's ACR3 default curve within one 8-bit level.
    private static let appleCurve: [(Double, Double)] = [
        (0, 0), (0.00027, 0.0001), (0.00053, 0.0003), (0.00107, 0.0007), (0.00214, 0.0015),
        (0.00428, 0.0033), (0.00855, 0.0072), (0.01208, 0.0109), (0.01708, 0.0169),
        (0.02417, 0.0270), (0.03424, 0.0437), (0.04832, 0.0711), (0.06812, 0.1156),
        (0.09654, 0.1870), (0.13648, 0.2877), (0.19258, 0.4140), (0.27256, 0.5534),
        (0.38555, 0.7004), (0.46016, 0.7722), (0.53864, 0.8326),
    ]

    // MARK: - JPEG

    /// Exposure, Highlights (positive only; negative uses CIHighlightShadowAdjust) and Contrast
    /// for already-rendered images. Returns the input unchanged when there is nothing to do.
    static func bitmap(_ image: CIImage, exposure: Double, highlights: Double, contrast: Double) -> CIImage {
        let exposureKey = Int((clamp(exposure, -5, 5) * 100).rounded())
        let highlightsKey = Int(clamp(highlights, 0, 100).rounded())
        let contrastKey = Int(clamp(contrast, -100, 100).rounded())
        guard exposureKey != 0 || highlightsKey != 0 || contrastKey != 0 else { return image }
        let key = TableKey.bitmap(exposure: exposureKey, highlights: highlightsKey, contrast: contrastKey)
        let table = table(for: key) {
            bitmapCurve(exposure: Double(exposureKey) / 100, highlights: Double(highlightsKey), contrast: Double(contrastKey))
        }
        return apply(table, to: image)
    }

    private static func bitmapCurve(exposure: Double, highlights: Double, contrast: Double) -> (Double) -> Double {
        let gain = pow(2, max(exposure, 0))
        return { x in
            var y: Double
            if exposure < 0 {
                y = negativeExposure(min(x, 1), exposure)
            } else {
                // Values pushed above white roll off instead of clipping.
                let v = x * gain
                let knee = 0.75
                y = v <= knee ? v : knee + (1 - knee) * (1 - exp(-(v - knee) / (1 - knee)))
            }
            if highlights > 0 {
                // Lift the upper tones in gamma space; the bump is 0 at both ends and monotonic.
                let s = encode(y)
                y = decode(s + 0.08 * highlights / 100 * 6.75 * s * s * (1 - s))
            }
            return applyContrast(y, contrast, pivot: 0.5)
        }
    }

    // MARK: - Building blocks

    /// Adobe's negative-exposure curve (`dng_function_exposure_tone`): linear darkening below a
    /// quarter of white, then a quadratic that still maps white to white.
    private static func negativeExposure(_ x: Double, _ exposure: Double) -> Double {
        let slope = pow(2, exposure)
        let a = 16.0 / 9.0 * (1 - slope)
        let b = slope - 0.5 * a
        let c = 1 - a - b
        guard x > 0.25 else { return x * slope }
        guard x < 1 else { return x }
        return (a * x + b) * x + c
    }

    /// Slider value (-100...100) to Highlights strength. Limits keep the curve monotonic:
    /// the log-space slope is `1 - amount * bump'`, and `bump'` ranges from -6.75 to 2.25.
    private static func highlightAmount(_ highlights: Double) -> Double {
        let h = highlights / 100
        return h < 0 ? -h * 0.4 : -h * 0.13
    }

    /// Scene value where Highlights starts; midtones below it are never touched.
    private static let highlightPivot = 0.3

    /// Reshapes tones between the pivot and `top` (display white), in stops. Positive `amount`
    /// darkens the upper highlights and spreads out the tones just below white, which the
    /// shoulder would otherwise squeeze together; negative brightens them. The pivot and `top`
    /// map to themselves, and the change fades in with zero slope at the pivot.
    private static func shiftHighlights(_ x: Double, amount: Double, top: Double) -> Double {
        let range = log2(top / highlightPivot)
        guard amount != 0, x > highlightPivot, x < top, range > 0 else { return x }
        let stops = log2(x / highlightPivot)
        let t = stops / range
        let bump = 6.75 * t * t * (1 - t)  // 0 at both ends, 1 at t = 2/3, flat at the pivot
        return highlightPivot * pow(2, stops - amount * range * bump)
    }

    /// S-curve in gamma space around `pivot` (an sRGB-encoded value that stays put). The slope
    /// at the pivot is `1 + 0.45 · contrast/100`; black and white stay fixed.
    private static func applyContrast(_ y: Double, _ contrast: Double, pivot: Double) -> Double {
        guard contrast != 0 else { return y }
        let gamma = max(1 + 0.45 * contrast / 100, 0.3)
        let s = encode(y)
        let out = s < pivot
            ? pivot * pow(s / pivot, gamma)
            : 1 - (1 - pivot) * pow((1 - s) / (1 - pivot), gamma)
        return decode(out)
    }

    private static func encode(_ y: Double) -> Double {
        let v = min(max(y, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func decode(_ s: Double) -> Double {
        let v = min(max(s, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func interpolate(_ points: [(Double, Double)], at x: Double) -> Double {
        guard let upper = points.firstIndex(where: { $0.0 >= x }) else { return points.last!.1 }
        guard upper > 0 else { return points[0].1 }
        let (x0, y0) = points[upper - 1], (x1, y1) = points[upper]
        return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        value.isFinite ? min(max(value, lower), upper) : 0
    }
}
