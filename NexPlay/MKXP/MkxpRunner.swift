// Runs RPG Maker XP/VX/Ace games through the mkxp-z core (MkxpCore.framework built by tools/fetch_mkxp_core.sh).
// Only compiled when the build sets NEXPLAY_MKXP (see docs/workflow-2.0.0.yml); normal builds use RubyCoreStub.
//
// The core contract (gamecore_* functions, one game per app launch, run from a run loop callout on the main
// thread, keys as SDL scancodes) follows Empo's cores/GameCore.h, GameCoreLaunch.swift and docs/multi-session.md.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).
// mkxp-z (GPLv2+), Ruby, SDL, ANGLE and FluidSynth are inside the core; see Settings > Credits.

#if NEXPLAY_MKXP
import UIKit
import Darwin

/// The gamecore_* functions, looked up with dlsym so the app links without the core.
private struct GameCoreSymbols {
    typealias SetPath = @convention(c) (UnsafePointer<CChar>?) -> Void
    typealias RunApp = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias KeyEvent = @convention(c) (Int32, Int32) -> Void
    typealias Void0 = @convention(c) () -> Void

    let setGamePath: SetPath
    let runApp: RunApp
    let injectKey: KeyEvent
    let requestPause: Void0?
    let requestResume: Void0?

    static func load() -> GameCoreSymbols? {
        guard let frameworks = Bundle.main.privateFrameworksPath else { return nil }
        let path = frameworks + "/MkxpCore.framework/MkxpCore"
        guard let handle = dlopen(path, RTLD_NOW) else {
            AppLog.log("mkxp core: dlopen failed: \(String(cString: dlerror()))")
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let setPath = symbol("gamecore_setGamePath", SetPath.self),
              let run = symbol("gamecore_run_app", RunApp.self),
              let key = symbol("gamecore_injectKeyEvent", KeyEvent.self)
        else {
            AppLog.log("mkxp core: missing gamecore_* symbols")
            return nil
        }
        return GameCoreSymbols(setGamePath: setPath, runApp: run, injectKey: key,
                               requestPause: symbol("gamecore_requestPause", Void0.self),
                               requestResume: symbol("gamecore_requestResume", Void0.self))
    }
}

@MainActor
final class MkxpRunner: RubyGameRunner {
    private static var symbols: GameCoreSymbols?
    private static var didLoad = false
    /// iOS can run one Ruby game per app launch (the core keeps the main thread).
    static var hasRun = false

    private static func core() -> GameCoreSymbols? {
        if !didLoad {
            didLoad = true
            symbols = GameCoreSymbols.load()
        }
        return symbols
    }

    var isAvailable: Bool { MkxpRunner.core() != nil && !MkxpRunner.hasRun }

    var unavailableReason: String {
        if MkxpRunner.core() == nil {
            return "The mkxp core could not be loaded from this build (MkxpCore.framework is missing or does not match). See the App Log."
        }
        return "A Ruby game already ran in this app session. Close NexPlay from the app switcher and open it again to start another XP/VX/Ace game."
    }

    func makeViewController(game: Game, onExit: @escaping () -> Void) -> UIViewController {
        guard let core = MkxpRunner.core(), !MkxpRunner.hasRun else {
            return RubyCoreStub().makeViewController(game: game, onExit: onExit)
        }
        return MkxpViewController(game: game, core: core, onExit: onExit)
    }

    fileprivate static func mark() { hasRun = true }
}

/// Starts the core and puts the touch controls over it in a window of their own.
private final class MkxpViewController: UIViewController, RubyPlayerControlling {
    private let game: Game
    private let core: GameCoreSymbols
    private let onExit: () -> Void
    private var controlsWindow: UIWindow?
    private var controllers: PhysicalControllerManager?
    private var started = false

    init(game: Game, core: GameCoreSymbols, onExit: @escaping () -> Void) {
        self.game = game
        self.core = core
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let label = UILabel()
        label.text = "Starting \(game.name)…"
        label.textColor = .white
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.textAlignment = .center
        view.addSubview(label)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        MkxpRunner.mark()
        AppLog.noteGame(game.name)
        AppLog.log("mkxp core: starting \(game.name) (\(game.engine.badge))")
        showControls()
        // The core must start from a run loop callout, never from a block on the main dispatch queue.
        let folder = Paths.entryDirectory(for: game).path
        let timer = Timer(timeInterval: 0.1, repeats: false) { [core] _ in
            folder.withCString { core.setGamePath($0) }
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup("NexPlay"), nil]
            let result = argv.withUnsafeMutableBufferPointer { buffer in
                core.runApp(1, buffer.baseAddress)
            }
            AppLog.log("mkxp core: run_app returned \(result)")
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showControls() {
        guard let scene = view.window?.windowScene else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIViewController()
        host.view.backgroundColor = .clear
        let overlay = GamepadOverlayView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.setProfile(LayoutStore.load(for: game.id))
        overlay.isHidden = !game.gamepad
        overlay.onKey = { [weak self] key, down in self?.send(key, down) }
        let gameID = game.id
        overlay.onSave = { profile in LayoutStore.save(profile, for: gameID) }
        overlay.onReset = {
            LayoutStore.reset(gameID)
            return LayoutStore.load(for: gameID)
        }
        host.view.addSubview(overlay)
        window.rootViewController = host
        window.isHidden = false
        controlsWindow = window

        let manager = PhysicalControllerManager(gameID: game.id)
        manager.onKey = { [weak self] key, down in self?.send(key, down) }
        manager.start()
        controllers = manager
    }

    /// DOM keyCode to SDL scancode, the keys GameCore.h expects.
    private func send(_ key: PadKey, _ down: Bool) {
        let code = key.keyCode
        var scancode: Int32 = 0
        switch code {
        case 65...90: scancode = Int32(4 + code - 65)        // A-Z
        case 49...57: scancode = Int32(30 + code - 49)       // 1-9
        case 48: scancode = 39                               // 0
        case 112...123: scancode = Int32(58 + code - 112)    // F1-F12
        case 13: scancode = 40
        case 27: scancode = 41
        case 8: scancode = 42
        case 9: scancode = 43
        case 32: scancode = 44
        case 33: scancode = 75
        case 34: scancode = 78
        case 39: scancode = 79
        case 37: scancode = 80
        case 40: scancode = 81
        case 38: scancode = 82
        case 16: scancode = 225
        case 17: scancode = 224
        case 18: scancode = 226
        default: return
        }
        core.injectKey(scancode, down ? 1 : 0)
    }

    func shutdownRuby() {
        controllers?.stop()
        controllers = nil
        controlsWindow?.isHidden = true
        controlsWindow = nil
        AppLog.noteGame(nil)
    }
}

/// A window that only takes touches that land on one of its controls.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self || view === rootViewController?.view ? nil : view
    }
}
#endif
