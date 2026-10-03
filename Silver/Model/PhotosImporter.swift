import AppKit
import Photos

/// Adds exported JPEGs to the Photos library. Silver only asks to add photos, never to read
/// the library, so it doesn't put them in an album or look for earlier imports.
nonisolated enum PhotosImporter {
    static var isDenied: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .denied, .restricted: true
        default: false
        }
    }

    /// Asks for access the first time; later calls return the user's answer.
    static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
    }

    /// Adds the JPEG at `url`. Moving hands the file to Photos instead of copying it.
    static func add(_ url: URL, moving: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = moving
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openPhotos() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
