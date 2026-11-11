import UIKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

// Offline translation with MTool translation files (TranslateFile.json: original text → translation), an idea from
// ArkRPG. The hook wraps RPG Maker MV/MZ's text drawing; nothing is ever sent to an online service.

extension SettingsKey {
    /// Translation on for games that have no own setting (default off).
    static let translationEnabled = "translationEnabled"
}

enum TranslationStore {
    static let folder: URL = {
        let dir = Paths.support.appendingPathComponent("Translations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func gameFolder(_ game: Game) -> URL {
        let dir = folder.appendingPathComponent(game.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An imported dictionary wins over one that ships in the game folder.
    static func dictionaryURL(for game: Game) -> URL? {
        let imported = gameFolder(game).appendingPathComponent("TranslateFile.json")
        if FileManager.default.fileExists(atPath: imported.path) { return imported }
        let shipped = Paths.entryDirectory(for: game).appendingPathComponent("TranslateFile.json")
        if FileManager.default.fileExists(atPath: shipped.path) { return shipped }
        let root = Paths.folder(for: game).appendingPathComponent("TranslateFile.json")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    static func untranslatedURL(for game: Game) -> URL {
        gameFolder(game).appendingPathComponent("untranslated.json")
    }

    private static func key(_ game: Game) -> String { "translation.\(game.id.uuidString)" }

    /// Per-game override, else the app setting.
    static func isEnabled(for game: Game) -> Bool {
        guard game.engine.isRPGMaker else { return false }
        if let value = UserDefaults.standard.object(forKey: key(game)) as? Bool { return value }
        return UserDefaults.standard.bool(forKey: SettingsKey.translationEnabled)
    }

    static func setEnabled(_ value: Bool?, for game: Game) {
        if let value { UserDefaults.standard.set(value, forKey: key(game)) } else { UserDefaults.standard.removeObject(forKey: key(game)) }
    }

    /// Checks that a file is a JSON object of strings and copies it in as the game's dictionary.
    static func importDictionary(from url: URL, for game: Game) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let target = gameFolder(game).appendingPathComponent("TranslateFile.json")
        try data.write(to: target, options: .atomic)
        return object.count
    }

    static func loadUntranslated(for game: Game) -> [String] {
        guard let data = try? Data(contentsOf: untranslatedURL(for: game)),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func saveUntranslated(_ list: [String], for game: Game) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: untranslatedURL(for: game), options: .atomic)
        }
    }

    /// The collected untranslated lines as an MTool-style JSON object (each line maps to itself), ready to translate.
    static func exportUntranslated(for game: Game) throws -> URL {
        var object: [String: String] = [:]
        for line in loadUntranslated(for: game) { object[line] = line }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Paths.safeName(game.name))-untranslated.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The scheme handler serves the dictionary at /__nex/translate.json.
    static func fileOverride(for game: Game) -> ((String) -> Data?)? {
        guard isEnabled(for: game) else { return nil }
        return { path in
            guard path == "__nex/translate.json" else { return nil }
            guard let url = TranslationStore.dictionaryURL(for: game) else { return Data("{}".utf8) }
            return (try? Data(contentsOf: url)) ?? Data("{}".utf8)
        }
    }
}

final class TranslationFeature: PlayerFeature {
    private var collected = Set<String>()
    private var dirty = false

    /// Wraps text conversion and drawing. Whole strings are looked up first, then the text pieces between escape
    /// codes (\C[2], \V[1], \N[1]...). Unknown strings are reported to the app in batches.
    static let script = #"""
    (function () {
        var dict = {};
        try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/__nex/translate.json', false);
            xhr.send(null);
            if (xhr.status === 200) dict = JSON.parse(xhr.responseText) || {};
        } catch (e) { dict = {}; }
        var pending = [], seen = {};
        function report(text) {
            if (seen[text] || text.length > 2000) return;
            seen[text] = true;
            pending.push(text);
        }
        setInterval(function () {
            if (!pending.length) return;
            try { window.webkit.messageHandlers.nexTranslate.postMessage(pending.splice(0, 200)); } catch (e) { pending = []; }
        }, 2000);
        function hasLetters(text) { return /[^\s\d\p{P}]/u.test(text); }
        function lookup(text) {
            if (typeof text !== 'string' || !text) return text;
            if (Object.prototype.hasOwnProperty.call(dict, text)) return String(dict[text]);
            var trimmed = text.trim();
            if (trimmed !== text && Object.prototype.hasOwnProperty.call(dict, trimmed)) {
                return text.replace(trimmed, String(dict[trimmed]));
            }
            return null;
        }
        function translate(text) {
            var whole = lookup(text);
            if (whole !== null && whole !== undefined) return whole;
            var parts = String(text).split(/(\\[A-Za-z]+\[[^\]]*\]|\\[A-Za-z{}\\$.|!<>^]|\n)/);
            var changed = false;
            for (var i = 0; i < parts.length; i += 2) {
                var piece = parts[i];
                if (!piece || !hasLetters(piece)) continue;
                var found = lookup(piece);
                if (found !== null && found !== undefined) { parts[i] = found; changed = true; }
                else report(piece.trim());
            }
            return changed ? parts.join('') : text;
        }
        window.__nexTranslate = translate;
        (function hook() {
            if (typeof Window_Base === 'undefined' || typeof Bitmap === 'undefined') { setTimeout(hook, 200); return; }
            if (Window_Base.prototype.__nexTranslated) return;
            Window_Base.prototype.__nexTranslated = true;
            var convert = Window_Base.prototype.convertEscapeCharacters;
            Window_Base.prototype.convertEscapeCharacters = function (text) {
                return convert.call(this, translate(String(text)));
            };
            var drawText = Bitmap.prototype.drawText;
            Bitmap.prototype.drawText = function (text) {
                var args = Array.prototype.slice.call(arguments);
                if (typeof text === 'string' && hasLetters(text)) {
                    var found = lookup(text);
                    if (found !== null && found !== undefined) args[0] = found; else report(text.trim());
                }
                return drawText.apply(this, args);
            };
        })();
    })();
    """#

    override func userScripts(for game: Game) -> [WKUserScript] {
        guard TranslationStore.isEnabled(for: game) else { return [] }
        collected = Set(TranslationStore.loadUntranslated(for: game))
        context.gameLog.add(TranslationStore.dictionaryURL(for: game) == nil
                            ? "translation on, but no TranslateFile.json yet: collecting untranslated text"
                            : "translation on with TranslateFile.json")
        return [WKUserScript(source: TranslationFeature.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)]
    }

    override var messageNames: [String] { ["nexTranslate"] }

    override func receive(name: String, body: Any) {
        guard let lines = body as? [String] else { return }
        let before = collected.count
        for line in lines where !line.isEmpty && collected.count < 50_000 { collected.insert(line) }
        if collected.count != before { dirty = true }
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        TranslationStore.saveUntranslated(collected.sorted(), for: context.game())
    }

    override func didFinishLoad() {
        flush()
    }

    override func shutdown() {
        flush()
    }

    override func menuItems(for game: Game) -> [UIMenuElement] {
        guard game.engine.isRPGMaker else { return [] }
        return [UIAction(title: "Translation…", image: UIImage(systemName: "character.bubble")) { [weak self] _ in
            guard let self else { return }
            self.flush()
            let view = TranslationSettingsView(game: self.context.game(), onRestart: { [weak self] in self?.context.reload() })
            self.context.present(UIHostingController(rootView: view))
        }]
    }
}

/// Per-game translation settings: on/off, import a dictionary, export collected text, clear.
struct TranslationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let game: Game
    var onRestart: () -> Void = {}

    @State private var enabled = false
    @State private var hasDictionary = false
    @State private var untranslatedCount = 0
    @State private var importing = false
    @State private var shareURL: URL?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Translate this game", isOn: Binding(
                        get: { enabled },
                        set: { value in
                            enabled = value
                            TranslationStore.setEnabled(value, for: game)
                        }
                    ))
                    LabeledContent("Dictionary", value: hasDictionary ? "TranslateFile.json" : "None")
                    LabeledContent("Collected untranslated lines", value: "\(untranslatedCount)")
                } footer: {
                    Text("Uses an MTool translation file (TranslateFile.json: original text mapped to translated text), from the game folder or imported here. Works offline. Changes apply when the game restarts.")
                }
                Section {
                    Button("Import TranslateFile.json…") { importing = true }
                    Button("Export Untranslated Lines…") { exportLines() }
                        .disabled(untranslatedCount == 0)
                    Button("Clear Collected Lines", role: .destructive) {
                        TranslationStore.saveUntranslated([], for: game)
                        refresh()
                    }
                    .disabled(untranslatedCount == 0)
                    Button("Restart Game to Apply") {
                        dismiss()
                        onRestart()
                    }
                } footer: {
                    Text("Export the collected lines, translate the values elsewhere, then import the file back.")
                }
            }
            .navigationTitle("Translation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear { refresh() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
                if case .success(let url) = result { importDictionary(url) }
            }
            .sheet(item: Binding(
                get: { shareURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareURL = nil } }
            )) { item in ActivityView(items: [item.url]) }
            .alert("Translation", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }

    private func refresh() {
        enabled = TranslationStore.isEnabled(for: game)
        hasDictionary = TranslationStore.dictionaryURL(for: game) != nil
        untranslatedCount = TranslationStore.loadUntranslated(for: game).count
    }

    private func importDictionary(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try TranslationStore.importDictionary(from: url, for: game)
            if !enabled {
                enabled = true
                TranslationStore.setEnabled(true, for: game)
            }
            message = "Imported \(count) entries. Restart the game to see them."
        } catch {
            message = "That file is not a translation dictionary (a JSON object of texts)."
        }
        refresh()
    }

    private func exportLines() {
        do {
            shareURL = try TranslationStore.exportUntranslated(for: game)
        } catch {
            message = error.localizedDescription
        }
    }
}
