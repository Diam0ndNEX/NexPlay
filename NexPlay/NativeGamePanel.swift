import SwiftUI
import UIKit

// 8.14.0: the in-game menu of the engines that draw outside the web view: the mkxp core (RPG Maker XP/VX/VX Ace) and
// EasyRPG (RPG Maker 2000/2003). The same panel (NexInGameMenu), the same tabs (Game, Display, Controls, Tools) and the
// same rows as the Game Panel of web games and the Windows panel. A row only shows when the engine can do it: the
// player passes the things it supports in `NativePanelSetup` and leaves the others nil.
// `NativePad` wires NexPlay's touch controls (GamepadOverlayView) for these players exactly like the web player does:
// edit, move, resize, change a button, presets, reset, controller buttons.

/// How the picture of a native engine is stretched to the screen. For mkxp it is the core's `smoothScaling`
/// (read when the core starts); EasyRPG uses Sharp or Smooth at once.
enum NativeScaling: Int, CaseIterable, Identifiable {
    case sharp = 0, smooth = 1, bicubic = 2, pixelArt = 4

    var id: Int { rawValue }

    static func key(_ id: UUID) -> String { "mkxpScaling.\(id.uuidString)" }

    static func current(for id: UUID, fallback: NativeScaling = .smooth) -> NativeScaling {
        guard let raw = UserDefaults.standard.object(forKey: key(id)) as? Int, let value = NativeScaling(rawValue: raw) else {
            return fallback
        }
        return value
    }

    static func set(_ value: NativeScaling, for id: UUID) {
        UserDefaults.standard.set(value.rawValue, forKey: key(id))
    }

    var title: String {
        switch self {
        case .sharp: return "Sharp"
        case .smooth: return "Smooth"
        case .bicubic: return "Smoother"
        case .pixelArt: return "Pixel Art"
        }
    }

    var detail: String {
        switch self {
        case .sharp: return "Hard pixels, the fastest; uneven at a phone's scale."
        case .smooth: return "A soft stretch, like RPG Maker's own player."
        case .bicubic: return "Softer edges, a little sharper than Smooth."
        case .pixelArt: return "Redraws pixel art with clean edges (xBRZ); the heaviest."
        }
    }
}

/// What a native player offers its panel. nil = the row is not shown.
struct NativePanelSetup {
    var game: Game
    var paused = false
    var speed = 1
    var speeds: [Int] = []
    var scaling: NativeScaling = .smooth
    var scalingChoices: [NativeScaling] = []
    /// True when a new picture setting applies at once; false = from the next start.
    var scalingLive = false
    var cheatsOn: Bool?
    var statsOn = false
    var controlsHidden = false
    var exitTitle = "Exit Game"
    var exitDetail = "Back to the library."
    var exitQuestion = "Progress you haven't saved in the game is lost."

    var close: () -> Void = {}
    var setPaused: ((Bool) -> Void)?
    var setSpeed: ((Int) -> Void)?
    var gameMenu: (() -> Void)?
    var restart: (() -> Void)?
    var setCheats: ((Bool) -> Void)?
    var openCheats: (() -> Void)?
    var screenshot: (() -> Void)?
    var setScaling: ((NativeScaling) -> Void)?
    var setStats: ((Bool) -> Void)?
    var setControlsHidden: (Bool) -> Void = { _ in }
    var editControls: () -> Void = {}
    var preset: (LayoutPreset) -> Void = { _ in }
    var resetControls: () -> Void = {}
    var type: ((String) -> Void)?
    var exit: () -> Void = {}
}

struct NativeGamePanel: View {
    let setup: NativePanelSetup

    @State private var tab = "game"
    @State private var question: NexMenuQuestion?
    @State private var paused: Bool
    @State private var speed: Int
    @State private var scaling: NativeScaling
    @State private var cheatsOn: Bool
    @State private var statsOn: Bool
    @State private var controlsHidden: Bool
    @State private var text = ""
    @State private var copied = false
    @State private var showControllerMap = false
    @State private var status: String?
    @State private var showTest = false
    @State private var showCopy = false

    init(setup: NativePanelSetup) {
        self.setup = setup
        _paused = State(initialValue: setup.paused)
        _speed = State(initialValue: setup.speed)
        _scaling = State(initialValue: setup.scaling)
        _cheatsOn = State(initialValue: setup.cheatsOn ?? false)
        _statsOn = State(initialValue: setup.statsOn)
        _controlsHidden = State(initialValue: setup.controlsHidden)
    }

    private let tabs = [
        NexMenuTab(id: "game", title: "Game"),
        NexMenuTab(id: "display", title: "Display"),
        NexMenuTab(id: "controls", title: "Controls"),
        NexMenuTab(id: "tools", title: "Tools"),
    ]

    var body: some View {
        NexInGameMenu(eyebrow: setup.game.engine.badge, title: setup.game.name, symbol: setup.game.engine.symbol,
                      tint: setup.game.engine.accent, tabs: tabs, tab: $tab, question: $question, status: status,
                      close: setup.close) {
            switch tab {
            case "display": displayTab
            case "controls": controlsTab
            case "tools": toolsTab
            default: gameTab
            }
        }
        .sheet(isPresented: $showControllerMap) {
            ControllerMapView(gameID: setup.game.id, gameName: setup.game.name)
        }
        .sheet(isPresented: $showTest) { ControlsTestView(game: setup.game) }
        .sheet(isPresented: $showCopy) { LayoutCopyView(source: setup.game) }
    }

    // MARK: Game

    @ViewBuilder private var gameTab: some View {
        Button {
            NexHaptics.press()
            setup.close()
        } label: {
            Label("Back to Game", systemImage: "play.fill")
        }
        .buttonStyle(NexPrimaryButtonStyle())
        if setup.setPaused != nil || setup.setSpeed != nil {
            NexMenuSection("Playback") {
                if let setPaused = setup.setPaused {
                    NexMenuToggleRow(title: "Pause Game", detail: "Stays paused after this menu closes",
                                     symbol: "pause.fill", isOn: paused) { value in
                        paused = value
                        setPaused(value)
                    }
                }
                if let setSpeed = setup.setSpeed, !setup.speeds.isEmpty {
                    NexMenuChipsRow(title: "Game Speed", symbol: "speedometer",
                                    choices: setup.speeds.map { NexMenuChoice(value: $0, title: "\($0)×") },
                                    selected: speed) { value in
                        speed = value
                        setSpeed(value)
                    }
                    NexMenuNote(text: "Fast forward. 1× is the normal speed.")
                }
            }
        }
        NexMenuSection("Game") {
            if let gameMenu = setup.gameMenu {
                NexMenuRow(title: "Game Menu", detail: "Opens the game's own menu (Esc)", symbol: "line.3.horizontal") {
                    gameMenu()
                }
            }
            if let restart = setup.restart {
                NexMenuRow(title: "Restart Game", detail: "Back to the title screen", symbol: "arrow.clockwise") {
                    question = NexMenuQuestion(title: "Restart the game?", message: setup.exitQuestion,
                                               answer: "Restart", destructive: true) { restart() }
                }
            }
            if let screenshot = setup.screenshot {
                NexMenuRow(title: "Screenshot", detail: "Saved to the game's gallery and Photos", symbol: "camera") {
                    screenshot()
                }
            }
        }
        if let setCheats = setup.setCheats {
            NexMenuSection("Cheats") {
                NexMenuToggleRow(title: "Cheat Menu", detail: "Money, items, levels and more, in the game's own style",
                                 symbol: "wand.and.stars", isOn: cheatsOn) { value in
                    cheatsOn = value
                    setCheats(value)
                }
                if cheatsOn, let openCheats = setup.openCheats {
                    NexMenuRow(title: "Open Cheat Menu", detail: "Opens on the map", symbol: "wand.and.stars.inverse",
                               accessory: .chevron) { openCheats() }
                }
            }
        }
        NexMenuSection {
            NexMenuRow(title: setup.exitTitle, detail: setup.exitDetail, symbol: "xmark.circle", destructive: true) {
                question = NexMenuQuestion(title: "\(setup.exitTitle)?", message: setup.exitQuestion,
                                           answer: setup.exitTitle, destructive: true) { setup.exit() }
            }
        }
    }

    // MARK: Display

    @ViewBuilder private var displayTab: some View {
        if let setScaling = setup.setScaling, !setup.scalingChoices.isEmpty {
            NexMenuSection("Picture") {
                NexMenuChipsRow(title: "Picture Quality", symbol: "sparkles.tv",
                                choices: setup.scalingChoices.map { NexMenuChoice(value: $0, title: $0.title) },
                                selected: scaling) { value in
                    scaling = value
                    setScaling(value)
                }
                NexMenuNote(text: scaling.detail)
                if !setup.scalingLive {
                    NexMenuNote(text: "Applies the next time the game starts: close NexPlay from the app switcher, then open the game again.",
                                symbol: "info.circle")
                }
            }
        }
        if let setStats = setup.setStats {
            NexMenuSection("Performance HUD") {
                NexMenuToggleRow(title: "Show Performance HUD", detail: "Frame rate, CPU, memory and temperature over the game",
                                 symbol: "gauge.with.dots.needle.67percent", isOn: statsOn) { value in
                    statsOn = value
                    setStats(value)
                }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controlsTab: some View {
        NexMenuSection("Touch Controls") {
            NexMenuToggleRow(title: "Show Controls", symbol: "gamecontroller.fill", isOn: !controlsHidden) { value in
                controlsHidden = !value
                setup.setControlsHidden(!value)
            }
            NexMenuRow(title: "Edit Touch Controls", detail: "Move, resize, add and change buttons",
                       symbol: "slider.horizontal.below.square.and.square.filled", accessory: .chevron) {
                setup.editControls()
            }
            NexMenuRow(title: "Reset Controls", detail: "The game's buttons go back to the default layout",
                       symbol: "arrow.counterclockwise") {
                question = NexMenuQuestion(title: "Reset the controls?", answer: "Reset", destructive: true) {
                    setup.resetControls()
                    status = "Controls reset"
                }
            }
        }
        NexMenuSection("Layouts") {
            NexMenuRow(title: "What Each Button Does", detail: "The key behind every on-screen button",
                       symbol: "list.bullet.rectangle", accessory: .chevron) { showTest = true }
            NexMenuRow(title: "Copy Layout to Other Games", detail: "Use this game's buttons in other games",
                       symbol: "square.on.square", accessory: .chevron) { showCopy = true }
        }
        NexMenuSection("Layout Preset") {
            ForEach(LayoutPreset.allCases) { preset in
                NexMenuRow(title: preset.title, symbol: preset.symbol) {
                    setup.preset(preset)
                    status = "\(preset.title) layout"
                }
            }
        }
        if let type = setup.type {
            NexMenuSection("Keyboard") {
                NexMenuCustomRow {
                    HStack(spacing: 10) {
                        TextField("Text for the game", text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.send)
                            .onSubmit { send(type) }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
                            .background(Capsule().fill(NexColor.surfaceRaised))
                        Button {
                            send(type)
                        } label: {
                            Image(systemName: "paperplane.fill")
                        }
                        .buttonStyle(NexGlassIconButtonStyle(size: 38))
                        .disabled(text.isEmpty)
                        .accessibilityLabel("Send")
                    }
                }
                NexMenuNote(text: "Typed into the game when it asks for text (a name, a password).")
            }
        }
        NexMenuSection("Controllers") {
            NexMenuRow(title: "Controller Buttons", detail: "What each button of a game controller presses",
                       symbol: "gamecontroller", accessory: .chevron) {
                showControllerMap = true
            }
            NexMenuNote(text: "Changes apply the next time the game starts.")
        }
    }

    private func send(_ type: (String) -> Void) {
        guard !text.isEmpty else { return }
        type(text)
        status = "Sent"
        text = ""
    }

    // MARK: Tools

    @ViewBuilder private var toolsTab: some View {
        NexMenuSection("Support") {
            NexMenuRow(title: "Report a Problem", detail: "Makes the logs ZIP and opens the share sheet",
                       symbol: "ladybug") {
                status = ProblemReport.share() ?? "Logs ready to share"
            }
        }
        NexMenuSection("NexPlay") {
            NexMenuRow(title: copied ? "Copied" : "Copy Log for Claude", detail: "The device report and the app log",
                       symbol: "doc.on.doc") {
                UIPasteboard.general.string = DeviceInfo.report() + "\n\n" + AppLog.shared.text
                copied = true
            }
            NexMenuCustomRow {
                Text(AppLog.shared.text.components(separatedBy: "\n").suffix(30).joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NexColor.textSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Touch controls for native players

@MainActor
enum NativePad {
    /// The top-most controller over `base`, to present on.
    static func top(_ base: UIViewController?) -> UIViewController? {
        var top = base
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    /// 8.14.2: RPG Maker and Ruby games only read the arrow keys, so a stick or D-pad set to W A S D (the keyboard
    /// presets) did nothing there. The directions go back to the arrows for those engines.
    static func arrowsOnly(_ profile: LayoutProfile, _ game: Game) -> LayoutProfile {
        guard game.engine.isRPGMaker || game.engine.isRuby else { return profile }
        func fix(_ items: [ControlItem]) -> [ControlItem] {
            items.map { item in
                var item = item
                if item.action.isDirectional { item.wasd = nil }
                return item
            }
        }
        var result = profile
        result.portrait = fix(profile.portrait)
        result.landscape = fix(profile.landscape)
        return result
    }

    /// Wires the overlay like the web player does: the layout (with the global size and opacity), saving, reset,
    /// presets and the Edit Button page. `presenter` gives the controller the pages are shown on.
    static func wire(_ pad: GamepadOverlayView, game: Game, presenter: @escaping () -> UIViewController?) {
        let prefs = ControlPrefs.current()
        let gameID = game.id
        let current = game
        pad.setProfile(prefs.display(arrowsOnly(LayoutStore.load(for: current), current)))
        pad.onSave = { profile in LayoutStore.save(prefs.stored(profile), for: gameID) }
        pad.onReset = {
            LayoutStore.reset(gameID)
            return prefs.display(arrowsOnly(LayoutStore.load(for: current), current))
        }
        pad.onPreset = { preset in prefs.display(arrowsOnly(preset.profile, current)) }
        pad.onEditItem = { item, done in
            let editor = ControlEditorView(item: item) { result in done(result) }
            let host = UIHostingController(rootView: editor)
            host.modalPresentationStyle = .formSheet
            top(presenter())?.present(host, animated: true)
        }
        pad.onConfirmReset = { reset in
            let alert = UIAlertController(title: "Reset Controls?", message: "This game's buttons go back to the default layout.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in reset() })
            top(presenter())?.present(alert, animated: true)
        }
    }

    /// Outside edit mode: the default layout again.
    static func resetLayout(_ pad: GamepadOverlayView, game: Game) {
        if pad.isEditing { pad.endEditing(save: false) }
        LayoutStore.reset(game.id)
        pad.setProfile(ControlPrefs.current().display(LayoutStore.load(for: game)))
    }

    /// Saves a screenshot to the game's gallery and to Photos.
    static func save(screenshot image: UIImage, for game: Game) {
        Gallery.add(image, for: game)
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        AppLog.log("screenshot saved for \(game.name)")
    }
}
