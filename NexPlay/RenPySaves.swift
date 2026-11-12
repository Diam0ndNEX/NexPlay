import UIKit
import WebKit
import UniformTypeIdentifiers
import ZIPFoundation

// Ren'Py saves live inside RenPyWeb (IDBFS: IndexedDB of the game's local-server origin). RenPyWeb can zip them
// (renpy.savelocation.zip_saves) and unzip a ZIP of save files (unzip_saves); the page's own ≡ menu uses the same
// calls (renpy-pre.js onSavegamesExport/Import). Ren'Py 7 uses the C helpers Module._emSavegamesExport/Import.
// This feature runs them from the game menu, so desktop saves (*.save + persistent) can be brought over and saves
// can be backed up into Backups/<game-uuid>/.

enum RenPySaves {
    /// Files of a Ren'Py save folder worth moving.
    static func isSaveFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "save" || name == "persistent"
    }

    /// A ZIP with the save files of what was picked (ZIPs, folders, loose files) at its top level, the layout
    /// unzip_saves reads. Returns nil when nothing looks like a Ren'Py save.
    static func collect(_ urls: [URL]) throws -> (zip: URL, count: Int)? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("renpy-saves-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var found: [String: URL] = [:]

        func take(_ file: URL) {
            guard isSaveFile(file) else { return }
            let name = file.lastPathComponent
            // When the same save sits in several places, the newest copy wins.
            if let old = found[name] {
                let oldDate = (try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let newDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newDate <= oldDate { return }
            }
            found[name] = file
        }

        func walk(_ folder: URL) {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in walker {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { take(url) }
            }
        }

        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let copy = temp.appendingPathComponent("folder-\(index)", isDirectory: true)
                try fm.copyItem(at: url, to: copy)
                walk(copy)
            } else if url.pathExtension.lowercased() == "zip" {
                let folder = temp.appendingPathComponent("zip-\(index)", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: folder)
                walk(folder)
            } else {
                let copy = temp.appendingPathComponent("file-\(index)-" + url.lastPathComponent)
                try fm.copyItem(at: url, to: copy)
                // Keep the real name for the ZIP entry.
                let named = temp.appendingPathComponent("named-\(index)", isDirectory: true)
                try fm.createDirectory(at: named, withIntermediateDirectories: true)
                let target = named.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: copy, to: target)
                take(target)
            }
        }
        guard !found.isEmpty else { return nil }
        let zip = fm.temporaryDirectory.appendingPathComponent("renpy-import-\(UUID().uuidString).zip")
        let writer = try StoredZipWriter(url: zip)
        for (name, file) in found.sorted(by: { $0.key < $1.key }) {
            try writer.add(name: name, file: file)
        }
        try writer.finish()
        return (zip, found.count)
    }

    /// Imports a ZIP of save files into the running game. Ren'Py 8 unzips with renpy.savelocation.unzip_saves,
    /// Ren'Py 7 with Module._emSavegamesImport; then the files are written to IndexedDB and the save list rescanned.
    static let importScript = #"""
    const bytes = Uint8Array.from(atob(data), function (c) { return c.charCodeAt(0); });
    if (typeof FS === 'undefined') { throw new Error('Ren\'Py is not running yet. Wait for the main menu and try again.'); }
    FS.writeFile('savegames.zip', bytes);
    if (typeof Module !== 'undefined' && typeof Module._emSavegamesImport === 'function') {
        Module._emSavegamesImport();
    } else if (typeof renpy_exec === 'function') {
        await renpy_exec('result = renpy.savelocation.unzip_saves()');
    } else {
        throw new Error('This Ren\'Py runtime has no save import.');
    }
    await new Promise(function (resolve, reject) { FS.syncfs(false, function (err) { if (err) { reject(err); } else { resolve(); } }); });
    if (typeof renpy_exec === 'function') {
        try { await renpy_exec('renpy.loadsave.location.scan()'); } catch (e) {}
    }
    return 'ok';
    """#

    /// Zips the running game's saves and returns them as base64.
    static let exportScript = #"""
    if (typeof FS === 'undefined') { throw new Error('Ren\'Py is not running yet. Wait for the main menu and try again.'); }
    let made = false;
    if (typeof Module !== 'undefined' && typeof Module._emSavegamesExport === 'function') {
        made = !!Module._emSavegamesExport();
    } else if (typeof renpy_exec === 'function') {
        made = !!(await renpy_exec('result = renpy.savelocation.zip_saves()'));
    }
    if (!made) { throw new Error('Ren\'Py could not zip its saves.'); }
    const bytes = FS.readFile('savegames.zip');
    let text = '';
    const step = 0x8000;
    for (let i = 0; i < bytes.length; i += step) {
        text += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
    }
    return btoa(text);
    """#
}

/// Game menu entries for Ren'Py saves: export (share sheet), back up into Backups/, import from Files.
@MainActor
final class RenPySavesFeature: PlayerFeature {
    private var picker: PickerDelegate?

    override func menuItems(for game: Game) -> [UIMenuElement] {
        guard game.engine == .renpy else { return [] }
        return [UIMenu(title: "Ren'Py Saves", image: UIImage(systemName: "externaldrive.fill"), children: [
            UIAction(title: "Export Saves (ZIP)…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.export(backup: false)
            },
            UIAction(title: "Back Up Saves Now", image: UIImage(systemName: "archivebox")) { [weak self] _ in
                self?.export(backup: true)
            },
            UIAction(title: "Import Saves (.save, Folder or ZIP)…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                self?.pickImport()
            },
        ])]
    }

    private func export(backup: Bool) {
        guard let webView = context.webView else { return }
        let game = context.game()
        Task { @MainActor in
            do {
                let value = try await webView.callAsyncJavaScript(RenPySaves.exportScript, arguments: [:], in: nil, contentWorld: .page)
                guard let text = value as? String, let data = Data(base64Encoded: text) else { throw SaveToolsError.badResult }
                let name = "\(Paths.safeName(game.name))-renpy-saves-\(Paths.timestamp()).zip"
                if backup {
                    let folder = Paths.backupFolder(for: game)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: folder.appendingPathComponent("renpy-\(Paths.timestamp()).zip"), options: .atomic)
                    context.gameLog.add("ren'py saves backed up (\(data.count / 1024) KB)")
                    alert("Saves backed up", "The backup is in Manage Saves > Backups. To restore it, use Import Saves here.")
                } else {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    try data.write(to: url, options: .atomic)
                    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    sheet.popoverPresentationController?.sourceView = webView
                    sheet.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
                    context.present(sheet)
                }
            } catch {
                context.gameLog.add("ren'py save export failed: \(error.localizedDescription)")
                alert("Couldn't export the saves", error.localizedDescription)
            }
        }
    }

    private func pickImport() {
        let types: [UTType] = [.zip, .folder, .item]
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        controller.allowsMultipleSelection = true
        let delegate = PickerDelegate { [weak self] urls in self?.importSaves(urls) }
        picker = delegate
        controller.delegate = delegate
        context.present(controller)
    }

    private func importSaves(_ urls: [URL]) {
        picker = nil
        guard let webView = context.webView, !urls.isEmpty else { return }
        Task { @MainActor in
            do {
                let collected = try await Task.detached(priority: .userInitiated) { try RenPySaves.collect(urls) }.value
                for url in urls { try? FileManager.default.removeItem(at: url) }
                guard let collected else {
                    alert("No Ren'Py saves found", "Pick .save files (and the persistent file), a saves folder, or a ZIP of one. On a PC they are in the game's game/saves folder or in %APPDATA%/RenPy/<game>.")
                    return
                }
                defer { try? FileManager.default.removeItem(at: collected.zip) }
                // A safety copy of the current saves first, when the game can make one.
                if let current = try? await webView.callAsyncJavaScript(RenPySaves.exportScript, arguments: [:], in: nil, contentWorld: .page),
                   let text = current as? String, let data = Data(base64Encoded: text) {
                    let folder = Paths.backupFolder(for: context.game())
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? data.write(to: folder.appendingPathComponent("before-import-renpy-\(Paths.timestamp()).zip"), options: .atomic)
                }
                let data = try Data(contentsOf: collected.zip)
                _ = try await webView.callAsyncJavaScript(RenPySaves.importScript, arguments: ["data": data.base64EncodedString()],
                                                          in: nil, contentWorld: .page)
                context.gameLog.add("ren'py: imported \(collected.count) save file(s)")
                alert("Saves imported", "Imported \(collected.count) file(s). If they don't show in Load yet, restart the game from the menu.")
            } catch {
                context.gameLog.add("ren'py save import failed: \(error.localizedDescription)")
                alert("Couldn't import the saves", error.localizedDescription)
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "OK", style: .default))
        // The document picker may still be closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.context.present(controller) }
    }

    /// Keeps the document picker's delegate alive while it is on screen.
    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
