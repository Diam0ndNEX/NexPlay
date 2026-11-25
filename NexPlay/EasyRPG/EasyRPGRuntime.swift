import AVFoundation
import GameController
import UIKit

// 7.1.1: RPG Maker 2000/2003 games run natively on EasyRPG Player (https://easyrpg.org, GPL-3.0; liblcf, MIT): its
// libretro core for iOS arm64, fetched from the libretro buildbot when NexPlay is built (tools/easyrpg) and wrapped as
// Frameworks/EasyRPGCore.framework. NexRetro.c is the small libretro frontend; this file is the player around it.

enum EasyRPGCore {
    static var libraryURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("EasyRPGCore.framework/EasyRPGCore")
    }

    static var isPresent: Bool {
        guard let url = libraryURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The buildbot file date written when NexPlay was built, or nil.
    static var buildDate: String? {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("EasyRPGCore.framework/core.version"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// EasyRPG's system folder: the RTP goes in rtp/2000 and rtp/2003 here.
    static let systemFolder: URL = {
        let dir = Paths.support.appendingPathComponent("EasyRPG", isDirectory: true)
        for sub in ["rtp/2000", "rtp/2003"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
        return dir
    }()

    static func rtpFolder(_ version: String) -> URL {
        systemFolder.appendingPathComponent("rtp/\(version)", isDirectory: true)
    }

    static func hasRTP(_ version: String) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: rtpFolder(version).path)) ?? []).isEmpty
    }

    /// Copies an RTP folder the player picked (the installed RTP's folder, with Backdrop, CharSet, ...) into rtp/<version>.
    static func importRTP(from url: URL, version: String) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let target = rtpFolder(version)
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        try fm.copyItem(at: url, to: target)
    }

    /// The game's database (RPG_RT.ldb), at the top or one level down. Relative to `root`.
    static func findDatabase(in root: URL) -> String? {
        let fm = FileManager.default
        var level = [root]
        for _ in 0...2 {
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                if let ldb = kids.first(where: { $0.lastPathComponent.lowercased() == "rpg_rt.ldb" }) {
                    return GameScanner.relativePath(of: ldb, in: root)
                }
                next += kids.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            level = next
        }
        return nil
    }

    /// The title in RPG_RT.ini ([RPG_RT] GameTitle=), read as Shift-JIS or CP1252 when it isn't UTF-8.
    static func title(database: URL) -> String? {
        let ini = database.deletingLastPathComponent().appendingPathComponent("RPG_RT.ini")
        guard let text = ImportPipeline.readText(ini) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("gametitle=") {
                let title = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
        }
        return nil
    }

    /// Runs `body` with a C buffer for an error message; returns the message when `body` fails.
    static func withError(_ body: (UnsafeMutablePointer<CChar>, Int) -> Bool) -> String? {
        var buffer = [CChar](repeating: 0, count: 2048)
        let size = buffer.count
        let ok = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, size) }
        if ok { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct EasyRPGGameRuntime: GameRuntime {
    var kind: RuntimeKind { .easyrpg }
    var isAvailable: Bool { EasyRPGCore.isPresent }

    var unavailableReason: String {
        "This build has no EasyRPG core, so RPG Maker 2000/2003 games can't run natively. Pick Windows in Game Settings > Runtime, or install a newer build."
    }

    func capabilities(for game: Game) -> RuntimeCapabilities {
        RuntimeCapabilities()
    }

    func makeViewController(game: Game, store: LibraryStore, onExit: @escaping () -> Void) -> UIViewController {
        guard isAvailable else {
            return RuntimeUnavailableController.make(title: game.name, reason: unavailableReason, onExit: onExit)
        }
        return EasyRPGViewController(game: game, store: store, onExit: onExit)
    }
}

/// Runs the core on its own thread at the game's frame rate.
final class EasyRPGLoop {
    private let lock = NSLock()
    private var stopping = false
    private var paused = false
    private var multiplier = 1
    private var thread: Thread?

    private var resetAsked = false

    /// 8.14.0: the core is reset on its own thread before its next frame (the core is not thread safe).
    func requestReset() {
        lock.lock(); resetAsked = true; lock.unlock()
    }

    private func takeReset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let asked = resetAsked
        resetAsked = false
        return asked
    }

    /// 8.14.0: frames per tick (fast forward), 1...9.
    var speed: Int {
        get { lock.lock(); defer { lock.unlock() }; return multiplier }
        set { lock.lock(); multiplier = max(1, min(9, newValue)); lock.unlock() }
    }

    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    /// Loads the game on the core thread; `loaded` is called on the main thread with nil or an error.
    /// `finished` is called on the main thread once the core is unloaded after `stop()`.
    func start(core: String, game: String, system: String, saves: String,
               loaded: @escaping (String?) -> Void, finished: @escaping () -> Void) {
        let worker = Thread { [weak self] in
            if let error = EasyRPGCore.withError({ nexretro_open(core, $0, $1) })
                ?? EasyRPGCore.withError({ nexretro_load_game(game, system, saves, $0, $1) }) {
                DispatchQueue.main.async { loaded(error); finished() }
                return
            }
            DispatchQueue.main.async { loaded(nil) }
            let reported = nexretro_fps()
            let interval = 1.0 / (reported.isFinite && reported >= 1 ? reported : 60)   // 8.20.1: max(NaN, 1) is NaN
            var next = CACurrentMediaTime()
            while let self, !self.shouldStop {
                if self.isPaused {
                    Thread.sleep(forTimeInterval: 0.05)
                    next = CACurrentMediaTime()
                    continue
                }
                if self.takeReset() { nexretro_reset() }
                let frames = self.speed
                for _ in 0..<frames { nexretro_run() }
                next += interval
                let wait = next - CACurrentMediaTime()
                if wait > 0 {
                    Thread.sleep(forTimeInterval: wait)
                } else if wait < -0.25 {
                    next = CACurrentMediaTime()
                }
            }
            nexretro_unload()
            DispatchQueue.main.async { finished() }
        }
        worker.name = "NexPlay EasyRPG"
        worker.qualityOfService = .userInteractive
        thread = worker
        worker.start()
    }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
    }
}

/// The full-screen EasyRPG player: the picture, NexPlay's touch controls and in-game menu (8.14.0), controllers, sound.
@MainActor
final class EasyRPGViewController: UIViewController {
    private let game: Game
    private let store: LibraryStore
    private let onExit: () -> Void
    private let loop = EasyRPGLoop()
    private let screen = UIView()
    private let message = UILabel()
    private var displayLink: CADisplayLink?
    private let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: 1024 * 1024)
    private var audio: AVAudioEngine?
    private var started = false
    private var shutDown = false
    private var sessionStart: Date?
    // 8.14.0: NexPlay's touch controls, in-game menu, controllers and HUD (the same as the other engines).
    private let pad = GamepadOverlayView()
    private let menuButton = UIButton(type: .system)
    private var controllers: PhysicalControllerManager?
    private var held: [UInt32: Int] = [:]
    private var lastImage: CGImage?
    private var frames = 0
    private var hud: PerformanceHUDView?
    private var hudTimer: Timer?
    private weak var panelController: UIViewController?
    private var keepPaused = false
    private var userPaused = false
    private var pausedForEditing = false

    init(game: Game, store: LibraryStore, onExit: @escaping () -> Void) {
        self.game = game
        self.store = store
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        pixels.deallocate()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true

        screen.frame = view.bounds
        screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        screen.layer.magnificationFilter = NativeScaling.current(for: game.id) == .sharp ? .nearest : .linear
        screen.layer.contentsGravity = .resizeAspect
        view.addSubview(screen)

        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.text = "Starting \(game.name)…"
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)

        buildControls()

        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            message.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged),
                                               name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerChanged),
                                               name: .GCControllerDidDisconnect, object: nil)
        let manager = PhysicalControllerManager(gameID: game.id)
        manager.onKey = { [weak self] key, down in self?.press(key, down) }
        manager.onAction = { [weak self] action, down in self?.handleAction(action, down) }
        manager.start()
        controllers = manager
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        controllerChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        OrientationManager.lock(game.orientation)
        UIApplication.shared.isIdleTimerDisabled = true
        start()
    }

    // MARK: Start and stop

    private func start() {
        guard let core = EasyRPGCore.libraryURL?.path else { return }
        let folder = Paths.folder(for: game)
        let database = folder.appendingPathComponent(game.entry)
        let gameFolder = database.deletingLastPathComponent().path
        AppLog.noteGame(game.name)
        AppLog.log("easyrpg: starting \(game.name)")
        loop.start(core: core, game: database.path, system: EasyRPGCore.systemFolder.path, saves: gameFolder,
                   loaded: { [weak self] error in self?.loaded(error) },
                   finished: { [weak self] in self?.finished() })
    }

    private func loaded(_ error: String?) {
        if let error {
            AppLog.log("easyrpg: \(error)")
            message.text = "\(game.name)\n\n\(error)"
            return
        }
        message.isHidden = true
        AppLog.log("easyrpg: running on \(String(cString: nexretro_core_name())), \(nexretro_fps().isFinite ? Int(nexretro_fps()) : 0) fps")
        startAudio(rate: nexretro_sample_rate())
        let link = CADisplayLink(target: self, selector: #selector(drawFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
        sessionStart = Date()
        store.mutate(game.id) { $0.playCount += 1; $0.lastPlayed = Date() }
    }

    /// Stops the core; safe to call more than once.
    func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        loop.stop()
        displayLink?.invalidate()
        displayLink = nil
        audio?.stop()
        audio = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if let start = sessionStart {
            let seconds = Date().timeIntervalSince(start)
            sessionStart = nil
            store.mutate(game.id) {
                $0.playSeconds += seconds
                if seconds >= 120 { $0.lastGoodRuntime = .easyrpg }
            }
        }
        for id in 0..<16 { nexretro_set_button(UInt32(id), false) }
        held = [:]
        controllers?.stop()
        controllers = nil
        hudTimer?.invalidate()
        hudTimer = nil
    }

    private func finished() {
        if !shutDown { message.isHidden = false }
    }

    @objc private func close() {
        shutdown()
        OrientationManager.unlock()
        onExit()
    }

    @objc private func willResignActive() {
        loop.isPaused = true
        audio?.pause()
        if let start = sessionStart {
            let seconds = Date().timeIntervalSince(start)
            sessionStart = nil
            store.mutate(game.id) { $0.playSeconds += seconds }
        }
    }

    @objc private func didBecomeActive() {
        guard !shutDown, displayLink != nil, !userPaused, panelController == nil, !pad.isEditing else { return }
        loop.isPaused = false
        try? audio?.start()
        sessionStart = Date()
    }

    // MARK: Picture

    @objc private func drawFrame() {
        var width: UInt32 = 0
        var height: UInt32 = 0
        guard nexretro_copy_frame(pixels, 1024 * 1024, &width, &height), width > 0, height > 0 else { return }
        let bytes = Int(width) * Int(height) * 4
        let data = Data(bytes: UnsafeRawPointer(pixels), count: bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        lastImage = image
        frames += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.layer.contents = image
        CATransaction.commit()
    }

    // MARK: Sound

    private func startAudio(rate: Double) {
        let session = AVAudioSession.sharedInstance()
        let silent = UserDefaults.standard.bool(forKey: SettingsKey.silentModeAudio)
        try? session.setCategory(silent ? .playback : .ambient, mode: .default, options: [])
        try? session.setActive(true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let source = Self.makeSource(format: format)
        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            audio = engine
        } catch {
            AppLog.log("easyrpg: sound didn't start: \(error.localizedDescription)")
        }
    }

    /// The sound source, made outside the main actor: its block runs on the audio thread.
    nonisolated private static func makeSource(format: AVAudioFormat) -> AVAudioSourceNode {
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 8192 * 2)
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let wanted = min(Int(frameCount), 8192)
            let got = nexretro_read_audio(scratch, wanted)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<Int(frameCount) {
                if i < got {
                    left[i] = Float(scratch[i * 2]) / 32768
                    right[i] = Float(scratch[i * 2 + 1]) / 32768
                } else {
                    left[i] = 0
                    right[i] = 0
                }
            }
            return noErr
        }
    }

    // MARK: Controls

    /// Joypad ids (RETRO_DEVICE_ID_JOYPAD_*): EasyRPG maps A to Decision, B to Cancel/Menu, X to Shift.
    private enum Pad: UInt32 {
        case b = 0, y = 1, select = 2, start = 3, up = 4, down = 5, left = 6, right = 7, a = 8, x = 9, l = 10, r = 11
    }

    private func buildControls() {
        pad.frame = view.bounds
        pad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        NativePad.wire(pad, game: game) { [weak self] in self }
        pad.isHidden = !game.gamepad
        pad.onKey = { [weak self] key, down in self?.press(key, down) }
        pad.onAction = { [weak self] action, down in self?.handleAction(action, down) }
        pad.onEditingChanged = { [weak self] editing in self?.editingChanged(editing) }
        view.addSubview(pad)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.setImage(UIImage(systemName: "ellipsis.circle.fill"), for: .normal)
        menuButton.tintColor = .white
        menuButton.backgroundColor = UIColor(white: 0, alpha: 0.35)
        menuButton.layer.cornerRadius = 20
        menuButton.alpha = 0.7
        menuButton.accessibilityLabel = "Game menu"
        menuButton.addAction(UIAction { [weak self] _ in self?.menuButtonTapped() }, for: .touchUpInside)
        view.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        if game.statsOverlay == true { showHUD(true) }
    }

    /// A key from the touch controls or a controller, as EasyRPG's joypad: arrows and W/A/S/D move, Z/Enter/Space
    /// decide, X/Esc/Backspace cancel, Shift is EasyRPG's Shift, Page Up/Down are L/R, F12 resets.
    private func press(_ key: PadKey, _ down: Bool) {
        let id: Pad
        switch key.keyCode {
        case 38, 87: id = .up
        case 40, 83: id = .down
        case 37, 65: id = .left
        case 39, 68: id = .right
        case 90, 13, 32, 67: id = .a
        case 88, 27, 8, 86, 66, 78: id = .b
        case 16: id = .x
        case 9, 81: id = .y
        case 33: id = .l
        case 34: id = .r
        case 113: id = .select
        case 123:
            if down { loop.requestReset() }
            return
        default: return
        }
        let count = max(0, (held[id.rawValue] ?? 0) + (down ? 1 : -1))
        held[id.rawValue] = count
        nexretro_set_button(id.rawValue, count > 0)
    }

    private func handleAction(_ action: ControlAction, _ down: Bool) {
        switch action {
        case .fastForward:
            guard down else { return }
            let fast = max(2, min(9, game.fastForwardSpeed ?? 2))
            loop.speed = loop.speed == 1 ? fast : 1
        case .gamePanel, .showKeyboard:
            if down { openPanel() }
        case .scrollUp:
            press(.pageUp, down)
        case .scrollDown:
            press(.pageDown, down)
        case .quickSave, .quickLoad, .mouseLeft, .mouseRight:
            if down { AppLog.log("easyrpg: \(action.title) is not available for RPG Maker 2000/2003 games") }
        default:
            if let key = action.padKey { press(key, down) }
        }
    }

    private func setPaused(_ on: Bool) {
        guard displayLink != nil else { return }
        loop.isPaused = on
        if on { audio?.pause() } else { try? audio?.start() }
    }

    private func editingChanged(_ editing: Bool) {
        menuButton.isHidden = editing
        if editing {
            if !userPaused && !loop.isPaused {
                setPaused(true)
                pausedForEditing = true
            }
            addDoneButton()
        } else {
            doneButton?.removeFromSuperview()
            doneButton = nil
            if pausedForEditing {
                pausedForEditing = false
                setPaused(false)
            }
        }
    }

    private var doneButton: UIButton?

    /// While the controls are edited: Done (save) and Cancel at the top left.
    private func addDoneButton() {
        guard doneButton == nil else { return }
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Done", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.tintColor = .white
        button.backgroundColor = UIColor(red: 0.2, green: 0.72, blue: 0.33, alpha: 1)
        button.layer.cornerRadius = 18
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        button.showsMenuAsPrimaryAction = false
        button.addAction(UIAction { [weak self] _ in self?.pad.endEditing(save: true) }, for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])
        doneButton = button
    }

    // MARK: In-game menu (8.14.0)

    private func menuButtonTapped() {
        guard !pad.isEditing else { return }
        openPanel()
    }

    private func openPanel() {
        guard panelController == nil, !shutDown else { return }
        keepPaused = userPaused
        setPaused(true)
        var setup = NativePanelSetup(game: game)
        setup.paused = userPaused
        setup.speed = loop.speed
        setup.speeds = [1, 2, 3, 4, 6, 8]
        setup.scaling = NativeScaling.current(for: game.id)
        setup.scalingChoices = [.sharp, .smooth]
        setup.scalingLive = true
        setup.statsOn = game.statsOverlay ?? false
        setup.controlsHidden = pad.isHidden
        setup.close = { [weak self] in self?.closePanel() }
        setup.setPaused = { [weak self] on in self?.keepPaused = on }
        setup.setSpeed = { [weak self] value in self?.loop.speed = value }
        setup.gameMenu = { [weak self] in self?.closePanel { self?.tapButton(.b) } }
        setup.restart = { [weak self] in self?.closePanel { self?.loop.requestReset() } }
        setup.screenshot = { [weak self] in self?.takeScreenshot() }
        setup.setScaling = { [weak self] value in
            guard let self else { return }
            NativeScaling.set(value, for: self.game.id)
            self.screen.layer.magnificationFilter = value == .sharp ? .nearest : .linear
        }
        setup.setStats = { [weak self] on in self?.setStats(on) }
        setup.setControlsHidden = { [weak self] hidden in self?.pad.isHidden = hidden }
        setup.editControls = { [weak self] in self?.closePanel { self?.pad.beginEditing() } }
        setup.preset = { [weak self] preset in self?.pad.applyPreset(preset) }
        setup.resetControls = { [weak self] in
            guard let self else { return }
            NativePad.resetLayout(self.pad, game: self.game)
        }
        setup.exit = { [weak self] in self?.closePanel { self?.close() } }
        let controller = NexMenuHostingController(rootView: NativeGamePanel(setup: setup))
        panelController = controller
        present(controller, animated: true)
    }

    private func closePanel(then action: (() -> Void)? = nil) {
        guard let controller = panelController else {
            action?()
            return
        }
        panelController = nil
        userPaused = keepPaused
        setPaused(userPaused)
        controller.dismiss(animated: true) {
            if let action { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action() } }
        }
    }

    private func tapButton(_ id: Pad) {
        nexretro_set_button(id.rawValue, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nexretro_set_button(id.rawValue, false) }
    }

    private func takeScreenshot() {
        guard let image = lastImage else { return }
        NativePad.save(screenshot: UIImage(cgImage: image), for: game)
    }

    // MARK: Performance HUD

    private func setStats(_ on: Bool) {
        let gameID = game.id
        store.mutate(gameID) { $0.statsOverlay = on }
        showHUD(on)
    }

    private func showHUD(_ on: Bool) {
        hudTimer?.invalidate()
        hudTimer = nil
        hud?.removeFromSuperview()
        hud = nil
        guard on else { return }
        let panel = PerformanceHUDView(frame: .zero)
        panel.context = "2000/2003 · EasyRPG"
        view.addSubview(panel)
        view.bringSubviewToFront(menuButton)
        hud = panel
        frames = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHUD() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
        refreshHUD()
    }

    private func refreshHUD() {
        guard let hud else { return }
        hud.update(fps: frames)
        frames = 0
        hud.place(in: view.bounds, insets: view.safeAreaInsets)
    }

    /// A controller hides the touch controls when Settings asks for it (Hide Pad With Controller).
    @objc private func controllerChanged() {
        let prefs = ControlPrefs.current()
        guard prefs.hidePadWithController, !pad.isEditing else { return }
        pad.isHidden = !GCController.controllers().isEmpty || !game.gamepad
    }
}
