import UIKit
import SwiftUI
import WebKit

// Game Panel (6.1.0): one place for the in-game tools instead of nested menus. 8.3.0: shown in BCD's in-game menu
// layout (NexInGameMenu.swift). Game menu > Game Panel… (Quick Save
// and Quick Load stay right in the menu). It owns PlayAssistFeature and WebToolsFeature and forwards their scripts
// and lifecycle; they add no menu entries of their own.

final class GamePanelFeature: PlayerFeature {
    let assist: PlayAssistFeature
    let tools: WebToolsFeature
    let power: PowerFeature

    init(context: PlayerContext, assist: PlayAssistFeature, tools: WebToolsFeature, power: PowerFeature) {
        self.assist = assist
        self.tools = tools
        self.power = power
        super.init(context: context)
    }

    override func userScripts(for game: Game) -> [WKUserScript] {
        // The power script goes first: its frame limiter must wrap the browser's own requestAnimationFrame.
        power.userScripts(for: game) + tools.userScripts(for: game) + assist.userScripts(for: game)
    }

    override var messageNames: [String] { power.messageNames }

    override func receive(name: String, body: Any) {
        power.receive(name: name, body: body)
    }

    override func didFinishLoad() {
        power.didFinishLoad()
        tools.didFinishLoad()
        assist.didFinishLoad()
    }

    override func shutdown() {
        assist.shutdown()
        tools.shutdown()
        power.shutdown()
    }

    override func menuItems(for game: Game) -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: "Game Panel…", image: UIImage(systemName: "square.grid.2x2.fill")) { [weak self] _ in
                self?.openPanel()
            },
        ]
        if PlayAssist.supports(game) {
            let hasQuick = SaveStateStore.list(for: game.id).contains { $0.kind == .quick }
            items.append(UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: "Quick Save", image: UIImage(systemName: "bolt.circle")) { [weak self] _ in
                    self?.assist.quickSave()
                },
                UIAction(title: "Quick Load", image: UIImage(systemName: "bolt.horizontal.circle"),
                         attributes: hasQuick ? [] : [.disabled]) { [weak self] _ in
                    self?.assist.quickLoad()
                },
            ]))
        }
        return items
    }

    /// 8.3.0: a panel over the dimmed game (BCD's in-game menu layout), not a sheet.
    func openPanel() {
        let model = GamePanelModel(panel: self, game: context.game())
        let host = NexMenuHostingController(rootView: GamePanelView(model: model))
        model.onClose = { [weak host] in host?.presentingViewController?.dismiss(animated: true) }
        context.present(host)
    }
}

// MARK: - Model

@MainActor
final class GamePanelModel: ObservableObject {
    var game: Game
    @Published var options: AssistOptions
    @Published var speed: Double = 1
    @Published var paused = false
    @Published var hasQuick = false
    @Published var rewind: [RewindPoint] = []
    @Published var working = false
    @Published var status: String?
    @Published var shouldClose = false
    /// nil = the app default.
    @Published var powerChoice: PowerProfile?
    @Published var mouseMode: MouseMode = .direct
    /// 8.2.0: nil = Automatic.
    @Published var controlsStyle: ControlsStyle?
    /// 8.3.0: the Performance HUD of this game.
    @Published var statsOn = false
    /// Dismisses the panel (set by `openPanel`).
    var onClose: () -> Void = {}
    private weak var panel: GamePanelFeature?
    private var lastVolume: Double = 1
    private var closing = false

    init(panel: GamePanelFeature, game: Game) {
        self.game = game
        self.options = AssistOptions.load(for: game.id)
        self.panel = panel
        self.speed = panel.tools.speed
        self.paused = panel.tools.paused
        self.hasQuick = SaveStateStore.list(for: game.id).contains { $0.kind == .quick }
        self.powerChoice = panel.power.gameChoice
        self.mouseMode = panel.context.mouseMode()
        self.controlsStyle = panel.context.controlsStyle()
        self.statsOn = panel.context.statsShown()
    }

    func close() {
        guard !closing else { return }
        closing = true
        onClose()
    }

    func toggleStats() {
        panel?.context.toggleStats()
        statsOn = panel?.context.statsShown() ?? false
        say(statsOn ? "Performance HUD on" : "Performance HUD off")
    }

    // MARK: Controls Style (8.2.0)

    func setControlsStyle(_ style: ControlsStyle?) {
        controlsStyle = style
        panel?.context.setControlsStyle(style)
        game.controlsStyle = style
        say("Controls: \(ControlsStyle.resolved(for: game).title)")
    }

    /// Closes the panel, then opens the game's Extras sheet (8.2.1).
    func openExtras() {
        let context = panel?.context
        shouldClose = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context?.openExtras()
        }
    }

    /// Closes the panel, then opens the touch-control editor of the game's style.
    func editControls() {
        let context = panel?.context
        shouldClose = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context?.editControls()
        }
    }

    // MARK: Input (7.3.0)

    func setMouseMode(_ mode: MouseMode) {
        mouseMode = mode
        panel?.context.setMouseMode(mode)
        say("Mouse: \(mode.title)")
    }

    func applyPreset(_ preset: LayoutPreset) {
        guard let context = panel?.context else { return }
        context.applyPreset(preset)
        mouseMode = context.mouseMode()
        say("Layout: \(preset.title)")
    }

    /// Closes the panel, then opens the PC keyboard (it can't come up under a sheet).
    func showKeyboard() {
        let context = panel?.context
        shouldClose = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context?.showPCKeyboard()
        }
    }

    var powerProfile: PowerProfile { powerChoice ?? PowerProfile.appDefault }

    /// The next power profile (the Game Panel top row).
    func cyclePower() {
        let all = PowerProfile.allCases
        let index = all.firstIndex(of: powerProfile) ?? 0
        setPower(all[(index + 1) % all.count])
    }

    /// Closes the panel, then asks whether to leave the game.
    func exitGame() {
        let context = panel?.context
        shouldClose = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context?.exitGame()
        }
    }

    func setPower(_ choice: PowerProfile?) {
        powerChoice = choice
        panel?.power.choose(choice)
        let profile = choice ?? PowerProfile.appDefault
        say(choice == nil ? "App default: \(profile.title)" : profile.title)
    }

    var supportsStates: Bool { PlayAssist.supports(game) }
    var isRPG: Bool { game.engine.isRPGMaker }
    var isWeb: Bool { game.engine.isWebGame }

    func refresh() async {
        guard let panel else { return }
        options = AssistOptions.load(for: game.id)
        speed = panel.tools.speed
        paused = panel.tools.paused
        hasQuick = SaveStateStore.list(for: game.id).contains { $0.kind == .quick }
        if isRPG {
            rewind = await panel.assist.rewindPoints()
        } else {
            rewind = []
        }
    }

    /// A short line at the bottom of the panel.
    func say(_ text: String) {
        status = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self?.status == text { self?.status = nil }
        }
    }

    // MARK: States

    func quickSave() {
        guard let assist = panel?.assist else { return }
        Task { @MainActor in
            working = true
            let error = await assist.capture(kind: .quick)
            working = false
            if let error {
                say(error)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                hasQuick = true
                say("Quick saved")
            }
        }
    }

    func quickLoad() {
        guard let assist = panel?.assist else { return }
        guard let quick = SaveStateStore.list(for: game.id).first(where: { $0.kind == .quick }) else {
            say("No quick save yet")
            return
        }
        Task { @MainActor in
            working = true
            let error = await assist.load(quick)
            working = false
            if let error {
                say(error)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                shouldClose = true
            }
        }
    }

    func openStates() {
        panel?.assist.openStates()
    }

    func openLog() {
        panel?.assist.openLog()
    }

    func rewind(to point: RewindPoint) {
        guard let assist = panel?.assist else { return }
        Task { @MainActor in
            working = true
            let error = await assist.rewind(to: point)
            working = false
            if let error {
                say(error)
            } else {
                shouldClose = true
            }
        }
    }

    // MARK: Picture and screen (8.11.0)

    /// Saves a Picture option and applies it to the running game.
    func setPicture(_ edit: (inout AssistOptions) -> Void) {
        panel?.assist.change(edit)
        options = AssistOptions.load(for: game.id)
        panel?.context.applyPicture()
    }

    /// A slider being dragged: shown at once, saved with `commitPicture`.
    func previewPicture(x: Double? = nil, y: Double? = nil) {
        var preview = options
        if let x { preview.pictureX = x }
        if let y { preview.pictureY = y }
        options = preview
        panel?.context.previewPicture(preview)
    }

    func commitPicture() {
        let x = options.pictureX
        let y = options.pictureY
        setPicture { $0.pictureX = x; $0.pictureY = y }
    }

    func resetPicture() {
        setPicture {
            $0.pictureFit = ""; $0.pictureFull = false; $0.pictureZoom = 1
            $0.pictureX = 0; $0.pictureY = 0; $0.pictureSharp = false
        }
        say("Picture reset")
    }

    func setOrientation(_ mode: OrientationMode) {
        game.orientation = mode
        panel?.context.setOrientation(mode)
        say("Screen: \(mode.title)")
    }

    func restart() {
        let context = panel?.context
        shouldClose = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { context?.restartGame() }
    }

    func openLog() {
        let context = panel?.context
        shouldClose = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { context?.showGameLog() }
    }

    func screenshot() {
        let context = panel?.context
        shouldClose = true
        // The picture is taken once the panel is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { context?.screenshot() }
    }

    func setOption(_ edit: (inout AssistOptions) -> Void) {
        panel?.assist.change(edit)
        options = AssistOptions.load(for: game.id)
    }

    // MARK: Playback and sound

    func togglePause() {
        guard let tools = panel?.tools else { return }
        tools.setPaused(!paused, quiet: true)
        paused = tools.paused
        say(paused ? "Paused" : "Resumed")
    }

    func setSpeed(_ value: Double) {
        guard let tools = panel?.tools else { return }
        tools.setSpeed(value, quiet: true)
        speed = tools.speed
    }

    func previewVolume(_ value: Double) {
        options.volume = value
        panel?.tools.previewVolume(value)
    }

    func commitVolume() {
        panel?.tools.setVolume(options.volume, quiet: true)
    }

    func toggleMute() {
        if options.volume > 0 {
            lastVolume = options.volume
            previewVolume(0)
        } else {
            previewVolume(lastVolume > 0 ? lastVolume : 1)
        }
        commitVolume()
    }

    // MARK: Engines

    func twine(_ action: String) {
        guard let tools = panel?.tools else { return }
        Task { @MainActor in
            let text = await tools.runTwine(action)
            say(text == "ok" ? (action == "back" ? "Went back" : "Went forward") : text)
        }
    }

    func renpy(_ body: String, done: String) {
        guard let tools = panel?.tools else { return }
        Task { @MainActor in
            working = true
            let text = await tools.runRenPy(body, done: done)
            working = false
            say(text)
        }
    }
}

// MARK: - View

/// A titled glass card.
struct PanelCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.pixel(14, relativeTo: .subheadline, weight: .semibold))
                .foregroundStyle(NexStyle.accent)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(NexStyle.cardStroke))
    }
}

/// 8.3.0: the Game Panel in BCD's in-game menu layout (`NexInGameMenu`): a panel over the dimmed game with the tabs
/// Game, Display, Controls and Tools; sections appear by engine.
struct GamePanelView: View {
    @ObservedObject var model: GamePanelModel
    @State private var tab = "game"
    @State private var page: String?
    @State private var question: NexMenuQuestion?
    @AppStorage(SettingsKey.hudCorner) private var hudCorner = "topLeft"
    @AppStorage(SettingsKey.hudLayout) private var hudLayout = "tune"

    private let tabs = [
        NexMenuTab(id: "game", title: "Game"),
        NexMenuTab(id: "display", title: "Display"),
        NexMenuTab(id: "controls", title: "Controls"),
        NexMenuTab(id: "tools", title: "Tools"),
    ]

    var body: some View {
        NexInGameMenu(eyebrow: model.game.engine.badge, title: model.game.name, symbol: model.game.engine.symbol,
                      tint: model.game.engine.accent, tabs: tabs, tab: $tab,
                      pageTitle: page == "presets" ? "Layout Preset" : nil,
                      back: page == nil ? nil : { page = nil },
                      question: $question, status: model.status, working: model.working,
                      close: { model.close() }) {
            if page == "presets" {
                presetsPage
            } else {
                switch tab {
                case "display": displayTab
                case "controls": controlsTab
                case "tools": toolsTab
                default: gameTab
                }
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.shouldClose) { _, close in
            if close { model.close() }
        }
    }

    // MARK: Game

    @ViewBuilder private var gameTab: some View {
        Button {
            if model.paused { model.togglePause() }
            model.close()
        } label: {
            Label(model.paused ? "Resume Game" : "Back to Game", systemImage: "play.fill")
        }
        .buttonStyle(NexPrimaryButtonStyle())
        quickRow
        if model.supportsStates {
            NexMenuSection("Saves") {
                NexMenuRow(title: "Quick Save", symbol: "bolt.circle", enabled: !model.working) { model.quickSave() }
                NexMenuRow(title: "Quick Load", detail: model.hasQuick ? nil : "No quick save yet",
                           symbol: "bolt.horizontal.circle", enabled: model.hasQuick && !model.working) { model.quickLoad() }
                NexMenuRow(title: "Save States", detail: "Every state with its picture", symbol: "square.stack.3d.down.right",
                           accessory: .chevron) { model.openStates() }
                if model.isRPG {
                    NexMenuRow(title: "Message Log", symbol: "text.bubble", accessory: .chevron) { model.openLog() }
                }
            }
        }
        if model.isRPG && !model.rewind.isEmpty {
            NexMenuSection("Rewind") {
                NexMenuCustomRow {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.rewind) { point in
                                Button {
                                    NexHaptics.tap()
                                    question = NexMenuQuestion(title: "Rewind \(SaveStatesView.ago(point.ago))?",
                                                               message: "The game goes back to this moment. Rewind can undo it again.",
                                                               answer: "Rewind") { model.rewind(to: point) }
                                } label: {
                                    RewindChip(point: point)
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                        }
                    }
                }
                NexMenuNote(text: "A snapshot every 15 seconds on the map, for the last 5 minutes.")
            }
        }
        if model.isWeb {
            NexMenuSection("Playback") {
                NexMenuToggleRow(title: "Pause Game", symbol: "pause.fill", isOn: model.paused) { _ in model.togglePause() }
                NexMenuChipsRow(title: "Game Speed", symbol: "speedometer",
                                choices: [0.5, 1, 2, 3, 4].map { NexMenuChoice(value: $0, title: WebToolsFeature.speedText($0)) },
                                selected: model.speed) { model.setSpeed($0) }
                NexMenuNote(text: "Works for games that time themselves with the browser clock. Sound keeps its normal speed.")
            }
        }
        NexMenuSection("Sound") {
            NexMenuCustomRow {
                HStack(spacing: 12) {
                    Button {
                        NexHaptics.tap()
                        model.toggleMute()
                    } label: {
                        Image(systemName: model.options.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(NexGlassIconButtonStyle(size: 38))
                    .accessibilityLabel(model.options.volume == 0 ? "Unmute" : "Mute")
                    NexValueBar(value: model.options.volume, range: 0...1, step: 0.01,
                                set: { model.previewVolume($0) }, done: { model.commitVolume() })
                        .frame(height: 28)
                        .accessibilityLabel("Volume")
                    Text("\(Int((model.options.volume * 100).rounded()))%")
                        .font(NexType.number)
                        .foregroundStyle(NexColor.accentSoft)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            NexMenuNote(text: "Kept for this game.")
        }
        NexMenuSection("Game") {
            NexMenuRow(title: "Restart Game", detail: "Starts it again from the title", symbol: "arrow.clockwise") { model.restart() }
            NexMenuRow(title: "Game Log", detail: "What the game reported; copy it to send", symbol: "doc.text.magnifyingglass") { model.openLog() }
        }
        NexMenuSection("Capture") {
            NexMenuRow(title: "Screenshot", detail: "Saved to the game's gallery and Photos", symbol: "camera") { model.screenshot() }
        }
    }

    /// 7.7.0 (SPEC-7.0-review D5): the four most used actions as big buttons.
    private var quickRow: some View {
        HStack(spacing: 10) {
            QuickButton(title: "Save", symbol: "bolt.circle.fill", tint: .orange, enabled: model.supportsStates) {
                model.quickSave()
            }
            QuickButton(title: "Load", symbol: "bolt.horizontal.circle.fill", tint: .teal,
                        enabled: model.supportsStates && model.hasQuick) {
                model.quickLoad()
            }
            QuickButton(title: model.powerProfile.shortTitle, symbol: model.powerProfile.symbol, tint: .yellow, enabled: true) {
                model.cyclePower()
            }
            QuickButton(title: "Exit", symbol: "xmark.circle.fill", tint: NexColor.danger, enabled: true) {
                model.exitGame()
            }
        }
        .disabled(model.working)
    }

    // MARK: Display

    @ViewBuilder private var displayTab: some View {
        NexMenuSection("Power") {
            NexMenuChipsRow(title: "Power Profile", detail: model.powerChoice == nil
                                ? "Default is \(PowerProfile.appDefault.title) (Settings > Gameplay & Performance). \(model.powerProfile.detail)"
                                : model.powerProfile.detail,
                            symbol: model.powerProfile.symbol,
                            choices: [NexMenuChoice(value: "", title: "Default")]
                                + PowerProfile.allCases.map { NexMenuChoice(value: $0.rawValue, title: $0.shortTitle) },
                            selected: model.powerChoice?.rawValue ?? "") { model.setPower(PowerProfile(rawValue: $0)) }
        }
        NexMenuSection("Performance HUD") {
            NexMenuToggleRow(title: "Show Performance HUD", detail: "Frame rate, CPU, memory and temperature over the game",
                             symbol: "speedometer", isOn: model.statsOn) { _ in model.toggleStats() }
            NexMenuChipsRow(title: "Layout", detail: (HUDLayout(rawValue: hudLayout) ?? .tune).summary,
                            choices: HUDLayout.allCases.map { NexMenuChoice(value: $0.rawValue, title: $0.title) },
                            selected: hudLayout) { hudLayout = $0 }
            NexMenuChipsRow(title: "Place", choices: HUDPlace.allCases.map { NexMenuChoice(value: $0.rawValue, title: $0.title) },
                            selected: hudCorner) { hudCorner = $0 }
            NexMenuNote(text: "Layout and place apply to every game (Windows games use BCD's HUD in the same layout). CPU and memory are NexPlay's own process; the game's page runs in WebKit's process.")
        }
        pictureSection
    }

    /// 8.11.0: what Windows games have in BCD's menu (Picture: aspect and scaling, magnifier, filter, screen turn).
    @ViewBuilder private var pictureSection: some View {
        let moved = model.options.pictureZoom > 1 || !model.options.pictureFit.isEmpty
        NexMenuSection("Picture") {
            NexMenuChipsRow(title: "Screen Size", detail: Self.fitDetail(model.options.pictureFit), symbol: "aspectratio",
                            choices: [NexMenuChoice(value: "", title: "Game"), NexMenuChoice(value: "fit", title: "Fit"),
                                      NexMenuChoice(value: "fill", title: "Fill"), NexMenuChoice(value: "stretch", title: "Stretch")],
                            selected: model.options.pictureFit) { value in model.setPicture { $0.pictureFit = value } }
            NexMenuToggleRow(title: "Use the Whole Screen", detail: "Lets the game run under the notch and the home bar",
                             symbol: "rectangle.inset.filled", isOn: model.options.pictureFull) { value in
                model.setPicture { $0.pictureFull = value }
            }
            NexMenuChipsRow(title: "Magnifier", detail: "Enlarges the picture to read small text. Move it with the sliders.",
                            symbol: "plus.magnifyingglass",
                            choices: [1, 1.25, 1.5, 2, 3].map { NexMenuChoice(value: $0, title: $0 == 1 ? "Off" : String(format: "%g×", $0)) },
                            selected: model.options.pictureZoom) { value in model.setPicture { $0.pictureZoom = value } }
            if moved {
                NexMenuCustomRow {
                    pictureSlider("Left / Right", value: model.options.pictureX) { model.previewPicture(x: $0) }
                }
                NexMenuCustomRow {
                    pictureSlider("Up / Down", value: model.options.pictureY) { model.previewPicture(y: $0) }
                }
            }
            NexMenuChipsRow(title: "Picture Filter", detail: "Smooth blends the pixels when the game scales its picture up; Sharp keeps them square, best for pixel art.",
                            symbol: "square.grid.3x3",
                            choices: [NexMenuChoice(value: false, title: "Smooth"), NexMenuChoice(value: true, title: "Sharp")],
                            selected: model.options.pictureSharp) { value in model.setPicture { $0.pictureSharp = value } }
            NexMenuChipsRow(title: "Screen Turn", detail: "Whether the screen follows the way you hold the phone or stays in one orientation.",
                            symbol: "rotate.right",
                            choices: OrientationMode.allCases.map { NexMenuChoice(value: $0, title: $0.title) },
                            selected: model.game.orientation) { model.setOrientation($0) }
            NexMenuRow(title: "Reset Picture", symbol: "arrow.counterclockwise") { model.resetPicture() }
            NexMenuNote(text: "Kept for this game. Fit shows all of the picture, Fill covers the screen and crops the edges, Stretch fills it without keeping the shape. Touches still land where the picture is drawn.")
        }
    }

    private static func fitDetail(_ fit: String) -> String {
        switch fit {
        case "fit": return "The whole picture, as large as the screen allows."
        case "fill": return "The picture covers the screen; the edges may be cut off."
        case "stretch": return "The picture is pulled to the screen's shape."
        default: return "The game sizes itself."
        }
    }

    private func pictureSlider(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(NexType.caption)
                .foregroundStyle(NexColor.dark(.textSoft))
                .frame(width: 92, alignment: .leading)
            NexValueBar(value: value, range: -1...1, step: 0.02, set: set, done: { model.commitPicture() })
                .frame(height: 28)
                .accessibilityLabel(title)
        }
    }

    // MARK: Controls

    @ViewBuilder private var controlsTab: some View {
        NexMenuSection("Controls Style") {
            NexMenuCustomRow {
                ControlsStylePicker(game: model.game, choice: model.controlsStyle) { model.setControlsStyle($0) }
            }
        }
        NexMenuSection("Touch Controls") {
            NexMenuRow(title: "Edit Touch Controls", symbol: "slider.horizontal.below.square.and.square.filled",
                       accessory: .chevron) { model.editControls() }
            NexMenuRow(title: "Layout Preset", detail: "Replaces the touch layout of the game's Controls Style",
                       symbol: "square.on.square", accessory: .chevron) { page = "presets" }
            NexMenuRow(title: "Extras", detail: "Key bar, radial menu, turbo, gyro, aim zone, gestures, magnifier, Pencil",
                       symbol: "sparkles", accessory: .chevron) { model.openExtras() }
            NexMenuRow(title: "PC Keyboard", symbol: "keyboard") { model.showKeyboard() }
        }
        NexMenuSection("Mouse") {
            NexMenuChipsRow(title: "Mouse Mode", detail: model.mouseMode.detail, symbol: "cursorarrow",
                            choices: MouseMode.allCases.map { NexMenuChoice(value: $0, title: $0.shortTitle) },
                            selected: model.mouseMode) { model.setMouseMode($0) }
        }
    }

    @ViewBuilder private var presetsPage: some View {
        NexMenuSection {
            ForEach(LayoutPreset.allCases) { preset in
                NexMenuRow(title: preset.title, symbol: preset.symbol) {
                    model.applyPreset(preset)
                    page = nil
                }
            }
        }
        NexMenuNote(text: "Mouse presets turn Trackpad on. Extras work with both styles.")
    }

    // MARK: Tools

    @ViewBuilder private var toolsTab: some View {
        if model.isRPG {
            NexMenuSection("Messages") {
                NexMenuToggleRow(title: "Instant Text", symbol: "text.badge.checkmark", isOn: model.options.instantText) { value in
                    model.setOption { $0.instantText = value }
                }
                NexMenuChipsRow(title: "Auto-Advance", symbol: "text.alignleft",
                                choices: [0, 1.5, 3, 5].map { NexMenuChoice(value: $0, title: $0 == 0 ? "Off" : PlayAssistFeature.seconds($0)) },
                                selected: model.options.autoAdvance) { value in model.setOption { $0.autoAdvance = value } }
            }
        }
        if model.supportsStates {
            NexMenuSection("Safety Net") {
                NexMenuChipsRow(title: "Auto Save State", symbol: "clock.arrow.circlepath",
                                choices: [0, 5, 10, 15, 30].map { NexMenuChoice(value: $0, title: $0 == 0 ? "Off" : "\($0) min") },
                                selected: model.options.autoStateMinutes) { value in model.setOption { $0.autoStateMinutes = value } }
                if model.isRPG {
                    NexMenuToggleRow(title: "Record Rewind", symbol: "backward.fill", isOn: model.options.rewind) { value in
                        model.setOption { $0.rewind = value }
                    }
                }
                NexMenuNote(text: "Auto states are also made when you leave the app. The last 3 are kept.")
            }
        }
        if model.game.engine == .twine {
            NexMenuSection("Story") {
                NexMenuRow(title: "Back", symbol: "arrow.uturn.backward") { model.twine("back") }
                NexMenuRow(title: "Forward", symbol: "arrow.uturn.forward") { model.twine("forward") }
                NexMenuNote(text: "Moves through the story's own history (SugarCube).")
            }
        }
        if model.game.engine == .renpy {
            NexMenuSection("Ren'Py") {
                NexMenuRow(title: "Quick Save", detail: "Load screen, page Q", symbol: "bolt.circle") {
                    model.renpy("renpy.run(renpy.store.QuickSave())", done: "Quick saved (Load screen, page Q)")
                }
                renpyChips("Auto-Forward", [
                    ("On", "p = renpy.game.preferences\np.afm_enable = True\nif not p.afm_time:\n    p.afm_time = 15", "Auto-forward on"),
                    ("Off", "renpy.game.preferences.afm_enable = False", "Auto-forward off"),
                ])
                renpyChips("Text Speed", [
                    ("Instant", "renpy.game.preferences.text_cps = 0", "Text speed: instant"),
                    ("Fast", "renpy.game.preferences.text_cps = 120", "Text speed: fast"),
                    ("Normal", "renpy.game.preferences.text_cps = 40", "Text speed: normal"),
                    ("Slow", "renpy.game.preferences.text_cps = 20", "Text speed: slow"),
                ])
                renpyChips("Skip Unseen Text", [
                    ("On", "renpy.game.preferences.skip_unseen = True", "Skip skips unseen text too"),
                    ("Off", "renpy.game.preferences.skip_unseen = False", "Skip skips seen text only"),
                ])
                NexMenuNote(text: "These change Ren'Py's own preferences, which the game keeps.")
            }
        }
        NexMenuSection("Game") {
            NexMenuRow(title: "Exit Game", symbol: "xmark.circle", destructive: true) { model.exitGame() }
            NexMenuNote(text: "The game keeps running while this panel is open; Save States pauses it. Touch and hold the gear on the control bar for the full game menu.")
        }
    }

    /// Buttons that each run some Ren'Py Python (Ren'Py keeps the value; NexPlay can't read it back).
    private func renpyChips(_ title: String, _ items: [(String, String, String)]) -> some View {
        NexMenuChipsRow(title: title, choices: items.indices.map { NexMenuChoice(value: $0, title: items[$0].0) },
                        selected: nil) { index in model.renpy(items[index].1, done: items[index].2) }
    }
}

/// A rewind point: how long ago, and where.
struct RewindChip: View {
    let point: RewindPoint

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "clock.arrow.circlepath").font(.caption.weight(.bold)).foregroundStyle(NexStyle.accent)
            Text(SaveStatesView.ago(point.ago)).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text(point.map.isEmpty ? " " : point.map)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 84)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NexStyle.cardStroke))
    }
}


/// A big square button for the Game Panel's top row (8.3.0: glass, design-system type).
struct QuickButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            NexHaptics.press()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(NexType.captionStrong)
                    .foregroundStyle(NexColor.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .nexGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}
