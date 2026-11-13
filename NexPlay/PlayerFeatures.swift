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
                TranslationFeature(context: context), RenPySavesFeature(context: context)]
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

    func press(_ key: PadKey, _ down: Bool) {
        let current = counts[key.keyCode] ?? 0
        if down {
            counts[key.keyCode] = current + 1
            keys[key.keyCode] = key
            if current == 0 { send(key, true) }
        } else {
            guard current > 0 else { return }
            counts[key.keyCode] = current - 1
            if current == 1 { send(key, false) }
        }
    }

    func releaseAll() {
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
