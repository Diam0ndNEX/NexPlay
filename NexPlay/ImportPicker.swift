import UIKit
import UniformTypeIdentifiers

/// The controller to present UIKit screens on: the app's own visible window (never a game core's SDL window or a
/// controls overlay window), walking up past screens that are already closing.
@MainActor
enum TopController {
    static func find() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene else { return nil }
        // 8.19.0: the key window can be the mkxp/EasyRPG SDL window or a controls overlay (windowLevel above normal)
        // left behind by a game; presenting on it showed nothing, so pickers looked dead. Prefer a visible
        // normal-level window, the key one among those first.
        let visible = scene.windows.filter { !$0.isHidden && $0.rootViewController != nil && $0.alpha > 0.01 }
        // A native game's controls window (above normal level) that shows its menu: present over that menu.
        if let overlay = visible.filter({ $0.windowLevel > .normal && $0.rootViewController?.presentedViewController != nil })
            .max(by: { $0.windowLevel < $1.windowLevel }) {
            var top = overlay.rootViewController
            while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
            return top
        }
        let normal = visible.filter { $0.windowLevel == .normal }
        let window = normal.first(where: \.isKeyWindow) ?? normal.first ?? visible.first(where: \.isKeyWindow) ?? visible.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// Presents `controller` once nothing is closing any more (a menu, a sheet or a dialog that was just tapped is
    /// usually still animating away, and UIKit drops a presentation started on top of it). Waits up to about 2 s.
    /// 8.20.2: never presents the same controller twice. 8.20.1 tried again when presentingViewController was still
    /// nil right after present(), but UIKit queues a presentation asked for while a menu closes, so the second
    /// present() of a controller that was already on its way stopped the app ("already being presented").
    static func present(_ controller: UIViewController, attempt: Int = 0) {
        if controller.presentingViewController != nil || controller.isBeingPresented { return }
        guard let top = find() else {
            AppLog.log("ui: no screen to present \(type(of: controller)) on")
            return
        }
        if top === controller { return }
        let busy = top.isBeingDismissed || top.isBeingPresented || top.transitionCoordinator != nil
            || top.presentedViewController?.isBeingDismissed == true
        if busy && attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { present(controller, attempt: attempt + 1) }
            return
        }
        prepareForPhone(controller, on: top)
        top.present(controller, animated: true)
    }

    /// A share sheet or other popover-style screen needs an anchor on iPad (UIKit stops the app without one).
    static func prepareForPhone(_ controller: UIViewController, on top: UIViewController) {
        if let popover = controller.popoverPresentationController, popover.sourceView == nil, popover.barButtonItem == nil {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
    }
}

/// Presents the system Files picker from UIKit. Files and folders use separate pickers: mixing both kinds
/// in one picker makes iOS treat "Open" as "open this folder", so a selected file does nothing.
@MainActor
final class ImportPicker: NSObject, UIDocumentPickerDelegate {
    /// The picker only holds its delegate weakly, so keep it alive while the picker is on screen.
    private static var active: ImportPicker?

    private let onPick: ([URL]) -> Void

    private init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
        super.init()
    }

    /// Game files (ZIP, 7z, RAR, HTML, SWF, EXE...). 8.19.0: opened in place (no copy), so a big archive is not
    /// copied by iOS before NexPlay even sees it (that copy took minutes with no progress and could fill the
    /// storage). The caller gets security-scoped URLs; LibraryStore holds the access while importing.
    static func pickFiles(onPick: @escaping ([URL]) -> Void) {
        // 8.20.7: copy mode. On this signing (App ID differs from the bundle id) iOS never answers an in-place pick
        // (Open does nothing, logs 8.20.2-8.20.6); copy mode answers. LibraryStore.removeTemporary deletes the copy.
        present(types: [.item], asCopy: true, onPick: onPick)
    }

    /// One or more folders, read in place (security-scoped).
    static func pickFolders(onPick: @escaping ([URL]) -> Void) {
        present(types: [.folder], asCopy: true, onPick: onPick)
    }

    /// 7.13.5: exactly one file of any type (pairing file). Single selection, so tapping the file picks it at once.
    /// SwiftUI's fileImporter on the JIT and Setup Center screens showed the picker but ignored taps on files.
    static func pickOneFile(onPick: @escaping (URL) -> Void) {
        var types: [UTType] = [.item, .data, .propertyList, .xmlPropertyList, .binaryPropertyList]
        if let pairing = UTType(filenameExtension: "mobiledevicepairing") { types.append(pairing) }
        present(types: types, asCopy: true, multiple: false) { urls in
            if let url = urls.first { onPick(url) }
        }
    }

    /// 8.19.0: one file of the given types, copied (small files: images, JSON, save ZIPs).
    static func pickCopy(types: [UTType], multiple: Bool = false, onPick: @escaping ([URL]) -> Void) {
        present(types: types, asCopy: true, multiple: multiple, onPick: onPick)
    }

    private static func present(types: [UTType], asCopy: Bool, multiple: Bool = true,
                                onPick: @escaping ([URL]) -> Void) {
        NexPickerFix.installIfNeeded()
        let delegate = ImportPicker(onPick: onPick)
        active = delegate
        AppLog.log("import: opening the Files picker (\(types.map(\.identifier).joined(separator: ", ")))")
        show(types: types, asCopy: asCopy, multiple: multiple, delegate: delegate, attempt: 0)
    }

    /// 8.20.5: a picker asked for while a menu (the + menu) is still closing can be dropped by UIKit without an error,
    /// and 8.20.2 never tried again, so nothing opened. 1.5 s later, if this pick is still wanted (not picked, not
    /// cancelled) and the picker is in no window, a NEW picker is presented (never the same one twice: that crashed
    /// in 8.20.1). Up to two more tries.
    private static func show(types: [UTType], asCopy: Bool, multiple: Bool, delegate: ImportPicker, attempt: Int) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        picker.shouldShowFileExtensions = true
        picker.delegate = delegate
        TopController.present(picker)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard active === delegate else { return }
            let onScreen = picker.viewIfLoaded?.window != nil || picker.presentingViewController != nil
                || picker.isBeingPresented
            if onScreen { return }
            if attempt >= 2 {
                AppLog.log("import: the Files picker did not open (3 tries)")
                active = nil
                return
            }
            AppLog.log("import: the Files picker did not open, opening a new one")
            show(types: types, asCopy: asCopy, multiple: multiple, delegate: delegate, attempt: attempt + 1)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        ImportPicker.active = nil
        AppLog.log("import: picked \(urls.count) item(s): \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        ImportPicker.active = nil
    }
}

/// Holds security-scoped access to a picked URL while imports that need it are queued or running; access ends when
/// the last holder lets go.
final class ScopedAccess: @unchecked Sendable {
    let url: URL
    private let started: Bool

    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}
