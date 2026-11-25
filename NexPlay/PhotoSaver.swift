import UIKit
import Photos

/// 8.19.0: screenshots and media to Photos. Asks for add-only access first and reports whether it worked
/// (UIImageWriteToSavedPhotosAlbum alone said "Saved" even when access was denied).
enum PhotoSaver {
    static func save(_ image: UIImage, completion: (@MainActor (Bool) -> Void)? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                AppLog.log("photos: no permission to add photos (status \(status.rawValue))")
                Task { @MainActor in completion?(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { ok, error in
                if let error { AppLog.log("photos: saving failed: \(error.localizedDescription)") }
                Task { @MainActor in completion?(ok) }
            }
        }
    }

    /// The Settings switch "Screenshots to Photos" (on unless turned off).
    static var screenshotsWanted: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.screenshotsToPhotos) as? Bool ?? true
    }
}
