import CoreImage
import Foundation
import ImageIO

nonisolated enum Thumbnails {
    static let maxPixelSize: CGFloat = 480

    private static let context = CIContext(options: [.name: "Silver.Thumbnails", .cacheIntermediates: false])

    /// Fast thumbnail from the file's embedded preview.
    static func embedded(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The file's embedded preview at screen size, in `colorSpace` and Core Animation's BGRA
    /// layout, to show while the photo itself is decoded: about 0.15 s instead of 0.8 s for M11
    /// files. Drawn on the CPU so it doesn't wait for a Core Image context busy decoding.
    static func screenPreview(url: URL, maxPixelSize: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .none  // Same size: just color conversion.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Thumbnail rendered through the edit pipeline.
    static func rendered(url: URL, settings: EditSettings) -> CGImage? {
        // Oversample 2x for a crisper downscale.
        guard let source = SourceImage(url: url, maxPixelSize: maxPixelSize * 2) else { return nil }
        source.ensureLongEdge(source.longEdgeNeeded(for: settings.crop, outputPixelSize: maxPixelSize * 2))
        guard let (image, _) = ImagePipeline.render(source, settings: settings, geometry: true, context: context)
        else { return nil }
        return downscale(image, maxPixelSize: maxPixelSize, context: context)
    }

    static func downscale(_ image: CIImage, maxPixelSize: CGFloat, context: CIContext) -> CGImage? {
        let longEdge = max(image.extent.width, image.extent.height)
        var output = image
        if longEdge > maxPixelSize {
            let scale = maxPixelSize / longEdge
            output = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1,
            ])
        }
        return ImagePipeline.bitmap(output, from: output.extent.integral, context: context)
    }
}

/// Shooting information shown in the inspector.
nonisolated struct PhotoMetadata: Sendable {
    var pixelSize: CGSize?
    var camera: String?
    var lens: String?
    /// Focal length, aperture, shutter speed and ISO, as far as known.
    var exposure: [String] = []
    var captureDate: Date?

    static func load(url: URL) -> PhotoMetadata {
        var result = PhotoMetadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return result }

        if let width = props[kCGImagePropertyPixelWidth] as? Double,
           let height = props[kCGImagePropertyPixelHeight] as? Double {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            result.pixelSize = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        if let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            result.camera = model.localizedCaseInsensitiveContains(make.components(separatedBy: " ").first ?? "") ? model : "\(make) \(model)"
        }
        result.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String)

        var parts: [String] = []
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
            parts.append("\(Int(focal.rounded())) mm")
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double, aperture > 0 {
            parts.append(String(format: "ƒ/%.1f", aperture).replacingOccurrences(of: ".0", with: ""))
        }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            parts.append(time >= 1 ? String(format: "%g s", time) : "1/\(Int((1 / time).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
            parts.append("ISO \(iso)")
        }
        result.exposure = parts

        if let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            result.captureDate = formatter.date(from: dateString)
        }
        return result
    }
}
