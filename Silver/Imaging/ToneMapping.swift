import CoreImage
import Foundation
import Synchronization

/// Tone mapping: exposure, the base tone curve and Contrast, combined into one curve that
/// `ToneKernels.metal` applies with Adobe's hue-preserving `RGBTone` method, after the local
/// exposure change of Highlights and Shadows.
///
/// The curves are evaluated on the CPU into lookup tables (images one pixel high), so any
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

    private static let metalLibrary: Data? = metalLibraryURL.flatMap { try? Data(contentsOf: $0) }

    static func kernel(_ name: String) -> CIKernel? {
        metalLibrary.flatMap { try? CIKernel(functionName: name, fromMetalLibraryData: $0) }
    }

    static func colorKernel(_ name: String) -> CIColorKernel? {
        metalLibrary.flatMap { try? CIColorKernel(functionName: name, fromMetalLibraryData: $0) }
    }

    private static let kernels = kernel("rgbTone").flatMap { global in kernel("rgbToneLocal").map { (global: global, local: $0) } }

    /// Applies `table`, after the local exposure change of `local` if there is one.
    private static func apply(_ table: CIImage, to image: CIImage, exposure: Double, local: LocalAdjustment?) -> CIImage {
        guard let kernels else {
            assertionFailure("Tone kernels are missing from the Metal library")
            return image
        }
        let extent = image.extent
        let tableExtent = table.extent
        let maxEncoded = Float(pow(domain, encodePower))
        guard let local else {
            return kernels.global.apply(
                extent: extent,
                roiCallback: { index, rect in index == 0 ? rect : tableExtent },
                arguments: [image, table, maxEncoded, Float(samples)]
            ) ?? image
        }
        // Stretch the coefficients over the image; they are sampled bilinearly.
        let small = local.coefficients.extent
        let coefficients = local.coefficients
            .clampedToExtent()
            .samplingLinear()
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
                .scaledBy(x: extent.width / small.width, y: extent.height / small.height)
                .translatedBy(x: -small.minX, y: -small.minY))
        return kernels.local.apply(
            extent: extent,
            roiCallback: { index, rect in index == 0 ? rect : index == 1 ? rect.insetBy(dx: -1, dy: -1) : tableExtent },
            arguments: [
                image, coefficients, table, maxEncoded, Float(samples), Float(exposure - log2(0.18)),
                Float(clamp(local.highlights, -100, 100) / 100 * localStrength),
                Float(clamp(local.shadows, -100, 100) / 100 * localStrength),
            ]
        ) ?? image
    }

    /// Scene values the table entries are sampled at.
    private static let sampleInputs: [Double] = {
        let maxEncoded = pow(domain, encodePower)
        return (0..<samples).map { pow(maxEncoded * Double($0) / Double(samples - 1), 1 / encodePower) }
    }()

    private static func makeTable(_ f: (Double) -> Double) -> CIImage {
        // Built on every step of a slider drag, so it writes into one buffer.
        var data = Data(count: samples * 16)
        data.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            for (i, x) in sampleInputs.enumerated() {
                let y = Float(min(max(f(x), 0), 1))
                values[i * 4] = y
                values[i * 4 + 1] = y
                values[i * 4 + 2] = y
                values[i * 4 + 3] = 1
            }
        }
        // No color space: the values are used as-is, without color management.
        return CIImage(bitmapData: data, bytesPerRow: samples * 16, size: CGSize(width: samples, height: 1), format: .RGBAf, colorSpace: nil)
    }

    /// Recently used tables, most recent last.
    private static let tables = Mutex<[(key: TableKey, table: CIImage)]>([])
    private static let tableCacheLimit = 32

    private enum TableKey: Hashable {
        case raw(exposure: Int, contrast: Int)
        case bitmap(exposure: Int, contrast: Int)
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

    // MARK: - Highlights and Shadows

    /// Highlights −100 halves the distance in stops of bright regions above mid gray (after
    /// exposure), and Shadows +100 halves it for dark regions below, up to 2 stops. Positions
    /// relative to mid gray make the same settings reach further on photos with a wider range.
    /// Both fade in over their first stop from mid gray (see `rgbToneLocal`).
    private static let localStrength = 0.5

    // MARK: - RAW

    /// Develops scene-linear RAW output (white balance applied, highlight headroom kept) for display.
    static func raw(_ image: CIImage, exposure: Double, contrast: Double, local: LocalAdjustment?) -> CIImage {
        // Quantize to the cache key so equal keys always produce equal tables.
        let exposureKey = Int((clamp(exposure, -5, 5) * 100).rounded())
        let contrastKey = Int(clamp(contrast, -100, 100).rounded())
        let table = table(for: .raw(exposure: exposureKey, contrast: contrastKey)) {
            rawCurve(exposure: Double(exposureKey) / 100, contrast: Double(contrastKey))
        }
        return apply(table, to: image, exposure: Double(exposureKey) / 100, local: local)
    }

    /// Scene value (at exposure 0) that becomes display white. Fixed rather than measured per image:
    /// measuring costs about 0.12 s per photo opened or exported. 6 covers the brightest levels seen
    /// in M11 files (sensor clipping lands between about 1.3 and 5.9 depending on the image and white
    /// balance), so Highlights can still recover that headroom; clipped areas render at 249–254.
    static let sceneWhite = 6.0

    /// Scene value → display value for RAW files.
    private static func rawCurve(exposure: Double, contrast: Double) -> (Double) -> Double {
        let white = sceneWhite
        let gain = pow(2, max(exposure, 0))
        // Positive exposure moves the white point up with the image; negative exposure keeps it,
        // so clipped highlights stay white while the rest darkens (as in Adobe's DNG SDK).
        let top = white * gain
        let midGray = encode(base(0.18, white: baseWhite))
        let darken = NegativeExposure(exposure)
        return { x in
            let v = exposure < 0 ? white * darken(x / white) : x * gain
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
        let span = white - baseKnee
        let startSlope = baseKneeSlope * span / (1 - kneeValue)  // > 1 for any white ≥ baseWhite
        let c = 1 / (startSlope - 1)
        let u = (x - baseKnee) / span
        return kneeValue + (1 - kneeValue) * (1 + c) * u / (u + c)
    }

    private static let baseKnee = 0.46
    private static let baseKneeSlope = 0.86
    private static let kneeValue = interpolate(appleCurve, at: baseKnee)
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

    /// Exposure, Contrast, Highlights and Shadows for already-rendered images, which are treated
    /// like scene values with white at 1. Returns the input unchanged when there is nothing to do.
    static func bitmap(_ image: CIImage, exposure: Double, contrast: Double, local: LocalAdjustment?) -> CIImage {
        let exposureKey = Int((clamp(exposure, -5, 5) * 100).rounded())
        let contrastKey = Int(clamp(contrast, -100, 100).rounded())
        guard exposureKey != 0 || contrastKey != 0 || local != nil else { return image }
        let table = table(for: .bitmap(exposure: exposureKey, contrast: contrastKey)) {
            bitmapCurve(exposure: Double(exposureKey) / 100, contrast: Double(contrastKey))
        }
        return apply(table, to: image, exposure: Double(exposureKey) / 100, local: local)
    }

    private static func bitmapCurve(exposure: Double, contrast: Double) -> (Double) -> Double {
        let gain = pow(2, max(exposure, 0))
        let darken = NegativeExposure(exposure)
        let knee = 0.75
        // Positive exposure rolls values pushed above white off with a rational shoulder that
        // continues the slope at the knee and reaches white where white itself lands.
        let startSlope = (gain - knee) / (1 - knee)
        let c = startSlope > 1.0001 ? 1 / (startSlope - 1) : nil
        return { x in
            let y: Double
            if exposure < 0 {
                y = darken(min(x, 1))
            } else if let c, x * gain > knee {
                let u = min((x * gain - knee) / (gain - knee), 1)
                y = knee + (1 - knee) * (1 + c) * u / (u + c)
            } else {
                y = min(x * gain, 1)
            }
            return applyContrast(y, contrast, pivot: 0.5)
        }
    }

    // MARK: - Building blocks

    /// Adobe's negative-exposure curve (`dng_function_exposure_tone`): linear darkening below a
    /// quarter of white, then a quadratic that still maps white to white.
    private struct NegativeExposure {
        let slope, a, b, c: Double

        init(_ exposure: Double) {
            slope = pow(2, exposure)
            a = 16.0 / 9.0 * (1 - slope)
            b = slope - 0.5 * a
            c = 1 - a - b
        }

        func callAsFunction(_ x: Double) -> Double {
            guard x > 0.25 else { return x * slope }
            guard x < 1 else { return x }
            return (a * x + b) * x + c
        }
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
