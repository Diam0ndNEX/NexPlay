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

    /// The scheme handler serves the dictionary at /__nex/translate.json: machine translations (8.18.0) with the
    /// MTool dictionary on top (a person's translation wins over the machine's).
    /// 8.18.0: installed for every RPG Maker game and checked when the page asks, so turning translation on and
    /// restarting the game is enough. "null" = translation is off (the page script then does nothing).
    static func fileOverride(for game: Game) -> ((String) -> Data?)? {
        guard game.engine.isRPGMaker else { return nil }
        let gameID = game.id
        return { path in
            guard path == "__nex/translate.json" else { return nil }
            guard TranslationStore.isActive(for: game) else { return Data("null".utf8) }
            var merged: [String: Any] = MachineTranslation.load(gameID)
            if let url = TranslationStore.dictionaryURL(for: game), let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                merged.merge(object) { _, own in own }
            }
            if merged.isEmpty { return Data("{}".utf8) }
            return (try? JSONSerialization.data(withJSONObject: merged)) ?? Data("{}".utf8)
        }
    }

    /// The translation hook runs with a dictionary or with machine translation.
    static func isActive(for game: Game) -> Bool {
        isEnabled(for: game) || MachineTranslation.isEnabled(for: game)
    }
}

final class TranslationFeature: PlayerFeature {
    private var collected = Set<String>()
    private var dirty = false

    /// Wraps text conversion and drawing. Whole strings are looked up first, then the text pieces between escape
    /// codes (\C[2], \V[1], \N[1]...). Unknown strings are reported to the app in batches.
    static let script = #"""
    (function () {
        var dict = null;
        try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/__nex/translate.json', false);
            xhr.send(null);
            if (xhr.status === 200) dict = JSON.parse(xhr.responseText);
        } catch (e) { dict = null; }
        // Translation is off for this game.
        if (!dict || typeof dict !== 'object') return;
        var has = Object.prototype.hasOwnProperty;
        var pending = [], seen = {};
        function report(text) {
            if (!text || seen[text] || text.length > 2000) return;
            seen[text] = true;
            pending.push(text);
        }
        setInterval(function () {
            if (!pending.length) return;
            try { window.webkit.messageHandlers.nexTranslate.postMessage(pending.splice(0, 200)); } catch (e) { pending = []; }
        }, 1500);
        // 8.18.0: translations made while the game runs (machine translation) arrive here.
        var version = 0;
        window.__nexAddTranslations = function (more) {
            var added = 0;
            for (var k in more) if (has.call(more, k) && more[k]) { dict[k] = String(more[k]); added++; }
            if (added) version++;
            return added;
        };
        function hasLetters(text) { return /[^\s\d\p{P}]/u.test(text); }
        function lookup(text) {
            if (typeof text !== 'string' || !text) return null;
            if (has.call(dict, text)) return String(dict[text]);
            var trimmed = text.trim();
            if (trimmed !== text && has.call(dict, trimmed)) {
                return text.replace(trimmed, String(dict[trimmed]));
            }
            return null;
        }
        var CODES = /(\\[A-Za-z]+\[[^\]]*\]|\\[A-Za-z]+<[^>]*>|\\[A-Za-z]+|\\[{}\\$.|!<>^]|\n)/;
        function translate(text, whole) {
            var found = lookup(text);
            if (found !== null) return found;
            var parts = String(text).split(CODES);
            var changed = false, missing = false;
            for (var i = 0; i < parts.length; i += 2) {
                var piece = parts[i];
                if (!piece || !hasLetters(piece)) continue;
                var hit = lookup(piece);
                if (hit !== null) { parts[i] = hit; changed = true; }
                else { missing = true; report(piece.trim()); }
            }
            // A message is also asked for whole: it translates better than line by line.
            if (missing && whole && /\n/.test(text)) report(String(text));
            return changed ? parts.join('') : text;
        }
        window.__nexTranslate = translate;

        // Word wrap for translated messages: English is longer than Japanese, and RPG Maker does not wrap.
        function plain(line) { return String(line).replace(/\\[A-Za-z]+\[[^\]]*\]|\\[A-Za-z]+<[^>]*>|\\[A-Za-z]+|\\[{}\\$.|!<>^]/g, ''); }
        function wrap(win, text) {
            var width = 0;
            try {
                width = win.contentsWidth ? win.contentsWidth() : (win.width - 36);
                var face = typeof $gameMessage !== 'undefined' && $gameMessage && $gameMessage.faceName && $gameMessage.faceName();
                if (face) width -= (typeof ImageManager !== 'undefined' && ImageManager.faceWidth ? ImageManager.faceWidth : 144) + 24;
            } catch (e) { return text; }
            if (!(width > 40) || !win.textWidth) return text;
            var out = [];
            String(text).split('\n').forEach(function (line) {
                if (win.textWidth(plain(line)) <= width || line.indexOf(' ') < 0) { out.push(line); return; }
                var words = line.split(' '), cur = '';
                for (var i = 0; i < words.length; i++) {
                    var next = cur ? cur + ' ' + words[i] : words[i];
                    if (cur && win.textWidth(plain(next)) > width) { out.push(cur); cur = words[i]; }
                    else cur = next;
                }
                if (cur) out.push(cur);
            });
            return out.join('\n');
        }
        function isMessage(win) {
            return (typeof Window_Message !== 'undefined' && win instanceof Window_Message)
                || (typeof Window_ScrollText !== 'undefined' && win instanceof Window_ScrollText);
        }
        (function hook(tries) {
            if (typeof Window_Base === 'undefined' || typeof Bitmap === 'undefined') {
                if ((tries || 0) < 400) setTimeout(function () { hook((tries || 0) + 1); }, 200);
                return;
            }
            if (Window_Base.prototype.__nexTranslated) return;
            Window_Base.prototype.__nexTranslated = true;
            var convert = Window_Base.prototype.convertEscapeCharacters;
            Window_Base.prototype.convertEscapeCharacters = function (text) {
                var source = String(text);
                var message = isMessage(this);
                var out = translate(source, message);
                if (out !== source && message) {
                    try { out = wrap(this, out); } catch (e) {}
                }
                return convert.call(this, out);
            };
            var drawText = Bitmap.prototype.drawText;
            Bitmap.prototype.drawText = function (text) {
                if (typeof text === 'string' && text && hasLetters(text)) {
                    var found = lookup(text);
                    if (found !== null) {
                        var args = Array.prototype.slice.call(arguments);
                        args[0] = found;
                        return drawText.apply(this, args);
                    }
                    report(text.trim());
                }
                return drawText.apply(this, arguments);
            };
        })();
    })();
    """#

    override func userScripts(for game: Game) -> [WKUserScript] {
        // 8.18.0: always there for RPG Maker; the page asks the app whether translation is on (fileOverride).
        guard game.engine.isRPGMaker else { return [] }
        return [WKUserScript(source: TranslationFeature.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)]
    }

    /// Read on every (re)load, so a setting changed in the game applies after Restart Game.
    private func refreshState() {
        let game = context.game()
        guard TranslationStore.isActive(for: game) else {
            machineOn = false
            return
        }
        if collected.isEmpty { collected = Set(TranslationStore.loadUntranslated(for: game)) }
        machineOn = MachineTranslation.isEnabled(for: game)
        if machineOn {
            if machine.isEmpty { machine = MachineTranslation.load(game.id) }
            context.gameLog.add("machine translation on (\(machine.count) texts translated so far)")
        } else {
            context.gameLog.add(TranslationStore.dictionaryURL(for: game) == nil
                                ? "translation on, but no TranslateFile.json yet: collecting untranslated text"
                                : "translation on with TranslateFile.json")
        }
    }

    override var messageNames: [String] { ["nexTranslate"] }

    override func receive(name: String, body: Any) {
        guard let lines = body as? [String] else { return }
        let before = collected.count
        for line in lines where !line.isEmpty && collected.count < 50_000 { collected.insert(line) }
        if collected.count != before { dirty = true }
        if machineOn { translateLive(lines) }
    }

    // MARK: 8.18.0 machine translation while playing

    private var machineOn = false
    private var machine: [String: String] = [:]
    private var asked = Set<String>()
    private var jobs: TranslationJobs?
    private var host: UIViewController?
    private var warned = false
    private var saveItem: DispatchWorkItem?

    private func translateLive(_ lines: [String]) {
        let fresh = lines.filter { MachineTranslation.needsTranslation($0) && machine[$0] == nil && !asked.contains($0) }
        guard !fresh.isEmpty else { return }
        asked.formUnion(fresh)
        let jobs = ensureHost()
        let gameID = context.game().id
        jobs.translate(fresh, from: MachineTranslation.guessSource(fresh)) { [weak self] result in
            guard let self else { return }
            if result.isEmpty {
                if !self.warned, let error = jobs.lastError {
                    self.warned = true
                    self.context.gameLog.add("machine translation: \(error) Open Translation in the game menu and use Translate Whole Game once to download the language.")
                }
                return
            }
            self.machine.merge(result) { _, new in new }
            self.push(result)
            self.scheduleSave(gameID)
        }
    }

    private func push(_ result: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else { return }
        context.evaluate("window.__nexAddTranslations && window.__nexAddTranslations(\(json))")
    }

    private func scheduleSave(_ gameID: UUID) {
        saveItem?.cancel()
        let snapshot = machine
        let item = DispatchWorkItem { TranslationFeature.persist(snapshot, gameID: gameID) }
        saveItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: item)
    }

    /// The invisible view that owns the translation session, inside the player.
    private func ensureHost() -> TranslationJobs {
        if let jobs { return jobs }
        let jobs = TranslationJobs()
        // While playing, iOS is not asked to download a language (that sheet would cover the game).
        jobs.mayDownload = false
        self.jobs = jobs
        let hosting = UIHostingController(rootView: TranslationHostView(jobs: jobs))
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        hosting.view.alpha = 0.02
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let root = context.webView?.superview {
            let parent = sequence(first: root as UIResponder, next: { $0.next }).first { $0 is UIViewController } as? UIViewController
            parent?.addChild(hosting)
            root.addSubview(hosting.view)
            hosting.didMove(toParent: parent)
        }
        host = hosting
        return jobs
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        TranslationStore.saveUntranslated(collected.sorted(), for: context.game())
    }

    override func didFinishLoad() {
        flush()
        refreshState()
    }

    override func shutdown() {
        flush()
        jobs?.cancel()
        if let host {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        host = nil
        if machineOn {
            saveItem?.cancel()
            TranslationFeature.persist(machine, gameID: context.game().id)
        }
    }

    func openSettings() {
        flush()
        let view = TranslationSettingsView(game: context.game(), onRestart: { [weak self] in self?.context.reload() },
                                           onTranslated: { [weak self] map in self?.addMachine(map) })
        context.present(UIHostingController(rootView: view))
    }

    /// Translations made in the settings sheet go into the running game at once.
    func addMachine(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        machine.merge(map) { _, new in new }
        push(map)
    }

    /// Translated names for the cheat engine (from the game's machine translations).
    func machineNames() -> [String: String] {
        machine.isEmpty ? MachineTranslation.load(context.game().id) : machine
    }

    /// Adds to what is on disk (Translate Whole Game may have written more meanwhile).
    nonisolated static func persist(_ map: [String: String], gameID: UUID) {
        guard !map.isEmpty else { return }
        var disk = MachineTranslation.load(gameID)
        disk.merge(map) { old, _ in old }
        MachineTranslation.save(disk, gameID: gameID)
    }

    override func menuItems(for game: Game) -> [UIMenuElement] {
        guard game.engine.isRPGMaker else { return [] }
        return [UIAction(title: "Translation…", image: UIImage(systemName: "character.bubble")) { [weak self] _ in
            self?.openSettings()
        }]
    }
}

/// Per-game translation settings: machine translation (8.18.0), an MTool dictionary, collected text.
struct TranslationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let game: Game
    var onRestart: () -> Void = {}
    var onTranslated: ([String: String]) -> Void = { _ in }

    @State private var enabled = false
    @State private var machineOn = false
    @State private var machineCount = 0
    @State private var hasDictionary = false
    @State private var untranslatedCount = 0
    @State private var shareURL: URL?
    @State private var message: String?
    @State private var working = false
    @State private var step = ""
    @State private var status = ""
    @StateObject private var jobs = TranslationJobs()

    var body: some View {
        NavigationStack {
            NexForm {
                Section {
                    Toggle("Translate to English Automatically", isOn: Binding(
                        get: { machineOn },
                        set: { value in
                            machineOn = value
                            MachineTranslation.setEnabled(value, for: game)
                        }
                    ))
                    LabeledContent("Translated so far", value: "\(machineCount) texts")
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        translateWholeGame()
                    } label: {
                        if working {
                            HStack {
                                ProgressView()
                                Text(step.isEmpty ? "Translating…" : step)
                            }
                        } else {
                            Label("Translate Whole Game Now", systemImage: "character.bubble.fill")
                        }
                    }
                    .disabled(working)
                    if working {
                        if jobs.total > 0 {
                            ProgressView(value: Double(jobs.done), total: Double(max(jobs.total, 1)))
                            Text("\(jobs.done) of \(jobs.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Button("Stop", role: .cancel) { jobs.cancel() }
                    }
                    if machineCount > 0 && !working {
                        Button("Delete Machine Translations", role: .destructive) {
                            MachineTranslation.clear(game.id)
                            refresh()
                        }
                    }
                } header: {
                    Text("English on This iPhone")
                } footer: {
                    Text("Uses Apple's on-device translation: iOS downloads the language once, then nothing leaves the iPhone. Translate Whole Game reads every text in the game's data (messages, choices, items, skills, menus) and keeps the English; text the game draws itself (plugin menus) is translated while you play and shows in English from then on. Long English lines wrap in the message window. Changes apply when the game restarts. Stopping keeps what is done; the next run goes on from there.")
                }
                Section {
                    Toggle("Use an MTool Dictionary", isOn: Binding(
                        get: { enabled },
                        set: { value in
                            enabled = value
                            TranslationStore.setEnabled(value, for: game)
                        }
                    ))
                    LabeledContent("Dictionary", value: hasDictionary ? "TranslateFile.json" : "None")
                    LabeledContent("Collected untranslated lines", value: "\(untranslatedCount)")
                    Button("Import TranslateFile.json…") {
                        ImportPicker.pickCopy(types: [.json, .plainText, .item]) { urls in if let url = urls.first { importDictionary(url) } }
                    }
                    Button("Export Untranslated Lines…") { exportLines() }
                        .disabled(untranslatedCount == 0)
                    Button("Clear Collected Lines", role: .destructive) {
                        TranslationStore.saveUntranslated([], for: game)
                        refresh()
                    }
                    .disabled(untranslatedCount == 0)
                } header: {
                    Text("Dictionary")
                } footer: {
                    Text("An MTool translation file (TranslateFile.json: original text mapped to translated text), from the game folder or imported here. It wins over machine translation. Export the collected lines, translate the values elsewhere, then import the file back.")
                }
                Section {
                    Button("Restart Game to Apply") {
                        dismiss()
                        onRestart()
                    }
                }
            }
            .navigationTitle("Translation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { dismiss() } }
            }
            .onAppear { refresh() }
            .onDisappear { jobs.cancel() }
            .translationJobs(jobs)
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
        machineOn = MachineTranslation.isEnabled(for: game)
        machineCount = MachineTranslation.load(game.id).count
        hasDictionary = TranslationStore.dictionaryURL(for: game) != nil
        untranslatedCount = TranslationStore.loadUntranslated(for: game).count
    }

    private func translateWholeGame() {
        working = true
        step = "Reading the game's texts…"
        status = ""
        let game = self.game
        Task { @MainActor in
            let collected = await Task.detached(priority: .userInitiated) { GameTextExtractor.collect(for: game) }.value
            var known = MachineTranslation.load(game.id)
            let own: [String: Any] = {
                guard let url = TranslationStore.dictionaryURL(for: game), let data = try? Data(contentsOf: url) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }()
            let wanted = collected.plain.filter { known[$0] == nil && own[$0] == nil }
            let source = MachineTranslation.guessSource(Array(collected.plain))
            if collected.plain.isEmpty {
                working = false
                step = ""
                message = "No Japanese, Chinese, Korean or Russian text found in the game's data folder."
                return
            }
            if let availability = await MachineTranslation.availability(from: source), availability == .unsupported {
                working = false
                step = ""
                message = "iOS can't translate \(MachineTranslation.languageName(source)) to English."
                return
            }
            step = "Translating \(MachineTranslation.languageName(source)) to English…"
            let result: [String: String] = await withCheckedContinuation { continuation in
                if wanted.isEmpty {
                    continuation.resume(returning: [:])
                } else {
                    jobs.translate(Array(wanted), from: source) { continuation.resume(returning: $0) }
                }
            }
            known.merge(result) { _, new in new }
            var added = result
            var rebuilt = 0
            for item in collected.coded where known[item.whole] == nil {
                if let english = GameTextExtractor.rebuild(item.parts, using: known) {
                    known[item.whole] = english
                    added[item.whole] = english
                    rebuilt += 1
                }
            }
            MachineTranslation.save(known, gameID: game.id)
            if !machineOn {
                machineOn = true
                MachineTranslation.setEnabled(true, for: game)
            }
            onTranslated(added)
            working = false
            step = ""
            refresh()
            let left = wanted.count - result.count
            if let error = jobs.lastError, result.isEmpty, !wanted.isEmpty {
                message = "Nothing was translated: \(error)"
            } else {
                status = "\(result.count + rebuilt) new texts in English" + (left > 0 ? ", \(left) not done yet (run it again to go on)." : ".")
                message = "Done. Restart the game to see everything in English."
            }
        }
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
