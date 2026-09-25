import CoreGraphics
import Foundation

/// Geometry helpers for crop rectangles living in the straightened image frame.
///
/// The straightened frame has the same size as the oriented image (`imageSize`), with the image rotated
/// about its center by the straighten angle. A crop is valid when it lies inside that frame and inside
/// the rotated image, so the output never contains empty corners.
nonisolated enum CropGeometry {
    static let minimumSize = 0.02

    /// Inset (as a fraction of the half size) that keeps crops safely away from interpolated rotated edges.
    private static func limits(_ imageSize: CGSize, angle: Double) -> (Double, Double) {
        let inset = angle == 0 ? 1.0 : 0.998
        return (Double(imageSize.width) / 2 * inset, Double(imageSize.height) / 2 * inset)
    }

    /// Corners of `rect` in pixels relative to the image center (y down).
    private static func corners(of rect: CropRect, imageSize: CGSize) -> [(Double, Double)] {
        let w = Double(imageSize.width), h = Double(imageSize.height)
        let left = rect.minX * w - w / 2
        let right = rect.maxX * w - w / 2
        let top = rect.minY * h - h / 2
        let bottom = rect.maxY * h - h / 2
        return [(left, top), (right, top), (right, bottom), (left, bottom)]
    }

    /// Maximum factor by which the corners may be scaled about the image center while staying valid.
    private static func maxScale(of rect: CropRect, angle: Double, imageSize: CGSize) -> Double {
        let (limitX, limitY) = limits(imageSize, angle: angle)
        let theta = angle * .pi / 180
        let c = cos(theta), s = sin(theta)
        var k = Double.infinity
        for (px, py) in corners(of: rect, imageSize: imageSize) {
            // Inside the frame.
            if abs(px) > 1e-9 { k = min(k, Double(imageSize.width) / 2 / abs(px)) }
            if abs(py) > 1e-9 { k = min(k, Double(imageSize.height) / 2 / abs(py)) }
            // Inside the rotated image: rotate the corner back into image space.
            let ix = px * c + py * s
            let iy = -px * s + py * c
            if abs(ix) > 1e-9 { k = min(k, limitX / abs(ix)) }
            if abs(iy) > 1e-9 { k = min(k, limitY / abs(iy)) }
        }
        return k
    }

    static func fits(_ rect: CropRect, angle: Double, imageSize: CGSize) -> Bool {
        maxScale(of: rect, angle: angle, imageSize: imageSize) >= 1 - 1e-9
    }

    /// Shrinks `rect` toward the image center until it fits. Preserves the aspect ratio.
    static func fitted(_ rect: CropRect, angle: Double, imageSize: CGSize) -> CropRect {
        let k = maxScale(of: rect, angle: angle, imageSize: imageSize)
        guard k < 1 else { return rect }
        return CropRect(
            x: (rect.x - 0.5) * k + 0.5,
            y: (rect.y - 0.5) * k + 0.5,
            width: rect.width * k,
            height: rect.height * k
        )
    }

    /// Largest centered crop with the given pixel aspect ratio (width / height) that fits.
    static func largestRect(pixelAspect: Double, angle: Double, imageSize: CGSize) -> CropRect {
        let imageAspect = Double(imageSize.width / imageSize.height)
        let normalizedAspect = pixelAspect / imageAspect
        let width = normalizedAspect >= 1 ? 1 : normalizedAspect
        let height = normalizedAspect >= 1 ? 1 / normalizedAspect : 1
        let rect = CropRect(centerX: 0.5, centerY: 0.5, width: width, height: height)
        return fitted(rect, angle: angle, imageSize: imageSize)
    }

    /// Moves from a valid rect toward `proposal` as far as possible while staying valid.
    static func constrained(from valid: CropRect, to proposal: CropRect, angle: Double, imageSize: CGSize) -> CropRect {
        if fits(proposal, angle: angle, imageSize: imageSize) { return proposal }
        guard fits(valid, angle: angle, imageSize: imageSize) else {
            return fitted(proposal, angle: angle, imageSize: imageSize)
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if fits(valid.interpolated(to: proposal, mid), angle: angle, imageSize: imageSize) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return valid.interpolated(to: proposal, lo)
    }

    /// Pixel aspect ratio (width / height) of a normalized rect.
    static func pixelAspect(of rect: CropRect, imageSize: CGSize) -> Double {
        (rect.width * Double(imageSize.width)) / max(rect.height * Double(imageSize.height), 1e-9)
    }

    /// Target pixel aspect for a constraint, following the orientation of `rect`.
    static func pixelAspect(for ratio: AspectRatio, matching rect: CropRect, imageSize: CGSize) -> Double? {
        guard let longToShort = ratio.longToShort(imageSize: imageSize) else { return nil }
        return pixelAspect(of: rect, imageSize: imageSize) >= 1 ? longToShort : 1 / longToShort
    }
}
