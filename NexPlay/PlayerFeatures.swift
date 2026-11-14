import UIKit
import WebKit

/// What a player feature can reach in the running game.
@MainActor
final class PlayerContext {
    weak var webView: WKWebView?
    let gameLog: GameLog
    var game: () -> Game = { Game(name: "", engine: .web, entry: "") }
    var present: (UIViewController) -> Void = { _ in }
    var reload: () -> Void = {}
    var update: (@escaping (inout Game) -> Void) -> Void = { _ in }
    // 7.3.0 input (set by the player): mouse mode, layout presets, the PC keyboard.
    var mouseMode: () -> MouseMode = { .direct }
    var setMouseMode: (MouseMode) -> Void = { _ in }
    var applyPreset: (LayoutPreset) -> Void = { _ in }
    var showPCKeyboard: () -> Void = {}
    /// 7.7.0: asks before leaving the game (Game Panel's Exit button).
    var exitGame: () -> Void = {}
    /// 8.2.0: the game's Controls Style (nil = Automatic), changing it, and opening the touch-control editor.
    var controlsStyle: () -> ControlsStyle? = { nil }
    var setControlsStyle: (ControlsStyle?) -> Void = { _ in }
    var editControls: () -> Void = {}
    /// 8.2.1: the game's Extras sheet.
    var openExtras: () -> Void = {}

    init(gameLog: GameLog) {
        self.gameLog = gameLog
    }

    func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script)
    }
}

/// A piece of the player that adds scripts, message handlers and menu items without changing
/// PlayerViewController (plugin manager, cheats, translation...). Register new features in `PlayerFeatures.make`.
@MainActor
class PlayerFeature {
    let context: PlayerContext

    init(context: PlayerContext) {
        self.context = context
    }

    /// Scripts added to the page before it loads.
    func userScripts(for game: Game) -> [WKUserScript] { [] }
    /// Names of `window.webkit.messageHandlers` this feature receives.
    var messageNames: [String] { [] }
    func receive(name: String, body: Any) {}
    /// Items for the game menu.
    func menuItems(for game: Game) -> [UIMenuElement] { [] }
    /// The page finished loading.
    func didFinishLoad() {}
    /// The player is closing.
    func shutdown() {}
}

enum PlayerFeatures {
    /// Every feature the player runs. Play Assist and Game Tools live inside the Game Panel.
    @MainActor
    static func make(context: PlayerContext) -> [PlayerFeature] {
        let panel = GamePanelFeature(context: context, assist: PlayAssistFeature(context: context),
                                     tools: WebToolsFeature(context: context), power: PowerFeature(context: context))
        return [panel, PluginsFeature(context: context), CheatsFeature(context: context),
                TranslationFeature(context: context), RenPySavesFeature(context: context), RumbleFeature(context: context)]
    }

    /// Replacement file contents the scheme handler serves for a game (relative path, lowercased), or nil.
    /// Called on the file queue.
    static func fileOverride(for game: Game) -> ((String) -> Data?)? {
        let providers = [PluginManager.fileOverride(for: game), TranslationStore.fileOverride(for: game)].compactMap { $0 }
        guard !providers.isEmpty else { return nil }
        return { path in
            for provider in providers {
                if let data = provider(path) { return data }
            }
            return nil
        }
    }
}

/// Routes key presses from touch controls and controllers to the page. Keys are counted, so two controls bound to
/// the same key only release it when both are let go.
@MainActor
final class KeyRouter {
    weak var webView: WKWebView?
    private var counts: [Int: Int] = [:]
    private var keys: [Int: PadKey] = [:]

    /// 8.2.1 turbo (Extras): these keys repeat while held, `turboRate` presses a second.
    var turboKeys: Set<Int> = []
    var turboRate = 10
    private var turboTimers: [Int: Timer] = [:]

    func press(_ key: PadKey, _ down: Bool) {
        let current = counts[key.keyCode] ?? 0
        if down {
            counts[key.keyCode] = current + 1
            keys[key.keyCode] = key
            if current == 0 {
                send(key, true)
                if turboKeys.contains(key.keyCode) { startTurbo(key) }
            }
        } else {
            guard current > 0 else { return }
            counts[key.keyCode] = current - 1
            if current == 1 {
                stopTurbo(key.keyCode)
                send(key, false)
            }
        }
    }

    private func startTurbo(_ key: PadKey) {
        stopTurbo(key.keyCode)
        let half = 0.5 / Double(min(max(turboRate, 2), 20))
        let code = key.keyCode
        turboDown[code] = true
        let timer = Timer(timeInterval: half, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.turboTick(code) }
        }
        RunLoop.main.add(timer, forMode: .common)
        turboTimers[code] = timer
    }

    private var turboDown: [Int: Bool] = [:]

    private func turboTick(_ code: Int) {
        guard turboTimers[code] != nil, let key = keys[code] else { return }
        let now = !(turboDown[code] ?? true)
        turboDown[code] = now
        send(key, now)
    }

    private func stopTurbo(_ code: Int) {
        turboTimers[code]?.invalidate()
        turboTimers[code] = nil
    }

    func releaseAll() {
        for timer in turboTimers.values { timer.invalidate() }
        turboTimers = [:]
        for (code, count) in counts where count > 0 {
            if let key = keys[code] { send(key, false) }
        }
        counts = [:]
    }

    private func send(_ key: PadKey, _ down: Bool) {
        let name = PageScripts.jsString(key.key)
        let code = PageScripts.jsString(key.code)
        webView?.evaluateJavaScript("window.__nexKey && window.__nexKey(\(key.keyCode),\(name),\(code),\(down))")
    }
}
