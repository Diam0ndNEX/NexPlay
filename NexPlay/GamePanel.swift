import UIKit
import SwiftUI
import WebKit

// Game Panel (6.1.0): one sheet for the in-game tools instead of nested menus. Game menu > Game Panel… (Quick Save
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

    func openPanel() {
        let model = GamePanelModel(panel: self, game: context.game())
        let host = UIHostingController(rootView: GamePanelView(model: model))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        context.present(host)
    }
}

// MARK: - Model

@MainActor
final class GamePanelModel: ObservableObject {
    let game: Game
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
    private weak var panel: GamePanelFeature?
    private var lastVolume: Double = 1

    init(panel: GamePanelFeature, game: Game) {
        self.game = game
        self.options = AssistOptions.load(for: game.id)
        self.panel = panel
        self.speed = panel.tools.speed
        self.paused = panel.tools.paused
        self.hasQuick = SaveStateStore.list(for: game.id).contains { $0.kind == .quick }
        self.powerChoice = panel.power.gameChoice
        self.mouseMode = panel.context.mouseMode()
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

struct GamePanelView: View {
    @ObservedObject var model: GamePanelModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRewind: RewindPoint?

    private let tileColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    quickRow
                    if model.supportsStates { savesCard }
                    if model.isRPG && !model.rewind.isEmpty { rewindCard }
                    if model.isWeb { playbackCard }
                    soundCard
                    powerCard
                    inputCard
                    if model.isRPG { textCard }
                    if model.supportsStates { safetyCard }
                    if model.game.engine == .twine { storyCard }
                    if model.game.engine == .renpy { renpyCard }
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Game Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetHelpButton(title: "Game Panel", text: "Every in-game tool in one place. The top row saves, loads, switches the power profile and leaves the game. The game keeps running while the panel is open; Save States pauses it. Touch and hold the gear on the control bar for the full game menu.")
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetCloseButton { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let status = model.status {
                    Text(status)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(NexStyle.cardStroke))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.status)
        }
        .environment(\.colorScheme, .dark)
        .task { await model.refresh() }
        .onChange(of: model.shouldClose) { close in
            if close { dismiss() }
        }
        .confirmationDialog("Rewind?", isPresented: Binding(get: { pendingRewind != nil }, set: { if !$0 { pendingRewind = nil } }),
                            titleVisibility: .visible, presenting: pendingRewind) { point in
            Button("Rewind \(SaveStatesView.ago(point.ago))") { model.rewind(to: point) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The game goes back to this moment. Rewind can undo it again.")
        }
    }

    // MARK: Cards

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.game.engine.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(NexStyle.accentGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: NexStyle.accent.opacity(0.5), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.game.name)
                    .font(.pixel(18, relativeTo: .headline))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatChip(symbol: "cpu", text: model.game.engine.badge)
                    if model.paused { StatChip(symbol: "pause.fill", text: "Paused") }
                    if model.isWeb && model.speed != 1 { StatChip(symbol: "speedometer", text: WebToolsFeature.speedText(model.speed)) }
                    if model.options.volume == 0 { StatChip(symbol: "speaker.slash.fill", text: "Muted") }
                }
            }
            Spacer(minLength: 0)
            if model.working { ProgressView().tint(.white) }
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
            QuickButton(title: "Exit", symbol: "xmark.circle.fill", tint: .red, enabled: true) {
                model.exitGame()
            }
        }
        .disabled(model.working)
    }

    private var savesCard: some View {
        PanelCard("Saves", symbol: "square.stack.3d.down.right.fill") {
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ActionTile(title: "Quick Save", symbol: "bolt.circle.fill", tint: .orange) { model.quickSave() }
                ActionTile(title: "Quick Load", symbol: "bolt.horizontal.circle.fill", tint: .teal) { model.quickLoad() }
                    .disabled(!model.hasQuick)
                    .opacity(model.hasQuick ? 1 : 0.45)
                ActionTile(title: "Save States", symbol: "square.stack.3d.down.right.fill", tint: NexStyle.accent) { model.openStates() }
                if model.isRPG {
                    ActionTile(title: "Message Log", symbol: "text.bubble.fill", tint: .blue) { model.openLog() }
                }
            }
            .disabled(model.working)
        }
    }

    private var rewindCard: some View {
        PanelCard("Rewind", symbol: "backward.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.rewind) { point in
                        Button {
                            pendingRewind = point
                        } label: {
                            RewindChip(point: point)
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
            Text("A snapshot every 15 seconds on the map, for the last 5 minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var playbackCard: some View {
        PanelCard("Playback", symbol: "play.rectangle.fill") {
            Button {
                model.togglePause()
            } label: {
                Label(model.paused ? "Resume Game" : "Pause Game", systemImage: model.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(PlayButtonStyle())
            Text("Game Speed").font(.subheadline.weight(.semibold))
            Picker("Game Speed", selection: Binding(get: { model.speed }, set: { model.setSpeed($0) })) {
                ForEach([0.5, 1, 2, 3, 4], id: \.self) { (value: Double) in
                    Text(WebToolsFeature.speedText(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            Text("Works for games that time themselves with the browser clock. Sound keeps its normal speed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var powerCard: some View {
        PanelCard("Power", symbol: model.powerProfile.symbol) {
            Picker("Power", selection: Binding(get: { model.powerChoice?.rawValue ?? "" },
                                               set: { model.setPower(PowerProfile(rawValue: $0)) })) {
                Text("Default").tag("")
                ForEach(PowerProfile.allCases) { item in Text(item.shortTitle).tag(item.rawValue) }
            }
            .pickerStyle(.segmented)
            Text(model.powerChoice == nil ? "Default is \(PowerProfile.appDefault.title) (Settings > Gameplay & Performance). \(model.powerProfile.detail)" : model.powerProfile.detail)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var inputCard: some View {
        PanelCard("Input", symbol: "hand.point.up.left.fill") {
            Picker("Mouse", selection: Binding(get: { model.mouseMode }, set: { model.setMouseMode($0) })) {
                ForEach(MouseMode.allCases) { mode in Text(mode.shortTitle).tag(mode) }
            }
            .pickerStyle(.segmented)
            Text(model.mouseMode.detail)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Menu {
                    ForEach(LayoutPreset.allCases) { preset in
                        Button {
                            model.applyPreset(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.symbol)
                        }
                    }
                } label: {
                    Label("Layout Preset", systemImage: "square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    model.showKeyboard()
                } label: {
                    Label("PC Keyboard", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .tint(.white)
            Text("A preset replaces this game's touch layout. Edit it with the pencil on the control bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var soundCard: some View {
        PanelCard("Sound", symbol: "speaker.wave.2.fill") {
            HStack(spacing: 12) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.options.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(PressScaleStyle())
                Slider(value: Binding(get: { model.options.volume }, set: { model.previewVolume($0) }), in: 0...1,
                       onEditingChanged: { editing in
                           if !editing { model.commitVolume() }
                       })
                    .tint(NexStyle.accent)
                Text("\(Int((model.options.volume * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            Text("Kept for this game.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var textCard: some View {
        PanelCard("Messages", symbol: "text.alignleft") {
            Toggle(isOn: Binding(get: { model.options.instantText }, set: { value in model.setOption { $0.instantText = value } })) {
                Label("Instant Text", systemImage: "text.badge.checkmark")
            }
            .tint(NexStyle.accent)
            Text("Auto-Advance").font(.subheadline.weight(.semibold))
            Picker("Auto-Advance", selection: Binding(get: { model.options.autoAdvance }, set: { value in model.setOption { $0.autoAdvance = value } })) {
                ForEach([0, 1.5, 3, 5], id: \.self) { (value: Double) in
                    Text(value == 0 ? "Off" : PlayAssistFeature.seconds(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var safetyCard: some View {
        PanelCard("Safety Net", symbol: "lifepreserver.fill") {
            HStack {
                Label("Auto Save State", systemImage: "clock.arrow.circlepath")
                Spacer()
                Picker("Auto Save State", selection: Binding(get: { model.options.autoStateMinutes }, set: { value in model.setOption { $0.autoStateMinutes = value } })) {
                    ForEach([0, 5, 10, 15, 30], id: \.self) { (value: Int) in
                        Text(value == 0 ? "Off" : "Every \(value) min").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .tint(NexStyle.accent)
            }
            if model.isRPG {
                Toggle(isOn: Binding(get: { model.options.rewind }, set: { value in model.setOption { $0.rewind = value } })) {
                    Label("Record Rewind", systemImage: "backward.fill")
                }
                .tint(NexStyle.accent)
            }
            Text("Auto states are also made when you leave the app. The last 3 are kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var storyCard: some View {
        PanelCard("Story", symbol: "text.book.closed.fill") {
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ActionTile(title: "Back", symbol: "arrow.uturn.backward", tint: .pink) { model.twine("back") }
                ActionTile(title: "Forward", symbol: "arrow.uturn.forward", tint: .mint) { model.twine("forward") }
            }
            Text("Moves through the story's own history (SugarCube).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var renpyCard: some View {
        PanelCard("Ren'Py", symbol: "bubble.left.and.text.bubble.right.fill") {
            ActionTile(title: "Quick Save", symbol: "bolt.circle.fill", tint: .orange) {
                model.renpy("renpy.run(renpy.store.QuickSave())", done: "Quick saved (Load screen, page Q)")
            }
            optionRow("Auto-Forward", [
                ("On", "p = renpy.game.preferences\np.afm_enable = True\nif not p.afm_time:\n    p.afm_time = 15", "Auto-forward on"),
                ("Off", "renpy.game.preferences.afm_enable = False", "Auto-forward off"),
            ])
            optionRow("Text Speed", [
                ("Instant", "renpy.game.preferences.text_cps = 0", "Text speed: instant"),
                ("Fast", "renpy.game.preferences.text_cps = 120", "Text speed: fast"),
                ("Normal", "renpy.game.preferences.text_cps = 40", "Text speed: normal"),
                ("Slow", "renpy.game.preferences.text_cps = 20", "Text speed: slow"),
            ])
            optionRow("Skip Unseen Text", [
                ("On", "renpy.game.preferences.skip_unseen = True", "Skip skips unseen text too"),
                ("Off", "renpy.game.preferences.skip_unseen = False", "Skip skips seen text only"),
            ])
            Text("These change Ren'Py's own preferences, which the game keeps.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A label over a row of buttons that each run some Ren'Py Python.
    private func optionRow(_ title: String, _ items: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    Button {
                        model.renpy(item.1, done: item.2)
                    } label: {
                        Text(item.0)
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NexStyle.cardStroke))
                    }
                    .buttonStyle(PressScaleStyle())
                    .foregroundStyle(.white)
                }
            }
        }
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


/// A big square button for the Game Panel's top row.
struct QuickButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(NexStyle.cardStroke))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}
