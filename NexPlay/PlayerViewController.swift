import UIKit
import SwiftUI
import WebKit
import GameController
import AVFoundation
import UniformTypeIdentifiers

struct PlayerScreen: UIViewControllerRepresentable {
    let game: Game
    let store: LibraryStore
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> PlayerViewController {
        PlayerViewController(game: game, store: store, onExit: onExit)
    }

    func updateUIViewController(_ uiViewController: PlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: PlayerViewController, coordinator: ()) {
        uiViewController.shutdown()
    }
}

final class PlayerViewController: GCEventViewController, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate,
    UIGestureRecognizerDelegate {
    private enum PickPurpose {
        case jsonRestore
        case zipRestore
    }

    private var game: Game
    private let store: LibraryStore
    private let onExit: () -> Void

    private var webView: WKWebView!
    private var webTop: NSLayoutConstraint?
    private var webBottom: NSLayoutConstraint?
    private let statsReceiver = StatsReceiver()
    private let logReceiver = LogReceiver()
    private let exitReceiver = MessageReceiver()
    private let gameLog = GameLog()
    private let gamepad = GamepadOverlayView()
    private let controlBar = ControlBarView()
    private let keySender = KeySenderField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let banner = UILabel()
    private let statsLabel = UILabel()
    private let prefs = ControlPrefs.current()

    private var speed = 1
    private var currentFPS = 0
    private var statsTimer: Timer?
    private var bannerTimer: Timer?
    private var sessionStart: Date?
    private var loadStart: Date?
    private var didCountPlay = false
    private var isShutDown = false
    private var isEditingControls = false
    private var controllerConnected = false
    private var loadTask: Task<Void, Never>?
    private var pickPurpose: PickPurpose = .jsonRestore
    private var didWarnAboutMemory = false
    private var migrationRunning = false
    private let keyRouter = KeyRouter()
    private var controllers: PhysicalControllerManager?
    private var context: PlayerContext!
    private var features: [PlayerFeature] = []
    private var featureHandlerNames: [String] = []
    private var fastForwardOn = false

    init(game: Game, store: LibraryStore, onExit: @escaping () -> Void) {
        self.game = game
        self.store = store
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        // The game gets controller input through the Gamepad API instead of iOS menu navigation.
        controllerUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Auto-rotate in games (Settings) wins over the game's own orientation lock.
    private var playOrientation: OrientationMode {
        UserDefaults.standard.bool(forKey: SettingsKey.autoRotateInGames) ? .auto : game.orientation
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureAudio()

        let config = WKWebViewConfiguration()
        let handler = NexSchemeHandler(rootDirectory: Paths.folder(for: game),
                                       protectedDirectories: [Paths.entryDirectory(for: game)])
        handler.fileOverride = PlayerFeatures.fileOverride(for: game)
        config.setURLSchemeHandler(handler, forURLScheme: NexSchemeHandler.scheme)
        config.websiteDataStore = DataStores.store(for: game)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        let defaults = UserDefaults.standard
        let content = config.userContentController
        content.addUserScript(WKUserScript(source: PageScripts.diagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: PageScripts.identity(version: PlayerViewController.appVersion),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: PageScripts.keyBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if game.usesNWMode {
            let folder = (game.entry as NSString).deletingLastPathComponent
            content.addUserScript(WKUserScript(source: PageScripts.nwShim(entryFolder: folder),
                                               injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if game.engine.isRPGMaker {
            let runtime = PageScripts.rpgRuntime(pixelated: defaults.bool(forKey: SettingsKey.pixelatedScaling))
            content.addUserScript(WKUserScript(source: runtime, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        content.addUserScript(WKUserScript(source: PageScripts.noSelect, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: PageScripts.stats, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        content.add(statsReceiver, name: "nexStats")
        content.add(logReceiver, name: "nexLog")
        content.add(exitReceiver, name: "nexExit")

        context = PlayerContext(gameLog: gameLog)
        context.game = { [weak self] in self?.game ?? Game(name: "", engine: .web, entry: "") }
        context.present = { [weak self] controller in self?.presentOnTop(controller) }
        context.reload = { [weak self] in self?.prepareAndLoad() }
        context.update = { [weak self] change in self?.update(change) }
        features = PlayerFeatures.make(context: context)
        for feature in features {
            for script in feature.userScripts(for: game) { content.addUserScript(script) }
            for name in feature.messageNames {
                let receiver = MessageReceiver()
                receiver.onMessage = { [weak feature] body in feature?.receive(name: name, body: body) }
                content.add(receiver, name: name)
                featureHandlerNames.append(name)
            }
        }
        statsReceiver.onFPS = { [weak self] fps in self?.currentFPS = fps }
        logReceiver.onLine = { [weak self] line in self?.noteLine(line) }
        exitReceiver.onMessage = { [weak self] _ in
            self?.gameLog.add("the game asked to quit")
            self?.exitGame()
        }

        webView = WKWebView(frame: .zero, configuration: config)
        context.webView = webView
        keyRouter.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if game.engine.isRPGMaker && defaults.bool(forKey: SettingsKey.desktopMode) {
            webView.customUserAgent = PageScripts.desktopUserAgent
        }
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        let guide = view.safeAreaLayoutGuide
        let top = webView.topAnchor.constraint(equalTo: guide.topAnchor)
        let bottom = webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        webTop = top
        webBottom = bottom
        NSLayoutConstraint.activate([
            top,
            bottom,
            webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])

        configureGamepad()
        configureControllers()
        configureControlBar()
        configureLabels()
        configureKeySender()

        let wake = UITapGestureRecognizer(target: self, action: #selector(screenTapped))
        wake.cancelsTouchesInView = false
        wake.delaysTouchesBegan = false
        wake.delaysTouchesEnded = false
        wake.delegate = self
        view.addGestureRecognizer(wake)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillResign), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(controllersChanged), name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(controllersChanged), name: .GCControllerDidDisconnect, object: nil)

        gameLog.add(game.usesNWMode ? "NW.js mode: saves are files in save/" : "browser mode: saves are in web storage")
        prepareAndLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationManager.lock(playOrientation)
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: SettingsKey.keepScreenAwake)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didCountPlay {
            didCountPlay = true
            update { $0.playCount += 1; $0.lastPlayed = Date() }
            AppLog.noteGame(game.name)
        }
        if sessionStart == nil { sessionStart = Date() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.safeAreaInsets
        statsLabel.frame = CGRect(x: insets.left + 10, y: insets.top + 8, width: 210, height: 22)
        layoutBanner()

        // Portrait game position: move the game up so the touch controls cover less of it.
        let portrait = view.bounds.height > view.bounds.width
        let shift = portrait ? -CGFloat(prefs.portraitOffset) * view.bounds.height : 0
        if let webTop, webTop.constant != shift {
            webTop.constant = shift
            webBottom?.constant = shift
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { playOrientation.mask }

    // MARK: - Setup helpers

    private func configureAudio() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.silentModeAudio) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureGamepad() {
        let prefs = self.prefs
        gamepad.frame = view.bounds
        gamepad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gamepad.isHidden = !game.gamepad
        gamepad.setProfile(prefs.display(LayoutStore.load(for: game.id)))
        gamepad.onKey = { [weak self] key, down in self?.keyRouter.press(key, down) }
        gamepad.onAction = { [weak self] action, down in self?.handleAction(action, down) }
        let gameID = game.id
        gamepad.onSave = { profile in LayoutStore.save(prefs.stored(profile), for: gameID) }
        gamepad.onReset = {
            LayoutStore.reset(gameID)
            return prefs.display(LayoutStore.load(for: gameID))
        }
        gamepad.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            self.isEditingControls = editing
            self.controlBar.isHidden = editing
            if !editing { self.updateOverlays() }
        }
        view.addSubview(gamepad)
    }

    private func configureControllers() {
        let mode = UserDefaults.standard.string(forKey: SettingsKey.controllerMode)
        if prefs.physicalControllers && mode != "gamepadAPI" {
            let manager = PhysicalControllerManager(gameID: game.id)
            manager.onKey = { [weak self] key, down in self?.keyRouter.press(key, down) }
            manager.onAction = { [weak self] action, down in self?.handleAction(action, down) }
            manager.start()
            controllers = manager
        }
        controllerConnected = prefs.physicalControllers && !GCController.controllers().isEmpty
    }

    private func configureControlBar() {
        controlBar.frame = view.bounds
        controlBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controlBar.configure(prefs: prefs, showFastForward: game.engine.isRPGMaker && prefs.showFastForward)
        controlBar.menuProvider = { [weak self] in self?.buildMenuItems() ?? [] }
        controlBar.onItem = { [weak self] item in self?.barItem(item) }
        view.addSubview(controlBar)
        updateOverlays()
    }

    private func configureLabels() {
        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        statsLabel.layer.cornerRadius = 6
        statsLabel.clipsToBounds = true
        statsLabel.textAlignment = .center
        statsLabel.isHidden = true
        view.addSubview(statsLabel)

        banner.font = .systemFont(ofSize: 12, weight: .medium)
        banner.textColor = .white
        banner.backgroundColor = UIColor.systemRed.withAlphaComponent(0.88)
        banner.numberOfLines = 5
        banner.textAlignment = .center
        banner.layer.cornerRadius = 10
        banner.clipsToBounds = true
        banner.isHidden = true
        banner.isUserInteractionEnabled = true
        banner.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bannerTapped)))
        view.addSubview(banner)
    }

    private func configureKeySender() {
        keySender.onKey = { [weak self] key in self?.typeKey(key) }
        view.addSubview(keySender)
    }

    private var gameURL: URL? {
        let path = game.entry.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? game.entry
        return URL(string: "\(NexSchemeHandler.scheme)://\(game.host)/\(path)")
    }

    /// Applies the network block rule, then loads the game.
    private func prepareAndLoad() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            let content = webView.configuration.userContentController
            content.removeAllContentRuleLists()
            if game.blockNetwork {
                let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
                if let list = try? await WKContentRuleListStore.default()
                    .compileContentRuleList(forIdentifier: "nexplay-block", encodedContentRuleList: rules) {
                    content.add(list)
                }
            }
            if let url = gameURL {
                gameLog.add("--- loading \(url.absoluteString)")
                loadStart = Date()
                banner.isHidden = true
                webView.load(URLRequest(url: url))
            }
        }
    }

    private func update(_ change: @escaping (inout Game) -> Void) {
        change(&game)
        store.mutate(game.id, change)
    }

    // MARK: - Overlays

    /// On-screen controls and the control bar follow the game setting and connected controllers.
    private func updateOverlays() {
        guard !isEditingControls else { return }
        let hidePad = controllerConnected && prefs.hidePadWithController
        gamepad.isHidden = !game.gamepad || hidePad
        if gamepad.isHidden {
            gamepad.releaseAll()
        }
        controlBar.update(controllerConnected: controllerConnected)
        controlBar.setState(gamepadOn: game.gamepad, fastForwardOn: fastForwardOn)
    }

    @objc private func controllersChanged() {
        controllerConnected = prefs.physicalControllers && !GCController.controllers().isEmpty
        updateOverlays()
    }

    @objc private func screenTapped() {
        controlBar.wake()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touched = touch.view else { return true }
        if touched.isDescendant(of: controlBar) || touched.isDescendant(of: banner) { return false }
        // Pressing an on-screen control is playing, not asking for the bar.
        if touched !== gamepad && touched.isDescendant(of: gamepad) { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Problems on screen

    /// Every page message goes to the game log; script errors in the first 30 seconds also show a banner, so a black
    /// screen says why.
    private func noteLine(_ line: String) {
        gameLog.add(line)
        guard let start = loadStart, Date().timeIntervalSince(start) < 30 else { return }
        let lower = line.lowercased()
        if lower.hasPrefix("error:") || lower.hasPrefix("unhandled rejection") || lower.hasPrefix("failed to load") {
            showBanner("Game error: " + line)
        }
    }

    private func showBanner(_ text: String) {
        guard banner.isHidden else { return }
        banner.text = String(text.prefix(220)) + "\nTap to open the game log."
        banner.isHidden = false
        view.setNeedsLayout()
        bannerTimer?.invalidate()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.banner.isHidden = true }
        }
    }

    private func layoutBanner() {
        guard !banner.isHidden else { return }
        let insets = view.safeAreaInsets
        let width = min(view.bounds.width - insets.left - insets.right - 24, 560)
        let fit = banner.sizeThatFits(CGSize(width: width - 16, height: 200))
        banner.frame = CGRect(x: (view.bounds.width - width) / 2, y: insets.top + 8,
                              width: width, height: min(fit.height + 16, 140))
    }

    @objc private func bannerTapped() {
        banner.isHidden = true
        showLog()
    }

    // MARK: - Input

    /// App actions from on-screen controls and controller buttons.
    private func handleAction(_ action: ControlAction, _ down: Bool) {
        guard action == .fastForward, down, game.engine.isRPGMaker else { return }
        setSpeed(fastForwardOn ? 1 : max(2, game.fastForwardSpeed ?? 2))
    }

    private func barItem(_ item: ControlBarView.Item) {
        switch item {
        case .close:
            confirmExit()
        case .keyboard:
            toggleKeyboard()
        case .gamepad:
            toggleGamepad()
        case .settings:
            break
        case .screenshot:
            takeScreenshot()
        case .edit:
            editControls()
        case .fastForward:
            handleAction(.fastForward, true)
        }
    }

    private func toggleKeyboard() {
        if keySender.isFirstResponder {
            keySender.resignFirstResponder()
        } else {
            keySender.becomeFirstResponder()
        }
    }

    /// A typed key goes down, then up a moment later, so the game sees it in at least one frame.
    private func typeKey(_ key: PadKey) {
        keyRouter.press(key, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.keyRouter.press(key, false)
        }
    }

    private func editControls() {
        keySender.resignFirstResponder()
        gamepad.isHidden = false
        gamepad.beginEditing()
    }

    private func showControllerMap() {
        let view = ControllerMapView(gameID: game.id, gameName: game.name)
        let host = UIHostingController(rootView: view)
        presentOnTop(host)
    }

    private func takeScreenshot() {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { [weak self] image, error in
            guard let self else { return }
            guard let image else {
                self.showAlert("Screenshot failed", error?.localizedDescription ?? "No image.")
                return
            }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            self.gameLog.add("screenshot saved to Photos")
        }
    }

    // MARK: - Menu

    private func buildMenuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = []

        items.append(UIAction(title: "Restart Game", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.prepareAndLoad()
        })

        if game.engine.isRPGMaker {
            let speeds = [1, 2, 3, 4, 6, 9].map { n in
                UIAction(title: n == 1 ? "Normal Speed" : "\(n)× Speed", state: speed == n ? .on : .off) { [weak self] _ in
                    self?.setSpeed(n)
                }
            }
            items.append(UIMenu(title: "Fast Forward", image: UIImage(systemName: "forward.fill"), children: speeds))
        }

        let profilePrefs = prefs
        items.append(UIMenu(title: "Controls", image: UIImage(systemName: "gamecontroller"), children: [
            UIAction(title: "Show On-Screen Controls", state: game.gamepad ? .on : .off) { [weak self] _ in
                self?.toggleGamepad()
            },
            UIAction(title: "Edit Controls", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.editControls()
            },
            UIAction(title: "Type with Keyboard", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                self?.toggleKeyboard()
            },
            UIAction(title: "Use as Default Layout", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                guard let self else { return }
                LayoutStore.save(profilePrefs.stored(self.gamepad.profile), for: nil)
            },
            UIAction(title: "Use Default Layout", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                guard let self else { return }
                LayoutStore.reset(self.game.id)
                self.gamepad.setProfile(profilePrefs.display(LayoutStore.load(for: self.game.id)))
            },
            UIAction(title: "Controller Buttons…", image: UIImage(systemName: "gamecontroller.fill")) { [weak self] _ in
                self?.showControllerMap()
            },
        ]))

        let orientations = OrientationMode.allCases.map { mode in
            UIAction(title: mode.title, state: game.orientation == mode ? .on : .off) { [weak self] _ in
                self?.setOrientation(mode)
            }
        }
        items.append(UIMenu(title: "Orientation", image: UIImage(systemName: "rotate.right"), children: orientations))

        if game.usesNWMode {
            items.append(UIMenu(title: "Saves", image: UIImage(systemName: "externaldrive"), children: [
                UIAction(title: "Export Saves (ZIP)…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.exportSaveZip()
                },
                UIAction(title: "Import Saves (ZIP)…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    self?.pick(.zipRestore)
                },
            ]))
        } else {
            items.append(UIMenu(title: "Saves", image: UIImage(systemName: "externaldrive"), children: [
                UIAction(title: "Back Up Saves…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.backUp()
                },
                UIAction(title: "Restore Saves…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    self?.pick(.jsonRestore)
                },
            ]))
        }

        for feature in features {
            items.append(contentsOf: feature.menuItems(for: game))
        }

        items.append(UIAction(title: "Screenshot", image: UIImage(systemName: "camera")) { [weak self] _ in
            self?.takeScreenshot()
        })

        items.append(UIAction(title: "Stats Overlay", image: UIImage(systemName: "speedometer"),
                              state: (game.statsOverlay ?? false) ? .on : .off) { [weak self] _ in
            self?.toggleStats()
        })

        items.append(UIAction(title: "Block Internet", image: UIImage(systemName: "wifi.slash"),
                              state: game.blockNetwork ? .on : .off) { [weak self] _ in
            self?.toggleBlockNetwork()
        })

        items.append(UIAction(title: "Game Log", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
            self?.showLog()
        })

        items.append(UIAction(title: "Exit Game", image: UIImage(systemName: "xmark.circle"),
                              attributes: .destructive) { [weak self] _ in
            self?.exitGame()
        })
        return items
    }

    private func setSpeed(_ value: Int) {
        speed = value
        fastForwardOn = value > 1
        applySpeed()
        controlBar.setState(gamepadOn: game.gamepad, fastForwardOn: fastForwardOn)
    }

    private func applySpeed() {
        guard game.engine.isRPGMaker else { return }
        webView.evaluateJavaScript("window.__nex && window.__nex.setSpeed(\(speed))")
    }

    private func showLog() {
        let nav = UINavigationController(rootViewController: LogViewController(log: gameLog, gameName: game.name))
        presentOnTop(nav)
    }

    private func toggleGamepad() {
        update { $0.gamepad.toggle() }
        if !game.gamepad {
            gamepad.releaseAll()
            keyRouter.releaseAll()
        }
        updateOverlays()
    }

    private func setOrientation(_ mode: OrientationMode) {
        update { $0.orientation = mode }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        OrientationManager.lock(mode)
    }

    private func toggleStats() {
        update { $0.statsOverlay = !($0.statsOverlay ?? false) }
        applyStats()
    }

    private func applyStats() {
        let on = game.statsOverlay ?? false
        statsLabel.isHidden = !on
        webView.evaluateJavaScript("window.__nexStats && window.__nexStats(\(on))")
        statsTimer?.invalidate()
        statsTimer = nil
        if on {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refreshStats()
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStats() }
            }
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func refreshStats() {
        let level = UIDevice.current.batteryLevel
        let battery = level < 0 ? "--" : "\(Int(level * 100))%"
        statsLabel.text = "\(currentFPS) FPS · \(battery) · \(PlayerViewController.clockFormatter.string(from: Date()))"
    }

    private func toggleBlockNetwork() {
        update { $0.blockNetwork.toggle() }
        prepareAndLoad()
    }

    private func confirmExit() {
        let alert = UIAlertController(title: "Exit \(game.name)?", message: "Progress since your last save is lost.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.controlBar.wake() })
        alert.addAction(UIAlertAction(title: "Exit", style: .destructive) { [weak self] _ in self?.exitGame() })
        presentOnTop(alert)
    }

    private func exitGame() {
        shutdown()
        onExit()
    }

    // MARK: - Saves

    private func share(_ file: URL, onDone: (() -> Void)? = nil) {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = controlBar.anchor
        sheet.popoverPresentationController?.sourceRect = controlBar.anchor.bounds
        sheet.completionWithItemsHandler = { _, _, _, _ in onDone?() }
        presentOnTop(sheet)
    }

    private func backUp() {
        Task { @MainActor in
            do {
                let result = try await SaveTools.exportBackup(from: webView)
                let file = try SaveTools.writeBackupFile(result.data, gameName: game.name)
                let binary = result.binaryRecords
                share(file) { [weak self] in
                    if binary > 0 {
                        self?.showAlert("Partial backup",
                                        "\(binary) saved record(s) contain binary data that a backup file can't hold. They stay in the app.")
                    }
                }
            } catch {
                showAlert("Back up failed", error.localizedDescription)
            }
        }
    }

    private func exportSaveZip() {
        let target = game
        Task { @MainActor in
            do {
                let file = try await Task.detached(priority: .userInitiated) { try SaveArchive.exportZip(for: target) }.value
                share(file)
            } catch {
                showAlert("Export failed", error.localizedDescription)
            }
        }
    }

    private func pick(_ purpose: PickPurpose) {
        pickPurpose = purpose
        let types: [UTType] = purpose == .zipRestore ? [.zip] : [.json, .plainText]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        presentOnTop(picker)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        switch pickPurpose {
        case .zipRestore:
            confirmZipRestore(url)
        case .jsonRestore:
            restoreJSON(url)
        }
    }

    private func confirmZipRestore(_ url: URL) {
        let alert = UIAlertController(title: "Restore saves into \(game.name)?",
                                      message: "Current saves are backed up first, and every replaced file is kept as a .nex-displaced.bak copy.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in try? FileManager.default.removeItem(at: url) })
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            self?.restoreZip(url)
        })
        presentOnTop(alert)
    }

    private func restoreZip(_ url: URL) {
        let target = game
        Task { @MainActor in
            do {
                let count = try await Task.detached(priority: .userInitiated) { try SaveArchive.restore(zip: url, into: target) }.value
                try? FileManager.default.removeItem(at: url)
                showAlert("Saves restored", "Restored \(count) file(s). The game will restart.") { [weak self] in
                    self?.prepareAndLoad()
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                showAlert("Restore failed", error.localizedDescription)
            }
        }
    }

    private func restoreJSON(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            showAlert("Restore failed", "The file could not be read.")
            return
        }
        Task { @MainActor in
            do {
                let result = try await SaveTools.restore(text, into: webView)
                var message = "Restored \(result.restoredKeys) key(s) and \(result.restoredRecords) record(s)."
                if !result.skipped.isEmpty {
                    message += " Skipped: \(result.skipped.joined(separator: ", "))."
                }
                showAlert("Saves restored", message + " The game will restart.") { [weak self] in
                    self?.prepareAndLoad()
                }
            } catch {
                showAlert("Restore failed", error.localizedDescription)
            }
        }
    }

    /// Copies browser-mode saves into save/ files once per game, the first time it runs in NW.js mode.
    private func migrateSavesIfNeeded() {
        guard game.usesNWMode, game.savesMigrated != true, !migrationRunning else { return }
        migrationRunning = true
        let isMZ = game.engine == .rpgMZ
        let name = game.name
        Task { @MainActor in
            defer { migrationRunning = false }
            do {
                let result = try await SaveTools.migrateBrowserSaves(isMZ: isMZ, in: webView)
                for line in result.log {
                    gameLog.add("save migration: \(line)")
                    AppLog.log("save migration (\(name)): \(line)")
                }
                guard result.ok else { return }
                update { $0.savesMigrated = true }
                if !result.written.isEmpty {
                    gameLog.add("save migration copied \(result.written.count) save(s); restarting so the game sees them")
                    prepareAndLoad()
                }
            } catch {
                gameLog.add("save migration failed: \(error.localizedDescription)")
                AppLog.log("save migration (\(name)) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Alerts

    private func presentOnTop(_ controller: UIViewController) {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        top.present(controller, animated: true)
    }

    private func showAlert(_ title: String, _ message: String, onDone: (() -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in onDone?() })
        presentOnTop(alert)
    }

    // MARK: - Playtime and cleanup

    /// Pauses the game loop and its audio, then counts playtime.
    @objc private func appWillResign() {
        accumulate()
        keyRouter.releaseAll()
        webView?.evaluateJavaScript("window.__nex && window.__nex.pause()")
    }

    @objc private func appDidBecomeActive() {
        guard !isShutDown else { return }
        sessionStart = Date()
        webView?.evaluateJavaScript("window.__nex && window.__nex.resume()")
    }

    private func accumulate() {
        guard let start = sessionStart else { return }
        sessionStart = nil
        let seconds = Date().timeIntervalSince(start)
        update { $0.playSeconds += seconds; $0.lastPlayed = Date() }
    }

    /// Safe to call more than once.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        accumulate()
        AppLog.noteGame(nil)
        statsTimer?.invalidate()
        statsTimer = nil
        bannerTimer?.invalidate()
        bannerTimer = nil
        controlBar.stop()
        keySender.resignFirstResponder()
        loadTask?.cancel()
        gamepad.releaseAll()
        controllers?.stop()
        controllers = nil
        keyRouter.releaseAll()
        features.forEach { $0.shutdown() }
        NotificationCenter.default.removeObserver(self)
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationManager.unlock()
        let content = webView?.configuration.userContentController
        content?.removeScriptMessageHandler(forName: "nexStats")
        content?.removeScriptMessageHandler(forName: "nexLog")
        content?.removeScriptMessageHandler(forName: "nexExit")
        for name in featureHandlerNames { content?.removeScriptMessageHandler(forName: name) }
        featureHandlerNames = []
        webView?.stopLoading()
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applySpeed()
        applyStats()
        migrateSavesIfNeeded()
        features.forEach { $0.didFinishLoad() }
        checkStartPage()
    }

    /// A start page served as plain text means the file server answered with an error (missing file, no access):
    /// the page would be black text on black.
    private func checkStartPage() {
        let script = "document.contentType + '|' + (document.body ? document.body.innerText.slice(0, 120) : '')"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let text = result as? String, text.hasPrefix("text/plain") else { return }
            let body = text.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            self.gameLog.add("the start page could not be served: \(detail)")
            self.showBanner("The game's start page could not be opened (\(detail)). Delete the game and import it again.")
        }
        guard game.engine.isRPGMaker else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.isShutDown else { return }
            let probe = "(typeof SceneManager !== 'undefined' && SceneManager._scene) ? SceneManager._scene.constructor.name : 'no scene yet'"
            self.webView.evaluateJavaScript(probe) { [weak self] result, _ in
                if let name = result as? String { self?.gameLog.add("15 s after loading the game is at: \(name)") }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        gameLog.add("load failed: \(error.localizedDescription)")
        showAlert("Couldn't load the game", error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        gameLog.add("the web content process stopped (probably out of memory); reloading")
        AppLog.log("\(game.name): web content process stopped (probably out of memory); reloaded")
        webView.reload()
        if !didWarnAboutMemory {
            didWarnAboutMemory = true
            showAlert("The game was reloaded",
                      "iOS stopped the game, probably because it used too much memory. Unsaved progress since the last save is lost.")
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        gameLog.add("alert: \(message)")
        showAlert(game.name, message) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: game.name, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presentOnTop(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: game.name, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        presentOnTop(alert)
    }
}
