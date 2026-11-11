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

final class PlayerViewController: GCEventViewController, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate {
    private enum PickPurpose {
        case jsonRestore
        case zipRestore
    }

    private var game: Game
    private let store: LibraryStore
    private let onExit: () -> Void

    private var webView: WKWebView!
    private let statsReceiver = StatsReceiver()
    private let logReceiver = LogReceiver()
    private let exitReceiver = MessageReceiver()
    private let gameLog = GameLog()
    private let gamepad = GamepadOverlayView()
    private let menuButton = UIButton(type: .custom)
    private let statsLabel = UILabel()

    private var speed = 1
    private var currentFPS = 0
    private var statsTimer: Timer?
    private var sessionStart: Date?
    private var didCountPlay = false
    private var didPlaceMenuButton = false
    private var isShutDown = false
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
        logReceiver.onLine = { [weak self] line in self?.gameLog.add(line) }
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
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])

        gamepad.frame = view.bounds
        gamepad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gamepad.isHidden = !game.gamepad
        gamepad.setProfile(LayoutStore.load(for: game.id))
        gamepad.onKey = { [weak self] key, down in self?.keyRouter.press(key, down) }
        gamepad.onAction = { [weak self] action, down in self?.handleAction(action, down) }
        let gameID = game.id
        gamepad.onSave = { profile in LayoutStore.save(profile, for: gameID) }
        gamepad.onReset = {
            LayoutStore.reset(gameID)
            return LayoutStore.load(for: gameID)
        }
        gamepad.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            self.menuButton.isHidden = editing
            if !editing { self.gamepad.isHidden = !self.game.gamepad }
        }
        view.addSubview(gamepad)

        if UserDefaults.standard.string(forKey: SettingsKey.controllerMode) != "gamepadAPI" {
            let manager = PhysicalControllerManager(gameID: game.id)
            manager.onKey = { [weak self] key, down in self?.keyRouter.press(key, down) }
            manager.onAction = { [weak self] action, down in self?.handleAction(action, down) }
            manager.start()
            controllers = manager
        }

        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        statsLabel.layer.cornerRadius = 6
        statsLabel.clipsToBounds = true
        statsLabel.textAlignment = .center
        statsLabel.isHidden = true
        view.addSubview(statsLabel)

        configureMenuButton()

        NotificationCenter.default.addObserver(self, selector: #selector(appWillResign),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)

        gameLog.add(game.usesNWMode ? "NW.js mode: saves are files in save/" : "browser mode: saves are in web storage")
        prepareAndLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationManager.lock(game.orientation)
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

        if !didPlaceMenuButton {
            didPlaceMenuButton = true
            menuButton.center = CGPoint(x: view.bounds.width - insets.right - 34, y: insets.top + 34)
        }
        keepMenuButtonInside()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { game.orientation.mask }

    // MARK: - Setup helpers

    private func configureAudio() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.silentModeAudio) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
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
                webView.load(URLRequest(url: url))
            }
        }
    }

    private func update(_ change: @escaping (inout Game) -> Void) {
        change(&game)
        store.mutate(game.id, change)
    }

    // MARK: - Input

    /// App actions from on-screen controls and controller buttons.
    private func handleAction(_ action: ControlAction, _ down: Bool) {
        guard action == .fastForward, down, game.engine.isRPGMaker else { return }
        fastForwardOn.toggle()
        setSpeed(fastForwardOn ? max(2, game.fastForwardSpeed ?? 2) : 1)
    }

    private func editControls() {
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

    private func configureMenuButton() {
        menuButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        menuButton.setImage(UIImage(systemName: "ellipsis.circle.fill"), for: .normal)
        menuButton.tintColor = .white
        menuButton.backgroundColor = UIColor(white: 0, alpha: 0.35)
        menuButton.layer.cornerRadius = 22
        menuButton.accessibilityLabel = "Game menu"
        let visible = UserDefaults.standard.bool(forKey: SettingsKey.showMenuButton)
        menuButton.alpha = visible ? 0.85 : 0.15
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.buildMenuItems() ?? [])
            },
        ])
        menuButton.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragMenuButton(_:))))
        view.addSubview(menuButton)
    }

    @objc private func dragMenuButton(_ gesture: UIPanGestureRecognizer) {
        let move = gesture.translation(in: view)
        menuButton.center = CGPoint(x: menuButton.center.x + move.x, y: menuButton.center.y + move.y)
        gesture.setTranslation(.zero, in: view)
        keepMenuButtonInside()
    }

    private func keepMenuButtonInside() {
        let half = menuButton.bounds.width / 2
        let x = min(max(menuButton.center.x, half), view.bounds.width - half)
        let y = min(max(menuButton.center.y, half), view.bounds.height - half)
        menuButton.center = CGPoint(x: x, y: y)
    }

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

        items.append(UIMenu(title: "Controls", image: UIImage(systemName: "gamecontroller"), children: [
            UIAction(title: "Show On-Screen Controls", state: game.gamepad ? .on : .off) { [weak self] _ in
                self?.toggleGamepad()
            },
            UIAction(title: "Edit Controls", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                self?.editControls()
            },
            UIAction(title: "Use as Default Layout", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                guard let self else { return }
                LayoutStore.save(self.gamepad.profile, for: nil)
            },
            UIAction(title: "Use Default Layout", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                guard let self else { return }
                LayoutStore.reset(self.game.id)
                self.gamepad.setProfile(LayoutStore.load(for: self.game.id))
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
        applySpeed()
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
        gamepad.isHidden = !game.gamepad
        if !game.gamepad {
            gamepad.releaseAll()
            keyRouter.releaseAll()
        }
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

    private func exitGame() {
        shutdown()
        onExit()
    }

    // MARK: - Saves

    private func share(_ file: URL, onDone: (() -> Void)? = nil) {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = menuButton
        sheet.popoverPresentationController?.sourceRect = menuButton.bounds
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
