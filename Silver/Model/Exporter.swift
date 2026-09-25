import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExistingFilePolicy: String, CaseIterable, Identifiable, Sendable {
    case keepBoth
    case overwrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth: "Keep Both"
        case .overwrite: "Overwrite"
        }
    }
}

nonisolated struct ExportOptions: Sendable {
    var quality: Double
    var includeMetadata: Bool
    var existingFilePolicy: ExistingFilePolicy
}

nonisolated struct ExportJob: Sendable {
    let source: URL
    let settings: EditSettings
}

nonisolated enum ExportError: LocalizedError {
    case cannotDecode
    case cannotRender
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .cannotDecode: "The file could not be decoded."
        case .cannotRender: "The image could not be rendered."
        case .cannotWrite: "The JPEG file could not be written."
        }
    }
}

/// Renders full-resolution sRGB JPEGs.
nonisolated enum Exporter {
    private static let context = CIContext(options: [.name: "Silver.Export", .cacheIntermediates: false])

    /// Chooses `name.jpg` in `folder`, avoiding names already used in this batch and,
    /// unless overwriting, existing files.
    static func destination(for source: URL, in folder: URL, policy: ExistingFilePolicy, reserved: Set<String>) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = base + ".jpg"
        var index = 1
        func taken(_ name: String) -> Bool {
            if reserved.contains(name.lowercased()) { return true }
            return policy == .keepBoth && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        while taken(candidate) {
            candidate = "\(base)-\(index).jpg"
            index += 1
        }
        return folder.appendingPathComponent(candidate)
    }

    static func export(_ job: ExportJob, to destination: URL, options: ExportOptions) throws {
        guard let source = SourceImage(url: job.source, maxPixelSize: nil) else { throw ExportError.cannotDecode }
        guard let (image, _) = ImagePipeline.render(source, settings: job.settings, geometry: true),
              let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: ImagePipeline.sRGB)
        else { throw ExportError.cannotRender }

        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.cannotWrite }

        var properties = options.includeMetadata ? metadata(from: job.source, width: cgImage.width, height: cgImage.height) : [:]
        properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        properties[kCGImagePropertyOrientation] = 1

        CGImageDestinationAddImage(output, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ExportError.cannotWrite }
    }

    /// EXIF, GPS, IPTC and descriptive TIFF fields from the original, updated for the rendered image.
    private static func metadata(from url: URL, width: Int, height: Int) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }

        var result: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = original[key] { result[key] = value }
        }

        if var exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            exif[kCGImagePropertyExifColorSpace] = 1  // sRGB
            result[kCGImagePropertyExifDictionary] = exif
        }

        if let tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let descriptiveKeys = [
                kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription,
            ]
            var filtered = tiff.filter { descriptiveKeys.contains($0.key) }
            filtered[kCGImagePropertyTIFFSoftware] = "Silver"
            filtered[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = filtered
        }
        return result
    }
}
