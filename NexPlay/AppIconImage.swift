import UIKit

/// NexPlay's own app icon as an image, for the control bar bubble (the same in every game).
/// Xcode copies the icon out of the asset catalog into the app as AppIcon60x60@2x.png and friends and lists the
/// names in Info.plist under CFBundleIcons; UIImage(named:) finds them there.
enum AppIconImage {
    static let image: UIImage? = {
        let info = Bundle.main.infoDictionary
        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            if let files = primary["CFBundleIconFiles"] as? [String] {
                for name in files.reversed() {
                    if let found = UIImage(named: name) { return found }
                }
            }
            if let name = primary["CFBundleIconName"] as? String, let found = UIImage(named: name) {
                return found
            }
        }
        return UIImage(named: "AppIcon")
    }()
}
