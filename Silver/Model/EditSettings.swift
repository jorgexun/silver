import CoreGraphics
import Foundation

/// Non-destructive edit parameters for one photo. Persisted as `<name>.edit.json` next to the original.
nonisolated struct EditSettings: Equatable, Hashable, Sendable {
    // Light
    var exposure: Double = 0      // EV, -5...5
    var contrast: Double = 0      // -100...100
    var highlights: Double = 0    // -100...100
    var shadows: Double = 0       // -100...100

    // Color
    var temperature: Double = 0   // -100...100, relative to as-shot white balance
    var tint: Double = 0          // -100...100, relative to as-shot white balance
    var vibrance: Double = 0      // -100...100
    var saturation: Double = 0    // -100...100

    // Geometry
    /// Crop rectangle, normalized to the oriented image, top-left origin, in the straightened frame.
    var crop: CropRect = .full
    /// Straighten angle in degrees, positive rotates the image clockwise.
    var straighten: Double = 0    // -45...45
    /// Aspect ratio constraint used by the crop tool.
    var aspectRatio: AspectRatio = .original

    static let `default` = EditSettings()

    var isDefault: Bool { self == .default }

    var hasGeometry: Bool { crop != .full || straighten != 0 }

    /// Returns a copy with the given groups taken from `source`.
    func merging(_ groups: AdjustmentGroups, from source: EditSettings) -> EditSettings {
        var result = self
        if groups.contains(.light) {
            result.exposure = source.exposure
            result.contrast = source.contrast
            result.highlights = source.highlights
            result.shadows = source.shadows
        }
        if groups.contains(.whiteBalance) {
            result.temperature = source.temperature
            result.tint = source.tint
        }
        if groups.contains(.color) {
            result.vibrance = source.vibrance
            result.saturation = source.saturation
        }
        if groups.contains(.geometry) {
            result.crop = source.crop
            result.straighten = source.straighten
            result.aspectRatio = source.aspectRatio
        }
        return result
    }
}

extension EditSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, exposure, contrast, highlights, shadows, temperature, tint, vibrance, saturation, crop, straighten, aspectRatio
    }

    static let currentVersion = 1

    /// Values are clamped to the slider ranges, so a hand-edited or damaged sidecar can't
    /// produce settings the UI could never create.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, in range: ClosedRange<Double>) -> Double {
            guard let v = try? c.decodeIfPresent(Double.self, forKey: key), v.isFinite else { return 0 }
            return min(max(v, range.lowerBound), range.upperBound)
        }
        exposure = value(.exposure, in: -5...5)
        contrast = value(.contrast, in: -100...100)
        highlights = value(.highlights, in: -100...100)
        shadows = value(.shadows, in: -100...100)
        temperature = value(.temperature, in: -100...100)
        tint = value(.tint, in: -100...100)
        vibrance = value(.vibrance, in: -100...100)
        saturation = value(.saturation, in: -100...100)
        straighten = value(.straighten, in: -45...45)
        let decodedCrop = try? c.decodeIfPresent(CropRect.self, forKey: .crop)
        crop = decodedCrop.flatMap { $0.isValid ? $0 : nil } ?? .full
        aspectRatio = (try? c.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)) ?? .original
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(crop, forKey: .crop)
        try c.encode(straighten, forKey: .straighten)
        try c.encode(aspectRatio, forKey: .aspectRatio)
    }
}

/// Groups of settings that can be copied between photos.
nonisolated struct AdjustmentGroups: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let light = AdjustmentGroups(rawValue: 1 << 0)
    static let whiteBalance = AdjustmentGroups(rawValue: 1 << 1)
    static let color = AdjustmentGroups(rawValue: 1 << 2)
    static let geometry = AdjustmentGroups(rawValue: 1 << 3)

    static let `default`: AdjustmentGroups = [.light, .whiteBalance, .color]
    static let all: AdjustmentGroups = [.light, .whiteBalance, .color, .geometry]
}

/// A rectangle in normalized (0...1) coordinates with a top-left origin.
nonisolated struct CropRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.init(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    /// Finite, at least the minimum size, and inside the image.
    var isValid: Bool {
        let tolerance = 1e-6
        return [x, y, width, height].allSatisfy(\.isFinite)
            && width >= CropGeometry.minimumSize && height >= CropGeometry.minimumSize
            && x >= -tolerance && y >= -tolerance && maxX <= 1 + tolerance && maxY <= 1 + tolerance
    }

    func interpolated(to other: CropRect, _ t: Double) -> CropRect {
        CropRect(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t,
            width: width + (other.width - width) * t,
            height: height + (other.height - height) * t
        )
    }

    /// Rounds components so sidecar files stay readable.
    var rounded: CropRect {
        func r(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }
        return CropRect(x: r(x), y: r(y), width: r(width), height: r(height))
    }
}

/// Crop aspect ratio constraint. Fixed ratios follow the orientation of the current crop.
nonisolated enum AspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case free
    case original
    case square
    case ratio5x4
    case ratio4x3
    case ratio3x2
    case ratio16x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1 : 1"
        case .ratio5x4: "5 : 4"
        case .ratio4x3: "4 : 3"
        case .ratio3x2: "3 : 2"
        case .ratio16x9: "16 : 9"
        }
    }

    /// Long side divided by short side, or nil for a free crop.
    func longToShort(imageSize: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original:
            Double(max(imageSize.width, imageSize.height) / max(min(imageSize.width, imageSize.height), 1))
        case .square: 1
        case .ratio5x4: 5.0 / 4.0
        case .ratio4x3: 4.0 / 3.0
        case .ratio3x2: 3.0 / 2.0
        case .ratio16x9: 16.0 / 9.0
        }
    }
}
