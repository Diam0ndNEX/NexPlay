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
    typealias SetSetting = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    typealias ApplyConfig = @convention(c) (UnsafeRawPointer?) -> Void
    typealias SetBool = @convention(c) (Bool) -> Void
    typealias MessageCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias SetMessageCallback = @convention(c) (MessageCallback?, UnsafeMutableRawPointer?) -> Void
    typealias EventCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias SetEventCallback = @convention(c) (EventCallback?, UnsafeMutableRawPointer?) -> Void
    typealias IntResult = @convention(c) () -> Int32

    let setGamePath: SetPath
    let runApp: RunApp
    let injectKey: KeyEvent
    let requestPause: Void0?
    let requestResume: Void0?
    // Optional launch steps (Empo's GameCore.h order). A core without one just skips it.
    let setDebugLogPath: SetPath?
    let setSetting: SetSetting?
    let applySessionConfig: ApplyConfig?
    let resetSessionState: Void0?
    let setControllerCapture: SetBool?
    let setErrorCallback: SetMessageCallback?
    let signalErrorDismissed: Void0?
    let setInfoCallback: SetMessageCallback?
    let signalInfoDismissed: Void0?
    let setTerminatedCallback: SetEventCallback?
    let didExitCleanly: IntResult?

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
        return GameCoreSymbols(
            setGamePath: setPath, runApp: run, injectKey: key,
            requestPause: symbol("gamecore_requestPause", Void0.self),
            requestResume: symbol("gamecore_requestResume", Void0.self),
            setDebugLogPath: symbol("gamecore_setDebugLogPath", SetPath.self),
            setSetting: symbol("gamecore_setSetting", SetSetting.self),
            applySessionConfig: symbol("gamecore_applySessionConfig", ApplyConfig.self),
            resetSessionState: symbol("gamecore_resetSessionState", Void0.self),
            setControllerCapture: symbol("gamecore_setGameControllerCaptureEnabled", SetBool.self),
            setErrorCallback: symbol("gamecore_setErrorMessageCallback", SetMessageCallback.self),
            signalErrorDismissed: symbol("gamecore_signalErrorDismissed", Void0.self),
            setInfoCallback: symbol("gamecore_setInfoMessageCallback", SetMessageCallback.self),
            signalInfoDismissed: symbol("gamecore_signalInfoDismissed", Void0.self),
            setTerminatedCallback: symbol("gamecore_setEngineTerminatedCallback", SetEventCallback.self),
            didExitCleanly: symbol("gamecore_didEngineExitCleanly", IntResult.self))
    }
}

/// Mirrors GameCoreSessionConfig in GameCore.h (two pointers, then the vertical alignment enum).
private struct MkxpSessionConfig {
    var userDataDirectory: UnsafePointer<CChar>?
    var sharedFontsDirectory: UnsafePointer<CChar>?
    var verticalAlignment: Int32
}

/// The core calls back on its own thread with a pointer to this. It only hops to the main actor.
private final class MkxpEvents: @unchecked Sendable {
    weak var owner: MkxpViewController?
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

/// Starts the core and puts the touch controls and a menu button over it in a window of their own.
private final class MkxpViewController: UIViewController, RubyPlayerControlling {
    private let game: Game
    private let core: GameCoreSymbols
    private let onExit: () -> Void
    private let events = MkxpEvents()
    private var controlsWindow: UIWindow?
    private var host: UIViewController?
    private var overlay: GamepadOverlayView?
    private var controllers: PhysicalControllerManager?
    private var started = false
    private var paused = false
    private var ended = false
    private var missingRTP: [String] = []

    init(game: Game, core: GameCoreSymbols, onExit: @escaping () -> Void) {
        self.game = game
        self.core = core
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        events.owner = self
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Orientation

    /// Auto-rotate in games (Settings) wins. Otherwise the game's own lock, and landscape when it has none,
    /// because RPG Maker XP/VX/Ace games are drawn for a wide screen.
    private var playOrientation: OrientationMode {
        if UserDefaults.standard.bool(forKey: SettingsKey.autoRotateInGames) { return .auto }
        return game.orientation == .auto ? .landscape : game.orientation
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { playOrientation.mask }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationManager.lock(playOrientation)
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: SettingsKey.keepScreenAwake)
    }

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
        // The core's own window comes up a moment later and can reset the orientation, so lock again.
        for delay in [0.6, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.ended else { return }
                OrientationManager.lock(self.playOrientation)
            }
        }
        // The core must start from a run loop callout, never from a block on the main dispatch queue.
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.launchCore()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Launch

    /// GameCore.h order: debug log, settings, session config, session reset, game path, run_app.
    private func launchCore() {
        let folderURL = Paths.entryDirectory(for: game)
        let folder = folderURL.path
        let core = self.core

        if let setLog = core.setDebugLogPath {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let log = caches.appendingPathComponent("mkxp-session.log").path
            try? FileManager.default.removeItem(atPath: log)
            log.withCString { setLog($0) }
        }

        func put(_ key: String, _ value: String) {
            guard let set = core.setSetting else { return }
            key.withCString { k in value.withCString { v in set(k, v) } }
        }
        let ruby = MkxpRTP.rubyVersion(in: folderURL)
        put("rubyVersion", ruby)
        put("postloadScripts", "1")
        put("networkEnabled", "1")
        // 8.13.13: the same launch settings as Empo (GameCoreLaunch / MkxpCore.launch), which starts LonaRPG where
        // NexPlay ended in a stack error: syntax transform "legacy" for Ruby 1.8/1.9 games ("modern" for 3.x),
        // the in-game keyboard off, and JoiPlay mode OFF (8.13.5 switched it on for every game; Empo's default is off).
        put("syntaxTransform", (ruby == "18" || ruby == "19") ? "legacy" : "modern")
        put("inGameKeyboard", "0")
        put("joiplayCompat", "0")

        // RTP folders NexPlay has, passed as mkxp's "RTP" list. The ones the game needs but we lack are noted.
        var rtpPaths: [String] = []
        missingRTP = []
        for kind in MkxpRTP.required(in: folderURL) {
            if MkxpRTP.has(kind) { rtpPaths.append(MkxpRTP.folder(kind).path) } else { missingRTP.append(kind) }
        }
        var overlay: [String: Any] = [:]
        if !rtpPaths.isEmpty { overlay["RTP"] = rtpPaths }
        let compatScripts = MkxpCompat.installedPaths(for: game.id)
        if !compatScripts.isEmpty { overlay["preloadScript"] = compatScripts }
        if compatScripts.count > 1 {
            AppLog.log("mkxp compat: call-depth trace is on for this run (the last run ended in a stack error)")
            // One run only: a stack error in this run switches it on again for the next, otherwise it stays off.
            UserDefaults.standard.removeObject(forKey: MkxpCompat.traceKey(game.id))
        }
        if !overlay.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: overlay),
           let json = String(data: data, encoding: .utf8) {
            put("configOverlay", json)
        }
        AppLog.log("mkxp core: ruby \(ruby), RTP given \(rtpPaths.count), missing \(missingRTP.joined(separator: ","))")

        if let apply = core.applySessionConfig {
            let support = Paths.support.appendingPathComponent("MkxpUserData", isDirectory: true)
            let fonts = Paths.support.appendingPathComponent("Fonts", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
            // The core may keep these pointers, so they are never freed.
            var config = MkxpSessionConfig(userDataDirectory: UnsafePointer(strdup(support.path)),
                                           sharedFontsDirectory: UnsafePointer(strdup(fonts.path)),
                                           verticalAlignment: 2)
            withUnsafePointer(to: &config) { apply(UnsafeRawPointer($0)) }
        }
        core.resetSessionState?()
        // NexPlay reads controllers itself (PhysicalControllerManager), so the core must not as well.
        core.setControllerCapture?(false)

        let box = Unmanaged.passUnretained(events).toOpaque()
        core.setErrorCallback?({ message, userdata in
            guard let userdata = userdata else { return }
            let events = Unmanaged<MkxpEvents>.fromOpaque(userdata).takeUnretainedValue()
            let text = message.map { String(cString: $0) } ?? "The game reported an error."
            Task { @MainActor in events.owner?.coreMessage(text, isError: true) }
        }, box)
        core.setInfoCallback?({ message, userdata in
            guard let userdata = userdata else { return }
            let events = Unmanaged<MkxpEvents>.fromOpaque(userdata).takeUnretainedValue()
            let text = message.map { String(cString: $0) } ?? ""
            Task { @MainActor in events.owner?.coreMessage(text, isError: false) }
        }, box)
        core.setTerminatedCallback?({ userdata in
            guard let userdata = userdata else { return }
            let events = Unmanaged<MkxpEvents>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in events.owner?.coreEnded() }
        }, box)

        folder.withCString { core.setGamePath($0) }
        // argv[0] of the real process, like Empo passes.
        var argv: [UnsafeMutablePointer<CChar>?] = [CommandLine.unsafeArgv[0], nil]
        let result = argv.withUnsafeMutableBufferPointer { buffer in
            core.runApp(1, buffer.baseAddress)
        }
        AppLog.log("mkxp core: run_app returned \(result)")
    }

    // MARK: - Messages from the core

    /// The core can wait for the person to close the alert, so OK must always call the signal.
    fileprivate func coreMessage(_ text: String, isError: Bool) {
        AppLog.log("mkxp core \(isError ? "error" : "info"): \(text)")
        // 8.13.12: Ruby cuts a stack error's backtrace to one frame. The next run of this game records its call depth
        // (NexDeepTrace) so Export Logs names what recurses; a run without the error turns it off again.
        if isError, text.contains("SystemStackError") {
            UserDefaults.standard.set(true, forKey: MkxpCompat.traceKey(game.id))
        }
        var body = text
        if isError, !missingRTP.isEmpty {
            let names = missingRTP.map { MkxpRTP.title($0) }.joined(separator: ", ")
            body += "\n\nThis game asks for \(names), which NexPlay doesn't have. Import it in Settings > Setup Center."
        }
        let alert = UIAlertController(title: isError ? "Game Error" : game.name, message: body, preferredStyle: .alert)
        if isError {
            alert.addAction(UIAlertAction(title: "Copy", style: .default) { [weak self] _ in
                UIPasteboard.general.string = body
                self?.core.signalErrorDismissed?()
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            if isError { self?.core.signalErrorDismissed?() } else { self?.core.signalInfoDismissed?() }
        })
        present(alert: alert)
    }

    fileprivate func coreEnded() {
        guard !ended else { return }
        ended = true
        let clean = (core.didExitCleanly?() ?? 0) != 0
        AppLog.log("mkxp core: game ended (clean exit: \(clean))")
        let alert = UIAlertController(
            title: clean ? "Game Closed" : "Game Stopped",
            message: clean
                ? "The game ended. To play another XP/VX/VX Ace game, close NexPlay from the app switcher and open it again."
                : "The game stopped before it ended on its own. See the App Log for the reason. To start again, close NexPlay from the app switcher and open it again.",
            preferredStyle: .alert)
        // 8.13.8: games whose own scripts need Windows (Win32API/DL, LonaRPG) can't be fixed in mkxp; offer the
        // Windows engine when the game ships a program for it. Applies on the next start.
        if !clean, game.runtime != .windows, GameRuntimes.choices(for: game).contains(.windows) {
            alert.message = (alert.message ?? "") + "\n\nThis game also has a Windows program. Use Windows Next Time sets Runs On to Windows (Game Settings > Runtime)."
            let gameID = game.id
            alert.addAction(UIAlertAction(title: "Use Windows Next Time", style: .default) { [weak self] _ in
                LibraryStore.current?.mutate(gameID) { $0.runtime = .windows }
                AppLog.log("mkxp core: Runs On set to Windows for the next start")
                self?.onExit()
            })
        }
        alert.addAction(UIAlertAction(title: "Back to Library", style: .default) { [weak self] _ in self?.onExit() })
        present(alert: alert)
    }

    /// Shown from the controls window, because the core's own window can sit above this view controller.
    private func present(alert: UIAlertController) {
        var top: UIViewController? = host ?? self
        while let next = top?.presentedViewController { top = next }
        top?.present(alert, animated: true)
    }

    // MARK: - Controls and menu

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
        overlay.onEditingChanged = { [weak self] _ in self?.refreshMenuButton() }
        host.view.addSubview(overlay)
        host.view.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 6),
            menuButton.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        window.rootViewController = host
        window.isHidden = false
        controlsWindow = window
        self.host = host
        self.overlay = overlay

        let manager = PhysicalControllerManager(gameID: game.id)
        manager.onKey = { [weak self] key, down in self?.send(key, down) }
        manager.start()
        controllers = manager
        refreshMenuButton()
    }

    private lazy var menuButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "ellipsis.circle.fill"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(white: 0, alpha: 0.35)
        button.layer.cornerRadius = 20
        button.alpha = 0.7
        button.accessibilityLabel = "Game menu"
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    /// The menu is rebuilt each time it opens, so its titles match the current state.
    private func refreshMenuButton() {
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuItems() ?? [])
            }
        ])
    }

    private func menuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if let overlay = overlay {
            if overlay.isEditing {
                items.append(UIAction(title: "Done Editing Controls", image: UIImage(systemName: "checkmark")) { [weak overlay] _ in
                    overlay?.endEditing(save: true)
                })
                items.append(UIAction(title: "Cancel Editing", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak overlay] _ in
                    overlay?.endEditing(save: false)
                })
            } else {
                let hidden = overlay.isHidden
                items.append(UIAction(title: hidden ? "Show Controls" : "Hide Controls",
                                      image: UIImage(systemName: hidden ? "gamecontroller" : "gamecontroller.fill")) { [weak overlay] _ in
                    overlay?.isHidden = !hidden
                })
                items.append(UIAction(title: "Edit Controls", image: UIImage(systemName: "slider.horizontal.3")) { [weak overlay] _ in
                    overlay?.beginEditing()
                })
            }
        }
        items.append(UIAction(title: "Esc (game menu)", image: UIImage(systemName: "line.3.horizontal")) { [weak self] _ in
            self?.tap(41)
        })
        items.append(UIAction(title: "Reset Game (F12)", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
            self?.tap(69)
        })
        if core.requestPause != nil, core.requestResume != nil {
            items.append(UIAction(title: paused ? "Resume" : "Pause",
                                  image: UIImage(systemName: paused ? "play.fill" : "pause.fill")) { [weak self] _ in
                self?.togglePause()
            })
        }
        items.append(UIAction(title: "Quit NexPlay", image: UIImage(systemName: "power"), attributes: .destructive) { [weak self] _ in
            self?.confirmQuit()
        })
        return items
    }

    private func tap(_ scancode: Int32) {
        core.injectKey(scancode, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [core] in core.injectKey(scancode, 0) }
    }

    private func togglePause() {
        paused.toggle()
        if paused { core.requestPause?() } else { core.requestResume?() }
    }

    /// A Ruby game can't be unloaded from the core, so closing the game closes the app.
    private func confirmQuit() {
        let alert = UIAlertController(
            title: "Quit NexPlay?",
            message: "The game can't be unloaded, so NexPlay closes. Progress you haven't saved in the game is lost.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { _ in exit(0) })
        present(alert: alert)
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
        host = nil
        overlay = nil
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationManager.unlock()
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
