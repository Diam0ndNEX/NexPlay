import UIKit
import UniformTypeIdentifiers

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

    /// Any file (ZIP, HTML, ...). iOS hands over temporary copies, which the caller should delete after importing.
    static func pickFiles(onPick: @escaping ([URL]) -> Void) {
        present(types: [.item], asCopy: true, onPick: onPick)
    }

    /// One or more folders, read in place (security-scoped).
    static func pickFolders(onPick: @escaping ([URL]) -> Void) {
        present(types: [.folder], asCopy: false, onPick: onPick)
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

    private static func present(types: [UTType], asCopy: Bool, multiple: Bool = true,
                                onPick: @escaping ([URL]) -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        while let next = top.presentedViewController { top = next }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        let delegate = ImportPicker(onPick: onPick)
        active = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        ImportPicker.active = nil
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        ImportPicker.active = nil
    }
}
