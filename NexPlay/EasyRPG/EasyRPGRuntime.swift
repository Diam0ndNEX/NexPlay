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
    private var thread: Thread?

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
            let interval = 1.0 / max(nexretro_fps(), 1)
            var next = CACurrentMediaTime()
            while let self, !self.shouldStop {
                if self.isPaused {
                    Thread.sleep(forTimeInterval: 0.05)
                    next = CACurrentMediaTime()
                    continue
                }
                nexretro_run()
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

/// The full-screen EasyRPG player: the picture, touch controls, controllers, sound and the close button.
@MainActor
final class EasyRPGViewController: UIViewController {
    private let game: Game
    private let store: LibraryStore
    private let onExit: () -> Void
    private let loop = EasyRPGLoop()
    private let screen = UIView()
    private let controls = UIView()
    private let message = UILabel()
    private var displayLink: CADisplayLink?
    private let pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: 1024 * 1024)
    private var audio: AVAudioEngine?
    private var started = false
    private var shutDown = false
    private var sessionStart: Date?
    private var pressedByTouch: [Int: UInt32] = [:]

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
        screen.layer.magnificationFilter = .nearest
        screen.layer.contentsGravity = .resizeAspect
        view.addSubview(screen)

        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.text = "Starting \(game.name)…"
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)

        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.isMultipleTouchEnabled = true
        view.addSubview(controls)
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
        AppLog.log("easyrpg: running on \(String(cString: nexretro_core_name())), \(Int(nexretro_fps())) fps")
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
        guard !shutDown, displayLink != nil else { return }
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
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = UIColor.white.withAlphaComponent(0.6)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.accessibilityLabel = "Back to Library"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        let size: CGFloat = 56
        let pad = UIView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(pad)
        let face = UIView()
        face.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(face)
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            pad.bottomAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            pad.widthAnchor.constraint(equalToConstant: size * 3),
            pad.heightAnchor.constraint(equalToConstant: size * 3),
            face.trailingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            face.bottomAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            face.widthAnchor.constraint(equalToConstant: size * 3),
            face.heightAnchor.constraint(equalToConstant: size * 3),
        ])
        addButton("arrowtriangle.up.fill", .up, to: pad, x: 1, y: 0, size: size)
        addButton("arrowtriangle.down.fill", .down, to: pad, x: 1, y: 2, size: size)
        addButton("arrowtriangle.left.fill", .left, to: pad, x: 0, y: 1, size: size)
        addButton("arrowtriangle.right.fill", .right, to: pad, x: 2, y: 1, size: size)
        addButton("a.circle.fill", .a, to: face, x: 2, y: 1, size: size)
        addButton("b.circle.fill", .b, to: face, x: 1, y: 2, size: size)
        addButton("x.circle.fill", .x, to: face, x: 1, y: 0, size: size)
    }

    private func addButton(_ symbol: String, _ id: Pad, to parent: UIView, x: CGFloat, y: CGFloat, size: CGFloat) {
        let button = UIButton(type: .custom)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)), for: .normal)
        button.tintColor = UIColor.white.withAlphaComponent(0.45)
        button.frame = CGRect(x: x * size, y: y * size, width: size, height: size)
        button.tag = Int(id.rawValue)
        button.addTarget(self, action: #selector(buttonDown(_:)), for: [.touchDown, .touchDragEnter])
        button.addTarget(self, action: #selector(buttonUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        parent.addSubview(button)
    }

    @objc private func buttonDown(_ sender: UIButton) {
        nexretro_set_button(UInt32(sender.tag), true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func buttonUp(_ sender: UIButton) {
        nexretro_set_button(UInt32(sender.tag), false)
    }

    @objc private func controllerChanged() {
        let pads = GCController.controllers().compactMap(\.extendedGamepad)
        controls.isHidden = !pads.isEmpty
        for gamepad in pads {
            gamepad.valueChangedHandler = { pad, _ in
                let up = pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5
                let down = pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5
                let left = pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5
                let right = pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5
                nexretro_set_button(Pad.up.rawValue, up)
                nexretro_set_button(Pad.down.rawValue, down)
                nexretro_set_button(Pad.left.rawValue, left)
                nexretro_set_button(Pad.right.rawValue, right)
                nexretro_set_button(Pad.a.rawValue, pad.buttonA.isPressed)
                nexretro_set_button(Pad.b.rawValue, pad.buttonB.isPressed)
                nexretro_set_button(Pad.x.rawValue, pad.buttonX.isPressed)
                nexretro_set_button(Pad.y.rawValue, pad.buttonY.isPressed)
                nexretro_set_button(Pad.start.rawValue, pad.buttonMenu.isPressed)
                nexretro_set_button(Pad.l.rawValue, pad.leftShoulder.isPressed)
                nexretro_set_button(Pad.r.rawValue, pad.rightShoulder.isPressed)
            }
        }
    }
}
