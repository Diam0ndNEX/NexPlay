import SwiftUI
import UIKit

// 7.0.0: Windows games in NexPlay's library. A game's files stay in NexPlay's Games/<id> folder; a link to that folder
// sits on the Windows drive as C:\NexPlay\<id>. 8.0.0: BCD's engine is compiled into NexPlay (WindowsEngine.swift):
// the game becomes an entry of the engine's library (NexWindowsHost.addGame) and starts in-process with NexPlay's JIT,
// NexPlay's loading screen and BCD's session code (Wine, FEX, DXMT).
// BCD: https://github.com/thebcd69/bcd-games. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

enum WindowsGameFiles {
    /// Program names that are never the game: installers, redistributables, crash reporters, helpers.
    private static let skipped = ["unins", "uninstall", "setup", "install", "vcredist", "vc_redist", "dxsetup", "dxwebsetup",
                                  "directx", "dotnet", "netfx", "ndp4", "oalinst", "physx", "crashhandler", "crashreport",
                                  "crashpad", "unitycrashhandler", "ue4prereq", "ueprereq", "prereq", "notification_helper",
                                  "cefsharp", "cefprocess", "subprocess", "steamerrorreporter", "easyanticheat", "be_service",
                                  "dowser", "zsync", "7z", "winrar", "update", "patch"]

    /// The game's main program, relative to its folder: the shallowest .exe that isn't a helper, the biggest at that
    /// depth. Nil when the folder has no Windows program or holds a Java game.
    static func mainExecutable(in root: URL) -> String? {
        let fm = FileManager.default
        var level = [root]
        var best: [(size: Int, url: URL)] = []
        var hasJava = false
        for _ in 0...4 {
            var next: [URL] = []
            for dir in level {
                let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                        options: [.skipsHiddenFiles])) ?? []
                for kid in kids {
                    let values = try? kid.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory == true {
                        next.append(kid)
                        continue
                    }
                    let ext = kid.pathExtension.lowercased()
                    if ext == "jar" { hasJava = true }
                    guard ext == "exe" else { continue }
                    let name = kid.deletingPathExtension().lastPathComponent.lowercased()
                    if skipped.contains(where: { name.hasPrefix($0) || name.contains("crash") }) { continue }
                    best.append((values?.fileSize ?? 0, kid))
                }
            }
            if !best.isEmpty { break }
            level = next
        }
        if hasJava { return nil }
        guard let pick = best.max(by: { $0.size < $1.size }) else { return nil }
        return GameScanner.relativePath(of: pick.url, in: root)
    }

    /// Every .exe in the game's folder (four levels deep), relative to it, sorted.
    static func allExecutables(in root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            if walker.level > 5 { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "exe" { found.append(GameScanner.relativePath(of: url, in: root)) }
            if found.count >= 200 { break }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func detect(in root: URL) -> DetectedGame? {
        mainExecutable(in: root).map { DetectedGame(engine: .windows, entry: $0) }
    }

    /// The title from the program's name ("Hollow_Knight.exe" -> "Hollow Knight").
    static func title(for entry: String) -> String {
        let name = ((entry as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// The program a game starts: its chosen .exe, else its entry when that is an .exe, else a fresh look.
    static func program(for game: Game) -> String? {
        if let exe = game.exePath, !exe.isEmpty { return exe }
        if game.entry.lowercased().hasSuffix(".exe") { return game.entry }
        return mainExecutable(in: Paths.folder(for: game))
    }
}

/// The link from BCD's Windows drive to a NexPlay game folder.
enum WindowsLibraryLink {
    /// BCD's C: drive (Documents/wine/drive_c, as BCD's LibraryModel.drive).
    static var drive: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c", isDirectory: true)
    }

    /// True once BCD has set up its Windows drive (its first start in Windows Games).
    static var driveReady: Bool {
        FileManager.default.fileExists(atPath: drive.appendingPathComponent("windows", isDirectory: true).path)
    }

    static func linkURL(for game: Game) -> URL {
        drive.appendingPathComponent("NexPlay", isDirectory: true).appendingPathComponent(game.id.uuidString)
    }

    /// The program's path on BCD's drive ("NexPlay/<id>/Game/game.exe") and its Windows path.
    static func paths(for game: Game, program: String) -> (relative: String, windows: String) {
        let relative = "NexPlay/\(game.id.uuidString)/\(program)"
        return (relative, "C:\\" + relative.replacingOccurrences(of: "/", with: "\\"))
    }

    /// Makes (or repairs) C:\NexPlay\<id> pointing at the game's folder.
    static func make(for game: Game) throws {
        let fm = FileManager.default
        let link = linkURL(for: game)
        let target = Paths.folder(for: game)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == target.path { return }
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    static func remove(for game: Game) {
        let link = linkURL(for: game)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try? FileManager.default.removeItem(at: link)
        }
    }
}

/// The screen of a Windows game: NexPlay's loading screen over BCD's session screen (a child view controller). The
/// loading screen stays until the session runs, shows errors, and the controller returns to the library when the
/// session ends.
@MainActor
final class WindowsLaunchController: UIViewController {
    private let game: Game
    private let store: LibraryStore
    private let onExit: () -> Void
    private var loading: LoadingScreenView!
    private var started = false
    private var finished = false
    private var playStart: Date?
    private let hud = PerformanceHUDView()
    private var hudTimer: Timer?
    private var panelButton: UIButton?
    /// 8.2.0: the NexPlay Pad over the game when its Controls Style is NexPlay Pad (BCD's touch controls are hidden then).
    private let pad = GamepadOverlayView()
    private var padReady = false
    private var padDone: UIButton?
    #if NEXPLAY_WINDOWS
    private var session: NexWindowsSession?
    #endif

    init(game: Game, store: LibraryStore, onExit: @escaping () -> Void) {
        self.game = game
        self.store = store
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { nil }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // 7.10.0: the shared loading screen; 8.0.0: it covers BCD's session screen until the game runs.
        loading = LoadingScreenView(gameName: game.name, art: CoverCache.cached(for: game))
        loading.frame = view.bounds
        loading.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        loading.onCancel = { [weak self] in self?.leave() }
        loading.setStage("Starting Windows…")
        view.addSubview(loading)
        hud.isHidden = true
        view.addSubview(hud)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hud.place(in: view.bounds, insets: view.safeAreaInsets)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        OrientationManager.lock(.auto)
        // 7.12.0: the JIT sheet first when JIT is off (Settings > JIT & Performance > JIT for Games). Without it the
        // engine asks NexPlay's JIT itself when the game starts.
        let wantsJIT = UserDefaults.standard.object(forKey: SettingsKey.jitAutoForGames) as? Bool ?? true
        if WindowsEngine.unavailableReason == nil && wantsJIT && !JITManager.shared.isActive
            && JITHelperHost.unavailableReason == nil {
            loading.setStage("Waiting for JIT…")
            let sheet = JITSheetView(gameName: game.name) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.start()
                } else {
                    self.leave()
                }
            }
            let host = UIHostingController(rootView: sheet)
            host.modalPresentationStyle = .formSheet
            present(host, animated: true)
        } else {
            start()
        }
    }

    // MARK: - Start and end

    private func start() {
        AppLog.noteGame(game.name)
        if let reason = WindowsEngine.unavailableReason {
            fail(reason, retry: false)
            return
        }
        guard let program = WindowsGameFiles.program(for: game) else {
            fail("No Windows program (.exe) was found in this game's folder.", retry: false)
            return
        }
        #if NEXPLAY_WINDOWS
        do {
            try WindowsLibraryLink.make(for: game)
        } catch {
            fail("NexPlay couldn't link the game onto the Windows drive: \(error.localizedDescription)", retry: true)
            return
        }
        let paths = WindowsLibraryLink.paths(for: game, program: program)
        let arguments = game.runOptions.map { $0.argumentList.joined(separator: " ") }
        guard NexWindowsHost.addGame(relativePath: paths.relative, title: game.name, arguments: arguments) else {
            fail("The Windows engine couldn't add this game to its library.", retry: true)
            return
        }
        if game.windowsInfo == nil, let info = WindowsPE.inspect(program: program, in: Paths.folder(for: game)) {
            store.mutate(game.id) { $0.windowsInfo = info }
        }
        let current = session ?? makeSession()
        loading.setStage("Loading game…")
        current.play(windowsPath: paths.windows)
        #else
        fail(WindowsEngine.unavailableReason ?? "This build has no Windows engine.", retry: false)
        #endif
    }

    #if NEXPLAY_WINDOWS
    private func makeSession() -> NexWindowsSession {
        let made = NexWindowsSession { [weak self] event in
            self?.handle(event)
        }
        session = made
        let child = made.controller
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(child.view, at: 0)
        child.didMove(toParent: self)
        return made
    }

    private func handle(_ event: NexWindowsSession.Event) {
        switch event {
        case .stage(let text):
            loading.setStage(text)
        case .started:
            playStart = Date()
            AppLog.log("windows: \(game.name): session running")
            UIView.animate(withDuration: 0.35, animations: { self.loading.alpha = 0 }, completion: { _ in
                self.loading.isHidden = true
            })
            applyControlsStyle()
            addPanelButton()
            view.bringSubviewToFront(hud)
        case .ended:
            AppLog.log("windows: \(game.name): session ended")
            finish()
        case .failed(let message):
            fail(message, retry: true)
        }
    }

    // MARK: Controls Style (8.2.0)

    private var currentGame: Game { store.game(id: game.id) ?? game }

    /// NexPlay Pad: NexPlay's overlay sends keys and mouse buttons into Wine; PC Controls: BCD's own touch controls.
    private func applyControlsStyle() {
        let style = ControlsStyle.resolved(for: currentGame)
        NexWindowsPadInput.applyStyle(style)
        AppLog.log("windows: \(game.name): controls style \(style.title)")
        if style == .nexPad {
            if !padReady { configurePad() }
            pad.isHidden = !currentGame.gamepad
        } else {
            if pad.isEditing { pad.endEditing(save: false) }
            pad.releaseAll()
            NexWindowsPadInput.releaseAll()
            pad.isHidden = true
        }
        if let panelButton { view.bringSubviewToFront(panelButton) }
    }

    private func configurePad() {
        padReady = true
        let prefs = ControlPrefs.current()
        let gameID = game.id
        let current = game
        pad.frame = view.bounds
        pad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pad.setProfile(prefs.display(LayoutStore.load(for: game)))
        pad.onKey = { key, down in NexWindowsPadInput.key(key, down) }
        pad.onAction = { [weak self] action, down in self?.padAction(action, down) }
        pad.onSave = { profile in LayoutStore.save(prefs.stored(profile), for: gameID) }
        pad.onReset = {
            LayoutStore.reset(gameID)
            return prefs.display(LayoutStore.load(for: current))
        }
        pad.onPreset = { preset in prefs.display(preset.profile) }
        pad.onEditItem = { [weak self] item, done in
            let editor = ControlEditorView(item: item) { result in done(result) }
            let host = UIHostingController(rootView: editor)
            host.modalPresentationStyle = .formSheet
            self?.present(host, animated: true)
        }
        pad.onConfirmReset = { [weak self] reset in
            let alert = UIAlertController(title: "Reset Controls?", message: "This game's buttons go back to the default layout.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in reset() })
            self?.present(alert, animated: true)
        }
        pad.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            self.panelButton?.isHidden = editing
            self.showPadDone(editing)
            if !editing { self.pad.isHidden = !self.currentGame.gamepad }
        }
        view.addSubview(pad)
    }

    /// App actions from the NexPlay Pad over a Windows game.
    private func padAction(_ action: ControlAction, _ down: Bool) {
        switch action {
        case .mouseLeft, .mouseRight:
            NexWindowsPadInput.mouse(right: action == .mouseRight, down: down)
        case .showKeyboard:
            if down { NexWindowsPadInput.toggleKeyboard() }
        case .gamePanel:
            if down { openPanel() }
        default:
            break
        }
    }

    /// Done over the pad's edit mode (the web player uses its control bar's pencil for this).
    private func showPadDone(_ on: Bool) {
        if !on {
            padDone?.removeFromSuperview()
            padDone = nil
            return
        }
        guard padDone == nil else { return }
        var config = UIButton.Configuration.filled()
        config.title = "Done"
        config.image = UIImage(systemName: "checkmark")
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(NexColor.accent)
        config.baseForegroundColor = UIColor(NexColor.onAccent)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            NexHaptics.success()
            self?.pad.endEditing(save: true)
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
        ])
        padDone = button
    }

    private func setControlsStyle(_ style: ControlsStyle?) {
        store.mutate(game.id) { $0.controlsStyle = style }
        applyControlsStyle()
    }

    /// 8.2.1: a layout preset for the game's style: the NexPlay Pad's layout, or BCD's touch layout.
    private func applyPreset(_ preset: LayoutPreset) {
        if ControlsStyle.resolved(for: currentGame) == .nexPad {
            if !padReady { configurePad() }
            if pad.isEditing { pad.endEditing(save: false) }
            pad.applyPreset(preset)
            if !currentGame.gamepad { store.mutate(game.id) { $0.gamepad = true } }
            pad.isHidden = false
        } else {
            PCControls.applyPreset(preset.profile)
        }
        AppLog.log("windows: \(game.name): preset \(preset.title)")
    }

    private func editControls() {
        if ControlsStyle.resolved(for: currentGame) == .nexPad {
            if !padReady { configurePad() }
            pad.isHidden = false
            pad.beginEditing()
        } else {
            NexWindowsPadInput.editPCControls()
        }
    }
    #endif

    /// The ⋯ button over the game: NexPlay's Windows panel (HUD, log, quit). BCD's own in-game menu stays as it is.
    private func addPanelButton() {
        guard panelButton == nil else { return }
        var more = UIButton.Configuration.filled()
        more.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        more.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        more.baseForegroundColor = .white
        more.cornerStyle = .capsule
        let button = UIButton(configuration: more, primaryAction: UIAction { [weak self] _ in self?.openPanel() })
        button.accessibilityLabel = "Windows panel"
        button.alpha = 0.6
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        panelButton = button
    }

    private func openPanel() {
        var panel = WindowsPanelView(
            gameName: game.name,
            hudOn: !hud.isHidden,
            onToggleHUD: { [weak self] in self?.toggleHUD() },
            onRestart: nil,
            onExit: { [weak self] in self?.quitGame() }
        )
        #if NEXPLAY_WINDOWS
        panel.controls = WindowsPanelView.Controls(
            game: currentGame,
            onStyle: { [weak self] style in self?.setControlsStyle(style) },
            onEdit: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.editControls() }
            },
            onPreset: { [weak self] preset in self?.applyPreset(preset) }
        )
        #endif
        let host = UIHostingController(rootView: panel)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    private func toggleHUD() {
        hud.isHidden.toggle()
        hudTimer?.invalidate()
        hudTimer = nil
        guard !hud.isHidden else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        hud.update(fps: nil)
        view.bringSubviewToFront(hud)
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hud.update(fps: nil) }
        }
    }

    /// Quit Game in the Windows panel: the engine ends the session, then `.ended` returns to the library.
    private func quitGame() {
        #if NEXPLAY_WINDOWS
        if let session, session.isRunning {
            session.quit()
            return
        }
        #endif
        leave()
    }

    /// Back to the library before a session runs (Cancel, an error card, the JIT sheet's Not Now).
    private func leave() {
        #if NEXPLAY_WINDOWS
        if let session, session.isRunning {
            session.quit()
            return
        }
        #endif
        finish()
    }

    /// The session ended (or never started): count the time and go back to the library.
    private func finish() {
        guard !finished else { return }
        finished = true
        hudTimer?.invalidate()
        hudTimer = nil
        #if NEXPLAY_WINDOWS
        session?.stopWatching()
        #endif
        if let start = playStart {
            let seconds = Date().timeIntervalSince(start)
            playStart = nil
            store.mutate(game.id) {
                $0.playSeconds += seconds
                $0.lastPlayed = Date()
                $0.playCount += 1
                if seconds >= 120 { $0.lastGoodRuntime = .windows }
            }
        }
        #if NEXPLAY_WINDOWS
        pad.releaseAll()
        NexWindowsPadInput.releaseAll()
        #endif
        AppLog.noteGame(nil)
        OrientationManager.unlock()
        onExit()
    }

    private func fail(_ message: String, retry: Bool) {
        AppLog.log("windows: \(game.name): \(message)")
        loading.isHidden = false
        loading.alpha = 1
        view.bringSubviewToFront(loading)
        let lines = AppLog.shared.text.split(separator: "\n").filter { $0.contains("windows") || $0.contains("jit:") }.suffix(40)
        loading.setLog(lines.map(String.init))
        var actions: [LoadingAction] = []
        if retry {
            actions.append(LoadingAction("Try Again", symbol: "arrow.clockwise", primary: true) { [weak self] in
                guard let self else { return }
                self.loading.resetToLoading("Starting Windows…")
                self.start()
            })
        }
        actions.append(LoadingAction("Copy Log for Claude", symbol: "doc.on.doc") {
            UIPasteboard.general.string = DeviceInfo.report() + "\n\n" + lines.joined(separator: "\n")
        })
        actions.append(LoadingAction("Back to Library", symbol: "chevron.backward", primary: !retry) { [weak self] in
            self?.leave()
        })
        loading.showError(what: message, why: nil, actions: actions)
    }
}
