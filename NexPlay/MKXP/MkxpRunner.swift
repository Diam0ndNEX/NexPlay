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
    typealias SetInt = @convention(c) (Int32) -> Void
    typealias DoubleResult = @convention(c) () -> Double
    typealias SnapshotSize = @convention(c) (UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Bool
    typealias CopySnapshot = @convention(c) (UnsafeMutablePointer<UInt8>?, Int32, UnsafeMutablePointer<Int32>?,
                                             UnsafeMutablePointer<Int32>?) -> Bool

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
    // 8.14.0: the in-game menu's tools (GameCore.h). Each is optional: a core without one hides its row.
    let setFastForward: SetInt?
    let setCheatsEnabled: SetBool?
    let averageFPS: DoubleResult?
    let snapshotSize: SnapshotSize?
    let copySnapshot: CopySnapshot?
    let pushTextInput: SetPath?
    let textInputActive: IntResult?

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
            didExitCleanly: symbol("gamecore_didEngineExitCleanly", IntResult.self),
            setFastForward: symbol("gamecore_setFastForwardMultiplier", SetInt.self),
            setCheatsEnabled: symbol("gamecore_setCheatsEnabled", SetBool.self),
            averageFPS: symbol("gamecore_getAverageFPS", DoubleResult.self),
            snapshotSize: symbol("gamecore_getSnapshotSize", SnapshotSize.self),
            copySnapshot: symbol("gamecore_copySnapshotRGBA", CopySnapshot.self),
            pushTextInput: symbol("gamecore_pushTextInput", SetPath.self),
            textInputActive: symbol("gamecore_isTextInputActive", IntResult.self))
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
/// A Date that can be read and written from any thread.
private final class NexAtomicDate {
    private let lock = NSLock()
    private var value = Date()
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return value }
}

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
    // 8.14.0
    private var speed = 1
    private var cheatsOn = false
    /// The game was paused for editing the touch controls (so their drag and tap gestures run: while the core runs it
    /// keeps the main run loop busy and UIKit gesture recognizers never fire).
    private var pausedForEditing = false
    private var hud: PerformanceHUDView?
    private var hudTimer: Timer?
    private var watchdog: DispatchSourceTimer?

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
        // 8.15.4: the core pauses by blocking the game thread, and when iOS sends the app to the background the
        // core's event loop (on the MAIN thread) waits for the game thread to stop at its next frame. A paused game
        // never gets there, so the main thread waited forever: no touches, no menu, no HUD after coming back.
        // The game is resumed before the app leaves the screen.
        NotificationCenter.default.addObserver(self, selector: #selector(resumeBeforeBackground),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeBeforeBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
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
            // 8.15.6: the last run's log is kept as mkxp-session.prev.log (Export Logs has both).
            let prev = caches.appendingPathComponent("mkxp-session.prev.log").path
            try? FileManager.default.removeItem(atPath: prev)
            try? FileManager.default.moveItem(atPath: log, toPath: prev)
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
        // 8.13.27: RPG Maker's own player stretches the game screen with smoothing (bilinear). The core's default is
        // nearest-neighbour, which at a phone's non-whole-number scale (640x360 shown about 3.3x) gives uneven, harsh
        // pixels that shimmer while the screen scrolls. Bilinear for upscaling, as on Windows.
        overlay["smoothScaling"] = NativeScaling.current(for: game.id).rawValue  // in-game menu > Display > Picture
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
        // 8.15.2: a heartbeat in the App Log every 5 s (time since start, the core's frame rate, paused or not). No line
        // = the main thread is stuck inside the core; fps 0 with lines = the game is not drawing.
        let startedAt = Date()
        let beat = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, !self.ended else { return }
            let fps = self.core.averageFPS.map { Int($0().rounded()) } ?? -1
            AppLog.log("mkxp: alive \(Int(Date().timeIntervalSince(startedAt))) s, fps \(fps), paused \(self.paused), panel \(self.panelController != nil), editing \(self.overlay?.isEditing == true)")
        }
        RunLoop.main.add(beat, forMode: .common)
        // 8.15.3: a watchdog on its own thread. The core runs on the main thread, so when the main thread stops serving
        // UIKit (touches, timers) the heartbeat above goes silent; this one keeps writing and says how long the main
        // queue has been stuck, with the core's frame rate.
        let mainSeen = NexAtomicDate()
        let watch = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watch.schedule(deadline: .now() + 2, repeating: 2)
        watch.setEventHandler { [weak self] in
            DispatchQueue.main.async { mainSeen.set(Date()) }
            guard let self = self else { return }
            let stuck = Date().timeIntervalSince(mainSeen.get())
            // 8.15.5: one line at 4 s, then one every 30 s while it lasts (not every 2 s).
            let seconds = Int(stuck)
            if stuck > 3, seconds < 6 || seconds % 30 < 2 {
                AppLog.log("mkxp: the main thread has not served UIKit for \(seconds) s (the core holds it)")
            }
        }
        mainSeen.set(Date())
        watch.resume()
        watchdog = watch
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
        // 8.14.0: wired like the web player (presets, Edit Button page, reset, global size and opacity).
        NativePad.wire(overlay, game: game) { [weak host] in host }
        overlay.isHidden = !game.gamepad
        overlay.onKey = { [weak self] key, down in self?.send(key, down) }
        overlay.onAction = { [weak self] action, down in self?.handleAction(action, down) }
        overlay.onEditingChanged = { [weak self] editing in self?.editingChanged(editing) }
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
        manager.onAction = { [weak self] action, down in self?.handleAction(action, down) }
        manager.start()
        controllers = manager
        refreshMenuButton()
        if game.statsOverlay == true { showHUD(true) }
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
        button.addAction(UIAction { [weak self] _ in self?.menuButtonTapped() }, for: .touchUpInside)
        return button
    }()

    /// The menu is rebuilt each time it opens, so its titles match the current state.
    private func refreshMenuButton() {
        if overlay?.isEditing == true {
            // While the touch controls are edited the button keeps a small menu (Done / Cancel).
            menuButton.showsMenuAsPrimaryAction = true
            menuButton.menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.menuItems() ?? [])
                }
            ])
        } else {
            menuButton.menu = nil
            menuButton.showsMenuAsPrimaryAction = false
        }
    }

    private func menuButtonTapped() {
        AppLog.log("mkxp: menu button tapped (editing \(overlay?.isEditing == true), panel \(panelController != nil))")
        guard overlay?.isEditing != true else { return }
        openPanel()
    }

    // 8.13.19: NexPlay's in-game menu (the panel the other engines use). The game is paused while it is open and goes
    // back to what it was (running, or paused if it was paused before or the panel's Pause switch is on).
    // 8.14.0: the shared native panel (NativeGamePanel.swift): the same tabs and rows as the web and Windows panels.
    private weak var panelController: UIViewController?
    private var panelKeepPaused = false

    private var canPause: Bool { core.requestPause != nil && core.requestResume != nil }

    private func openPanel() {
        guard let host = host, panelController == nil else { return }
        if overlay?.isEditing == true { overlay?.endEditing(save: true) }
        panelKeepPaused = paused
        if canPause && !paused { togglePause() }
        var setup = NativePanelSetup(game: game)
        setup.paused = panelKeepPaused
        setup.speed = speed
        setup.scaling = NativeScaling.current(for: game.id)
        setup.scalingChoices = NativeScaling.allCases
        setup.scalingLive = false
        setup.statsOn = game.statsOverlay ?? false
        setup.controlsHidden = overlay?.isHidden ?? false
        setup.exitTitle = "Quit NexPlay"
        setup.exitDetail = "The game can't be unloaded, so NexPlay closes."
        setup.close = { [weak self] in self?.closePanel() }
        if canPause {
            setup.setPaused = { [weak self] keep in self?.panelKeepPaused = keep }
        }
        if core.setFastForward != nil {
            setup.speeds = [1, 2, 3, 4, 6, 8]
            setup.setSpeed = { [weak self] value in self?.setSpeed(value) }
        }
        setup.gameMenu = { [weak self] in self?.closePanel { self?.tap(41) } }
        setup.restart = { [weak self] in self?.closePanel { self?.tap(69) } }
        if core.setCheatsEnabled != nil {
            setup.cheatsOn = cheatsOn
            setup.setCheats = { [weak self] on in self?.setCheats(on) }
            setup.openCheats = { [weak self] in self?.closePanel { self?.tap(74) } }
        }
        if core.snapshotSize != nil, core.copySnapshot != nil {
            setup.screenshot = { [weak self] in self?.takeScreenshot() }
        }
        setup.setScaling = { [weak self] value in
            guard let self else { return }
            NativeScaling.set(value, for: self.game.id)
        }
        setup.setStats = { [weak self] on in self?.setStats(on) }
        setup.setControlsHidden = { [weak self] hidden in self?.overlay?.isHidden = hidden }
        setup.editControls = { [weak self] in self?.closePanel { self?.overlay?.beginEditing() } }
        setup.preset = { [weak self] preset in self?.overlay?.applyPreset(preset) }
        setup.resetControls = { [weak self] in
            guard let self, let overlay = self.overlay else { return }
            NativePad.resetLayout(overlay, game: self.game)
        }
        setup.type = { [weak self] text in self?.typeText(text) }
        setup.exit = { exit(0) }
        let controller = NexMenuHostingController(rootView: NativeGamePanel(setup: setup))
        panelController = controller
        // 8.15.1: the panel is shown over whatever is on top (a core alert would make host.present fail silently and
        // leave the game paused for good = 0 fps, nothing answering). If it did not appear, the pause is undone.
        let wasPaused = panelKeepPaused
        AppLog.log("mkxp: panel opening (paused=\(paused))")
        (NativePad.top(host) ?? host).present(controller, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak controller] in
            guard let self = self, self.panelController != nil || controller != nil else { return }
            if controller?.presentingViewController == nil && controller?.view.window == nil {
                AppLog.log("mkxp: the panel did not appear; resuming the game")
                self.panelController = nil
                if self.canPause, self.paused != wasPaused { self.togglePause() }
            }
        }
    }

    private func closePanel(then action: (() -> Void)? = nil) {
        guard let controller = panelController else {
            action?()
            return
        }
        panelController = nil
        if canPause, paused != panelKeepPaused { togglePause() }
        controller.presentingViewController?.dismiss(animated: true) {
            if let action = action {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { action() }
            }
        }
    }

    // MARK: - 8.14.0: tools

    /// Buttons and controller buttons that are not keys.
    private func handleAction(_ action: ControlAction, _ down: Bool) {
        switch action {
        case .fastForward:
            guard down, core.setFastForward != nil else { return }
            let fast = max(2, min(9, game.fastForwardSpeed ?? 2))
            setSpeed(speed == 1 ? fast : 1)
        case .gamePanel:
            if down { openPanel() }
        case .scrollUp:
            send(.pageUp, down)
        case .scrollDown:
            send(.pageDown, down)
        case .showKeyboard:
            if down { openPanel() }
        case .quickSave, .quickLoad, .mouseLeft, .mouseRight:
            if down { AppLog.log("mkxp: \(action.title) is not available for XP/VX/VX Ace games") }
        default:
            if let key = action.padKey { send(key, down) }
        }
    }

    private func setSpeed(_ value: Int) {
        speed = max(1, min(9, value))
        core.setFastForward?(Int32(speed))
        AppLog.log("mkxp: game speed \(speed)x")
    }

    private func setCheats(_ on: Bool) {
        cheatsOn = on
        core.setCheatsEnabled?(on)
        AppLog.log("mkxp: cheat menu \(on ? "on" : "off")")
    }

    /// The core keeps a picture of the paused game (the panel pauses it), so this works from the menu.
    private func takeScreenshot() {
        guard let size = core.snapshotSize, let copy = core.copySnapshot else { return }
        var width: Int32 = 0
        var height: Int32 = 0
        guard size(&width, &height), width > 0, height > 0 else {
            AppLog.log("mkxp: no picture for a screenshot")
            return
        }
        let total = Int(width) * Int(height) * 4
        var buffer = [UInt8](repeating: 0, count: total)
        let ok = buffer.withUnsafeMutableBufferPointer { pointer in
            copy(pointer.baseAddress, Int32(total), &width, &height)
        }
        guard ok, let provider = CGDataProvider(data: Data(buffer) as CFData),
              let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            AppLog.log("mkxp: the screenshot could not be read")
            return
        }
        NativePad.save(screenshot: UIImage(cgImage: image), for: game)
    }

    /// Text for a game's name entry: the core's text input when the game asks for text, else key presses.
    private func typeText(_ text: String) {
        if let push = core.pushTextInput, (core.textInputActive?() ?? 0) != 0 {
            text.withCString { push($0) }
            return
        }
        var delay = 0.0
        for character in text.uppercased() {
            guard let ascii = character.asciiValue else { continue }
            let code = Int(ascii)
            guard (65...90).contains(code) || (48...57).contains(code) || code == 32 else { continue }
            let key = PadKey.fromKeyCode(code == 32 ? 32 : code)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.send(key, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.06) { [weak self] in self?.send(key, false) }
            delay += 0.12
        }
    }

    /// Editing the touch controls pauses the game, so dragging, tapping and the + menu work (see `pausedForEditing`).
    /// 8.15.4: editing no longer pauses the game (see `resumeBeforeBackground`: a paused core can lock the app).
    private func editingChanged(_ editing: Bool) {
        if !editing, pausedForEditing {
            pausedForEditing = false
            if paused { togglePause() }
        }
        refreshMenuButton()
    }

    // MARK: Performance HUD

    private func setStats(_ on: Bool) {
        let gameID = game.id
        LibraryStore.current?.mutate(gameID) { $0.statsOverlay = on }
        showHUD(on)
    }

    private func showHUD(_ on: Bool) {
        hudTimer?.invalidate()
        hudTimer = nil
        hud?.removeFromSuperview()
        hud = nil
        guard on, let view = host?.view else { return }
        let panel = PerformanceHUDView(frame: .zero)
        panel.context = "\(game.engine.badge) · mkxp"
        view.addSubview(panel)
        hud = panel
        refreshHUD()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHUD() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    private func refreshHUD() {
        guard let hud, let view = host?.view else { return }
        let fps = core.averageFPS.map { Int($0().rounded()) }
        hud.update(fps: fps)
        hud.place(in: view.bounds, insets: view.safeAreaInsets)
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

    @objc private func resumeBeforeBackground() {
        guard paused, canPause else { return }
        AppLog.log("mkxp: app leaving the screen, the game is resumed so it can't lock up")
        paused = false
        pausedForEditing = false
        panelKeepPaused = false
        core.requestResume?()
    }

    private func togglePause() {
        paused.toggle()
        AppLog.log("mkxp: \(paused ? "pause" : "resume")")
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
    private var sentLogged = 0

    private func send(_ key: PadKey, _ down: Bool) {
        let code = key.keyCode
        if sentLogged < 25 {
            sentLogged += 1
            AppLog.log("mkxp: touch key \(code) \(down ? "down" : "up") (\(sentLogged)/25 logged)")
        }
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
        case 36: scancode = 74                               // Home
        case 35: scancode = 77                               // End
        case 45: scancode = 73                               // Insert
        case 46: scancode = 76                               // Delete
        case 186: scancode = 51                              // ;
        case 187: scancode = 46                              // =
        case 188: scancode = 54                              // ,
        case 189: scancode = 45                              // -
        case 190: scancode = 55                              // .
        case 191: scancode = 56                              // /
        case 192: scancode = 53                              // `
        case 219: scancode = 47                              // [
        case 220: scancode = 49                              // \\
        case 221: scancode = 48                              // ]
        case 222: scancode = 52                              // '
        default: return
        }
        core.injectKey(scancode, down ? 1 : 0)
    }

    func shutdownRuby() {
        hudTimer?.invalidate()
        hudTimer = nil
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
