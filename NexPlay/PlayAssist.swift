import UIKit
import SwiftUI
import WebKit

// Play Assist (5.0.0), RPG Maker MV/MZ, and save states for Twine SugarCube stories (6.0.0). Shown in the Game Panel
// (6.1.0); this feature adds no menu entries itself.
// - Save states (manual, quick, auto): RPG Maker = the game's own save contents (DataManager.makeSaveContents through
//   JsonEx); SugarCube = Save.base64.save()/Save.serialize(). Kept by NexPlay in SaveStates/<game-uuid>/, outside the
//   game's save slots, so they never touch the game's save files. RPG Maker loading does what Scene_Load does.
// - Rewind (RPG Maker): in-memory snapshots every 15 s on the map (last 5 minutes). Every load first keeps where
//   you were, so a load or rewind can be undone.
// - Message log (backlog), instant text, auto-advance (RPG Maker).
// Options are per game in SaveStates/<game-uuid>/options.json (also the Game Tools volume).

enum PlayAssist {
    /// Engines with save states.
    static func supports(_ game: Game) -> Bool {
        game.engine.isRPGMaker || game.engine == .twine
    }

    /// SugarCube save states and history. Harlowe/Snowman stories have no save API, so they get a clear message.
    static let twineScript = #"""
    (function () {
        if (window.__nexAssist) return;
        var A = window.__nexAssist = {};
        function sc() {
            var S = window.SugarCube;
            return S && S.Save && S.State ? S : null;
        }
        function missing() {
            if (document.querySelector('tw-story')) return 'Save states work in SugarCube stories. This story uses another Twine format (Harlowe).';
            return 'The story is still starting, or it is not a SugarCube story.';
        }
        A.setOptions = function () { return 'ok'; };
        A.capture = function () {
            try {
                var S = sc();
                if (!S) return JSON.stringify({ ok: false, error: missing() });
                var data = null;
                if (S.Save.base64 && typeof S.Save.base64.save === 'function') data = S.Save.base64.save();
                else if (typeof S.Save.serialize === 'function') data = S.Save.serialize();
                if (typeof data !== 'string' || !data) return JSON.stringify({ ok: false, error: 'The story does not allow saving here.' });
                return JSON.stringify({ ok: true, data: data, map: String(S.State.passage || ''), playtime: '', leader: '', level: 0, shot: '' });
            } catch (e) { return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); }
        };
        A.restore = function (data) {
            try {
                var S = sc();
                if (!S) return missing();
                var result;
                if (S.Save.base64 && typeof S.Save.base64.load === 'function') result = S.Save.base64.load(data);
                else if (typeof S.Save.deserialize === 'function') result = S.Save.deserialize(data);
                else return 'This SugarCube version cannot load states.';
                if (result && typeof result.then === 'function') {
                    return result.then(function () { return 'ok'; }, function (e) { return String((e && e.message) || e); });
                }
                if (result === null) return 'The story could not read this state.';
                return 'ok';
            } catch (e) { return String((e && e.message) || e); }
        };
        A.rewindList = function () { return '[]'; };
        A.rewindTo = function () { return 'Rewind is not available in Twine stories. Use Story: Back.'; };
        A.logJSON = function () { return '[]'; };
        A.back = function () {
            var S = sc();
            if (!S || !S.Engine || !S.Engine.backward) return missing();
            return S.Engine.backward() ? 'ok' : 'Nothing to go back to.';
        };
        A.forward = function () {
            var S = sc();
            if (!S || !S.Engine || !S.Engine.forward) return missing();
            return S.Engine.forward() ? 'ok' : 'Nothing to go forward to.';
        };
    })();
    """#

    static let script = #"""
    (function () {
        if (window.__nexAssist) return;
        var A = window.__nexAssist = { instant: false, auto: 0, rewind: true, every: 15000, max: 20, ring: [], last: 0, frame: -1, log: [], seq: 0 };
        function ready() {
            return typeof SceneManager !== 'undefined' && typeof DataManager !== 'undefined' && typeof Scene_Map !== 'undefined'
                && typeof JsonEx !== 'undefined' && typeof $dataSystem !== 'undefined' && !!$dataSystem
                && (!DataManager.isDatabaseLoaded || DataManager.isDatabaseLoaded());
        }
        function started() {
            return typeof $gameSystem !== 'undefined' && !!$gameSystem && typeof $gamePlayer !== 'undefined' && !!$gamePlayer
                && typeof $gameMap !== 'undefined' && !!$gameMap;
        }
        function booting() {
            return typeof Scene_Boot !== 'undefined' && SceneManager._scene instanceof Scene_Boot;
        }
        function problem() {
            if (!ready() || booting()) return 'The game is still starting.';
            if (!started()) return 'Start or load a game first.';
            if (!(SceneManager._scene instanceof Scene_Map)) return 'Go back to the map first (close menus, finish the battle).';
            if (SceneManager.isSceneChanging && SceneManager.isSceneChanging()) return 'Wait a moment and try again.';
            if ($gamePlayer.isTransferring && $gamePlayer.isTransferring()) return 'Wait until the map has loaded.';
            if (typeof $gameMessage !== 'undefined' && $gameMessage && $gameMessage.isBusy()) return 'Close the message first.';
            if ($gameMap.isEventRunning && $gameMap.isEventRunning()) return 'Wait until the event ends.';
            return '';
        }
        function contents() {
            var count = $gameSystem._saveCount;
            if ($gameSystem.onBeforeSave) $gameSystem.onBeforeSave();
            $gameSystem._saveCount = count;
            return JsonEx.stringify(DataManager.makeSaveContents());
        }
        function meta() {
            var out = { map: '', playtime: '', leader: '', level: 0 };
            try { out.map = String($gameMap.displayName() || ''); } catch (e) {}
            try {
                if (!out.map && typeof $dataMapInfos !== 'undefined' && $dataMapInfos && $dataMapInfos[$gameMap.mapId()]) {
                    out.map = String($dataMapInfos[$gameMap.mapId()].name || '');
                }
            } catch (e) {}
            try { out.playtime = String($gameSystem.playtimeText()); } catch (e) {}
            try { var l = $gameParty.leader(); if (l) { out.leader = String(l.name()); out.level = Number(l.level) || 0; } } catch (e) {}
            return out;
        }
        function shot() {
            try {
                var bmp = SceneManager.snap();
                var src = bmp.canvas || bmp._canvas;
                if (!src || !src.width) return '';
                var w = 320, h = Math.max(1, Math.round(src.height * w / src.width));
                var c = document.createElement('canvas');
                c.width = w; c.height = h;
                c.getContext('2d').drawImage(src, 0, 0, w, h);
                var url = c.toDataURL('image/jpeg', 0.75);
                try { if (bmp.destroy) bmp.destroy(); } catch (e) {}
                return url;
            } catch (e) { return ''; }
        }
        function remember(label) {
            A.ring.push({ t: Date.now(), data: contents(), map: label || '' });
            while (A.ring.length > A.max) A.ring.shift();
        }
        A.setOptions = function (o) {
            A.instant = !!o.instant;
            A.auto = Number(o.auto) || 0;
            A.rewind = !!o.rewind;
            if (!A.rewind) A.ring = [];
            return 'ok';
        };
        A.capture = function (withShot) {
            try {
                var why = problem();
                if (why) return JSON.stringify({ ok: false, error: why });
                var m = meta();
                return JSON.stringify({ ok: true, data: contents(), map: m.map, playtime: m.playtime, leader: m.leader,
                    level: m.level, shot: withShot ? shot() : '' });
            } catch (e) { return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); }
        };
        A.restore = function (data) {
            try {
                if (!ready() || booting()) return 'The game is still starting.';
                if (SceneManager.isSceneChanging && SceneManager.isSceneChanging()) return 'Wait a moment and try again.';
                var saved = JsonEx.parse(data);
                // Keep where we are, so the load can be undone with Rewind.
                try { if (!problem()) remember((meta().map || 'Map') + ' (before load)'); } catch (e) {}
                try { if (AudioManager.stopMe) AudioManager.stopMe(); } catch (e) {}
                DataManager.createGameObjects();
                DataManager.extractSaveContents(saved);
                if (DataManager.correctDataErrors) DataManager.correctDataErrors();
                if ($gameSystem.onAfterLoad) $gameSystem.onAfterLoad();
                if (typeof Scene_Load !== 'undefined' && Scene_Load.prototype.reloadMapIfUpdated) {
                    Scene_Load.prototype.reloadMapIfUpdated.call(SceneManager._scene);
                }
                if (SceneManager._stack) SceneManager._stack = [];
                SceneManager.goto(Scene_Map);
                A.last = Date.now();
                return 'ok';
            } catch (e) { return String((e && e.message) || e); }
        };
        A.rewindList = function () {
            var now = Date.now(), out = [];
            for (var i = A.ring.length - 1; i >= 0; i--) {
                out.push({ index: i, ago: Math.max(0, Math.round((now - A.ring[i].t) / 1000)), map: String(A.ring[i].map || '') });
            }
            return JSON.stringify(out);
        };
        A.rewindTo = function (index) {
            var item = A.ring[index];
            if (!item) return 'That rewind point is gone.';
            A.ring = A.ring.slice(0, index + 1);
            return A.restore(item.data);
        };
        setInterval(function () {
            try {
                if (!A.rewind || document.hidden || Date.now() - A.last < A.every) return;
                if (problem()) return;
                var frame = (typeof Graphics !== 'undefined' && Graphics.frameCount) || 0;
                if (frame === A.frame) return; // paused: nothing changed
                A.frame = frame;
                A.last = Date.now();
                remember(meta().map);
            } catch (e) {}
        }, 1000);

        function strip(text) {
            var s = String(text == null ? '' : text);
            try { s = Window_Base.prototype.convertEscapeCharacters.call(Window_Base.prototype, s); } catch (e) {}
            s = s.replace(/\x1b[A-Za-z]+\[[^\]]*\]/g, '').replace(/\x1b[A-Za-z]+/g, '').replace(/\x1b./g, '');
            return s.replace(/[ \t]+\n/g, '\n').trim();
        }
        function addLog(name, text, choice) {
            var t = strip(text);
            if (!t) return;
            A.seq += 1;
            A.log.push({ i: A.seq, n: strip(name), t: t, c: !!choice });
            while (A.log.length > 400) A.log.shift();
        }
        A.logJSON = function () { return JSON.stringify(A.log); };
        (function hook() {
            if (typeof Window_Message === 'undefined' || typeof Game_Message === 'undefined' || typeof Window_Base === 'undefined') {
                setTimeout(hook, 500);
                return;
            }
            if (Window_Message.prototype.__nexAssist) return;
            Window_Message.prototype.__nexAssist = true;
            var start = Window_Message.prototype.startMessage;
            Window_Message.prototype.startMessage = function () {
                try {
                    var name = $gameMessage.speakerName ? $gameMessage.speakerName() : '';
                    addLog(name, $gameMessage.allText(), false);
                } catch (e) {}
                this.__nexPauseAt = 0;
                return start.apply(this, arguments);
            };
            var showFast = Window_Message.prototype.updateShowFast;
            Window_Message.prototype.updateShowFast = function () {
                var result = showFast.apply(this, arguments);
                if (A.instant) { this._showFast = true; this._lineShowFast = true; }
                return result;
            };
            var startPause = Window_Message.prototype.startPause;
            Window_Message.prototype.startPause = function () {
                this.__nexPauseAt = Date.now();
                return startPause.apply(this, arguments);
            };
            var triggered = Window_Message.prototype.isTriggered;
            Window_Message.prototype.isTriggered = function () {
                if (triggered.apply(this, arguments)) return true;
                if (A.auto > 0 && this.pause && this.__nexPauseAt && Date.now() - this.__nexPauseAt >= A.auto * 1000) {
                    this.__nexPauseAt = 0;
                    return true;
                }
                return false;
            };
            var onChoice = Game_Message.prototype.onChoice;
            Game_Message.prototype.onChoice = function (n) {
                try {
                    var list = this.choices ? this.choices() : [];
                    if (n >= 0 && list[n] != null) addLog('', '\u25B8 ' + list[n], true);
                } catch (e) {}
                return onChoice.apply(this, arguments);
            };
        })();
    })();
    """#
}

// MARK: - Options

/// Per-game Play Assist and Game Tools options (SaveStates/<game-uuid>/options.json).
struct AssistOptions: Codable, Equatable {
    var instantText = false
    /// Seconds before a finished message goes on by itself; 0 is off.
    var autoAdvance: Double = 0
    /// Minutes between auto states; 0 is off.
    var autoStateMinutes = 10
    var rewind = true
    /// Game Tools volume, 0...1.
    var volume: Double = 1

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instantText = try container.decodeIfPresent(Bool.self, forKey: .instantText) ?? false
        autoAdvance = try container.decodeIfPresent(Double.self, forKey: .autoAdvance) ?? 0
        autoStateMinutes = try container.decodeIfPresent(Int.self, forKey: .autoStateMinutes) ?? 10
        rewind = try container.decodeIfPresent(Bool.self, forKey: .rewind) ?? true
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }

    private static func url(_ gameID: UUID) -> URL {
        SaveStateStore.folder(for: gameID).appendingPathComponent("options.json")
    }

    static func load(for gameID: UUID) -> AssistOptions {
        guard let data = try? Data(contentsOf: url(gameID)),
              let options = try? JSONDecoder().decode(AssistOptions.self, from: data) else { return AssistOptions() }
        return options
    }

    func save(for gameID: UUID) {
        try? FileManager.default.createDirectory(at: SaveStateStore.folder(for: gameID), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: AssistOptions.url(gameID), options: .atomic)
        }
    }
}

// MARK: - Stored states

struct SaveStateInfo: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case manual, quick, auto

        var title: String {
            switch self {
            case .manual: return "STATE"
            case .quick: return "QUICK"
            case .auto: return "AUTO"
            }
        }

        var color: Color {
            switch self {
            case .manual: return .purple
            case .quick: return .orange
            case .auto: return .teal
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var date: Date = Date()
    var map: String = ""
    var playtime: String = ""
    var leader: String = ""
    var level: Int = 0
    var bytes: Int = 0
}

/// Save states on disk: SaveStates/<game-uuid>/states.json (the list), <state-uuid>.json (save contents),
/// <state-uuid>.jpg (thumbnail). LibraryStore.delete removes the folder with the game.
enum SaveStateStore {
    /// Auto states kept per game.
    static let autoKeep = 3

    static var root: URL { Paths.support.appendingPathComponent("SaveStates", isDirectory: true) }

    static func folder(for gameID: UUID) -> URL {
        root.appendingPathComponent(gameID.uuidString, isDirectory: true)
    }

    static func dataURL(_ info: SaveStateInfo, gameID: UUID) -> URL {
        folder(for: gameID).appendingPathComponent(info.id.uuidString + ".json")
    }

    static func imageURL(_ info: SaveStateInfo, gameID: UUID) -> URL {
        folder(for: gameID).appendingPathComponent(info.id.uuidString + ".jpg")
    }

    private static func indexURL(_ gameID: UUID) -> URL {
        folder(for: gameID).appendingPathComponent("states.json")
    }

    /// The game's states, newest first.
    static func list(for gameID: UUID) -> [SaveStateInfo] {
        guard let data = try? Data(contentsOf: indexURL(gameID)),
              let items = try? JSONDecoder().decode([SaveStateInfo].self, from: data) else { return [] }
        return items.sorted { $0.date > $1.date }
    }

    private static func write(_ items: [SaveStateInfo], gameID: UUID) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: indexURL(gameID), options: .atomic)
    }

    /// Stores a state. A quick state replaces the previous quick state; only the newest auto states are kept.
    static func add(_ info: SaveStateInfo, payload: String, image: Data?, gameID: UUID) throws {
        try FileManager.default.createDirectory(at: folder(for: gameID), withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: dataURL(info, gameID: gameID), options: .atomic)
        if let image {
            try? image.write(to: imageURL(info, gameID: gameID), options: .atomic)
        }
        var items = list(for: gameID)
        items.insert(info, at: 0)
        var removed: [SaveStateInfo] = []
        if info.kind == .quick {
            removed += items.filter { $0.kind == .quick && $0.id != info.id }
        }
        if info.kind == .auto {
            let autos = items.filter { $0.kind == .auto }
            if autos.count > autoKeep {
                removed += Array(autos[autoKeep...])
            }
        }
        let gone = Set(removed.map { $0.id })
        items.removeAll { gone.contains($0.id) }
        try write(items, gameID: gameID)
        for item in removed { removeFiles(item, gameID: gameID) }
    }

    static func delete(_ info: SaveStateInfo, gameID: UUID) {
        var items = list(for: gameID)
        items.removeAll { $0.id == info.id }
        try? write(items, gameID: gameID)
        removeFiles(info, gameID: gameID)
    }

    static func payload(_ info: SaveStateInfo, gameID: UUID) -> String? {
        try? String(contentsOf: dataURL(info, gameID: gameID), encoding: .utf8)
    }

    /// Every state and the options of a game (the game was deleted).
    static func removeAll(for gameID: UUID) {
        try? FileManager.default.removeItem(at: folder(for: gameID))
    }

    private static func removeFiles(_ info: SaveStateInfo, gameID: UUID) {
        try? FileManager.default.removeItem(at: dataURL(info, gameID: gameID))
        try? FileManager.default.removeItem(at: imageURL(info, gameID: gameID))
    }
}

struct RewindPoint: Decodable, Identifiable {
    let index: Int
    let ago: Int
    let map: String
    var id: Int { index }
}

struct AssistLogLine: Decodable, Identifiable {
    let i: Int
    let n: String
    let t: String
    let c: Bool
    var id: Int { i }
}

// MARK: - Player feature

final class PlayAssistFeature: PlayerFeature {
    private var autoTimer: Timer?
    private var lastAuto = Date()
    private var observers: [NSObjectProtocol] = []
    private var capturing = false

    override init(context: PlayerContext) {
        super.init(context: context)
        let token = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appWillResign() }
        }
        observers.append(token)
    }

    private var options: AssistOptions {
        AssistOptions.load(for: context.game().id)
    }

    private var supported: Bool {
        PlayAssist.supports(context.game())
    }

    override func userScripts(for game: Game) -> [WKUserScript] {
        if game.engine.isRPGMaker {
            return [WKUserScript(source: PlayAssist.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)]
        }
        if game.engine == .twine {
            return [WKUserScript(source: PlayAssist.twineScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)]
        }
        return []
    }

    override func didFinishLoad() {
        applyOptions()
        restartTimer()
    }

    override func shutdown() {
        autoTimer?.invalidate()
        autoTimer = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }

    /// Changes the game's options and applies them to the running game.
    func change(_ edit: (inout AssistOptions) -> Void) {
        let id = context.game().id
        var updated = AssistOptions.load(for: id)
        edit(&updated)
        updated.save(for: id)
        applyOptions()
        restartTimer()
    }

    private func applyOptions() {
        guard supported else { return }
        let current = options
        let script = "window.__nexAssist && window.__nexAssist.setOptions({instant: \(current.instantText), auto: \(current.autoAdvance), rewind: \(current.rewind)})"
        context.evaluate(script)
    }

    // MARK: Auto states

    private func restartTimer() {
        autoTimer?.invalidate()
        autoTimer = nil
        guard supported, options.autoStateMinutes > 0 else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.autoTick() }
        }
    }

    private func autoTick() async {
        let minutes = options.autoStateMinutes
        guard minutes > 0, Date().timeIntervalSince(lastAuto) >= Double(minutes) * 60 else { return }
        _ = await capture(kind: .auto)
    }

    /// Leaving the app (or iOS closing it later) shouldn't lose progress: an auto state when going to the background.
    private func appWillResign() {
        guard supported, context.webView != nil, options.autoStateMinutes > 0,
              Date().timeIntervalSince(lastAuto) >= 60 else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "NexPlay auto state", expirationHandler: nil)
        Task { @MainActor in
            _ = await self.capture(kind: .auto)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    // MARK: States

    /// Captures the running game into a stored state. Returns an error text, or nil when it worked.
    @discardableResult
    func capture(kind: SaveStateInfo.Kind) async -> String? {
        guard !capturing else { return "Still saving the last state." }
        guard context.webView != nil else { return "The game isn't running." }
        capturing = true
        defer { capturing = false }
        guard let text = await context.evaluateString("window.__nexAssist ? window.__nexAssist.capture(true) : ''"), !text.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return "Save states aren't ready yet. Wait for the game's title screen."
        }
        guard (object["ok"] as? Bool) == true, let payload = object["data"] as? String, !payload.isEmpty else {
            return (object["error"] as? String) ?? "The game couldn't be captured."
        }
        var picture: Data?
        if let shot = object["shot"] as? String, let comma = shot.firstIndex(of: ",") {
            picture = Data(base64Encoded: String(shot[shot.index(after: comma)...]))
        }
        if picture == nil {
            picture = await context.snapshotJPEG()
        }
        var info = SaveStateInfo(kind: kind)
        info.map = object["map"] as? String ?? ""
        info.playtime = object["playtime"] as? String ?? ""
        info.leader = object["leader"] as? String ?? ""
        info.level = (object["level"] as? NSNumber)?.intValue ?? 0
        info.bytes = payload.utf8.count
        let stored = info
        let image = picture
        let gameID = context.game().id
        do {
            try await Task.detached(priority: .utility) {
                try SaveStateStore.add(stored, payload: payload, image: image, gameID: gameID)
            }.value
        } catch {
            context.gameLog.add("save state failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
        if kind == .auto { lastAuto = Date() }
        context.gameLog.add("save state (\(kind.rawValue)) at \(stored.map.isEmpty ? "the current spot" : stored.map), \(stored.bytes / 1024) KB")
        return nil
    }

    /// Loads a stored state into the running game. Returns an error text, or nil when it worked.
    func load(_ info: SaveStateInfo) async -> String? {
        guard let webView = context.webView else { return "The game isn't running." }
        let gameID = context.game().id
        let payload = await Task.detached(priority: .userInitiated) { () -> String? in
            SaveStateStore.payload(info, gameID: gameID)
        }.value
        guard let payload, !payload.isEmpty else { return "This state's file is missing." }
        do {
            let value = try await webView.callAsyncJavaScript(
                "return window.__nexAssist ? await window.__nexAssist.restore(data) : 'Save states are not ready yet.';",
                arguments: ["data": payload], in: nil, contentWorld: .page)
            let text = value as? String ?? "The game didn't answer."
            guard text == "ok" else { return text }
            context.gameLog.add("loaded save state (\(info.kind.rawValue)) from \(info.date)")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func rewindPoints() async -> [RewindPoint] {
        guard let text = await context.evaluateString("window.__nexAssist ? window.__nexAssist.rewindList() : '[]'") else { return [] }
        return (try? JSONDecoder().decode([RewindPoint].self, from: Data(text.utf8))) ?? []
    }

    func rewind(to point: RewindPoint) async -> String? {
        guard let text = await context.evaluateString("window.__nexAssist ? window.__nexAssist.rewindTo(\(point.index)) : 'Rewind is not ready.'") else {
            return "The game didn't answer."
        }
        guard text == "ok" else { return text }
        context.gameLog.add("rewound \(point.ago) s")
        return nil
    }

    /// Quick Save from the game menu (a note on the game screen says how it went).
    func quickSave() {
        Task { @MainActor in
            if let error = await capture(kind: .quick) {
                context.toast(error)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                context.toast("Quick saved")
            }
        }
    }

    /// Quick Load from the game menu.
    func quickLoad() {
        let gameID = context.game().id
        guard let quick = SaveStateStore.list(for: gameID).first(where: { $0.kind == .quick }) else {
            context.toast("No quick save yet")
            return
        }
        let rpg = context.game().engine.isRPGMaker
        Task { @MainActor in
            if let error = await load(quick) {
                context.toast(error)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                context.toast(rpg ? "Quick loaded. Rewind can undo it." : "Quick loaded")
            }
        }
    }

    // MARK: Sheets

    /// The Save States sheet. The game pauses while it is open.
    func openStates() {
        let game = context.game()
        guard PlayAssist.supports(game) else { return }
        let model = SaveStatesModel(feature: self, gameID: game.id)
        let host = UIHostingController(rootView: SaveStatesView(model: model))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        context.evaluate("window.__nex && window.__nex.pause()")
        model.onClose = { [weak self] in self?.context.evaluate("window.__nex && window.__nex.resume()") }
        context.present(host)
    }

    func openLog() {
        Task { @MainActor in
            var lines: [AssistLogLine] = []
            if let text = await context.evaluateString("window.__nexAssist ? window.__nexAssist.logJSON() : '[]'") {
                lines = (try? JSONDecoder().decode([AssistLogLine].self, from: Data(text.utf8))) ?? []
            }
            let host = UIHostingController(rootView: MessageLogView(lines: lines))
            host.modalPresentationStyle = .pageSheet
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
            context.present(host)
        }
    }
}

// MARK: - Save States sheet

@MainActor
final class SaveStatesModel: ObservableObject {
    @Published var states: [SaveStateInfo] = []
    @Published var rewind: [RewindPoint] = []
    @Published var working = false
    @Published var message: String?
    var onClose: () -> Void = {}
    let gameID: UUID
    private weak var feature: PlayAssistFeature?

    init(feature: PlayAssistFeature, gameID: UUID) {
        self.feature = feature
        self.gameID = gameID
    }

    func reload() async {
        states = SaveStateStore.list(for: gameID)
        if let feature {
            rewind = await feature.rewindPoints()
        } else {
            rewind = []
        }
    }

    func saveNow() async {
        guard let feature else { return }
        working = true
        let error = await feature.capture(kind: .manual)
        working = false
        if let error {
            message = error
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        await reload()
    }

    /// True when the state loaded (the sheet then closes).
    func load(_ info: SaveStateInfo) async -> Bool {
        guard let feature else { return false }
        working = true
        let error = await feature.load(info)
        working = false
        if let error {
            message = error
            return false
        }
        return true
    }

    func rewind(to point: RewindPoint) async -> Bool {
        guard let feature else { return false }
        working = true
        let error = await feature.rewind(to: point)
        working = false
        if let error {
            message = error
            return false
        }
        return true
    }

    func delete(_ info: SaveStateInfo) {
        SaveStateStore.delete(info, gameID: gameID)
        states.removeAll { $0.id == info.id }
    }
}

struct SaveStatesView: View {
    @ObservedObject var model: SaveStatesModel
    @Environment(\.dismiss) private var dismiss
    @State private var pending: SaveStateInfo?
    @State private var pendingRewind: RewindPoint?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    static func ago(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s ago" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) min ago" : "\(minutes) min \(rest) s ago"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        Task { @MainActor in await model.saveNow() }
                    } label: {
                        HStack(spacing: 10) {
                            if model.working {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus.square.on.square.fill")
                            }
                            Text("Save State Now")
                        }
                    }
                    .buttonStyle(PlayButtonStyle())
                    .disabled(model.working)

                    Text("Load any time, even where the game doesn't let you save. The game's own saves are never touched. RPG Maker states are made on the map; Twine states work in SugarCube stories.")
                        .font(.caption).foregroundStyle(.secondary)

                    if !model.rewind.isEmpty {
                        sectionTitle("Rewind", symbol: "backward.fill", count: nil)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.rewind) { point in
                                    Button {
                                        pendingRewind = point
                                    } label: {
                                        RewindChip(point: point)
                                    }
                                    .buttonStyle(PressScaleStyle())
                                }
                            }
                        }
                    }

                    sectionTitle("States", symbol: "square.stack.3d.down.right.fill", count: model.states.count)
                    if model.states.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.down.right")
                                .font(.system(size: 34)).foregroundStyle(NexStyle.accent)
                            Text("No states yet").font(.headline)
                            Text("Tap Save State Now, or use Quick Save.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.states) { state in
                                Button {
                                    pending = state
                                } label: {
                                    SaveStateCard(state: state, gameID: model.gameID)
                                }
                                .buttonStyle(PressScaleStyle())
                                .contextMenu {
                                    Button {
                                        pending = state
                                    } label: {
                                        Label("Load State", systemImage: "arrow.down.circle")
                                    }
                                    Button(role: .destructive) {
                                        model.delete(state)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        Text("Touch and hold a state to delete it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(AppBackground().ignoresSafeArea())
            .confirmationDialog("Rewind?", isPresented: Binding(get: { pendingRewind != nil }, set: { if !$0 { pendingRewind = nil } }),
                                titleVisibility: .visible, presenting: pendingRewind) { point in
                Button("Rewind \(SaveStatesView.ago(point.ago))") {
                    Task { @MainActor in
                        if await model.rewind(to: point) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The game goes back to this moment.")
            }
            .navigationTitle("Save States")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task { @MainActor in await model.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resume") { dismiss() }
                }
            }
        }
        .confirmationDialog("Load this state?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { state in
            Button("Load State") {
                Task { @MainActor in
                    if await model.load(state) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The game jumps to this moment. Progress since then is lost unless it is saved.")
        }
        .environment(\.colorScheme, .dark)
        .task { await model.reload() }
        .onDisappear { model.onClose() }
        .alert("Save States", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private func sectionTitle(_ title: String, symbol: String, count: Int?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.pixel(14, relativeTo: .subheadline, weight: .semibold))
                .foregroundStyle(NexStyle.accent)
            Spacer()
            if let count, count > 0 {
                Text("\(count)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// A state as a card: the picture with its kind, then where, when and who.
struct SaveStateCard: View {
    let state: SaveStateInfo
    let gameID: UUID
    @State private var image: UIImage?

    private var details: String {
        var parts: [String] = []
        if !state.playtime.isEmpty { parts.append(state.playtime) }
        if !state.leader.isEmpty { parts.append(state.level > 0 ? "\(state.leader) Lv \(state.level)" : state.leader) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 92)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    Text(state.kind.title)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(state.kind.color.opacity(0.9), in: Capsule())
                        .padding(8)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.map.isEmpty ? "State" : state.map)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !details.isEmpty {
                    Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NexStyle.cardStroke))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            if image == nil {
                image = UIImage(contentsOfFile: SaveStateStore.imageURL(state, gameID: gameID).path)
            }
        }
    }
}

// MARK: - Message log

/// What was said, as chat bubbles: speakers on the left, the player's choices on the right.
struct MessageLogView: View {
    let lines: [AssistLogLine]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if lines.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(NexStyle.accent)
                                Text("No messages yet").font(.headline)
                                Text("Lines the game shows from now on appear here.")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        ForEach(lines) { line in
                            bubble(line).id(line.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Message Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func bubble(_ line: AssistLogLine) -> some View {
        if line.c {
            HStack {
                Spacer(minLength: 48)
                Text(line.t)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(NexStyle.accentGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if !line.n.isEmpty {
                        Text(line.n)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(NexStyle.accent)
                            .padding(.leading, 6)
                    }
                    Text(line.t)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NexStyle.cardStroke))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 48)
            }
        }
    }
}
