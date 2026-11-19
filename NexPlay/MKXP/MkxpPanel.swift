// 8.13.19: NexPlay's in-game menu for RPG Maker XP/VX/Ace games (the mkxp core). The same panel the web and
// Windows engines use (NexInGameMenu), opened by the round menu button over the game. Only compiled with NEXPLAY_MKXP.

#if NEXPLAY_MKXP
import SwiftUI

/// How the core stretches the game's picture to the screen (mkxp's `smoothScaling`). The game draws at its own small
/// size (LonaRPG 640x360), so this is the picture quality setting. Read when the game starts.
enum MkxpScaling: Int, CaseIterable {
    case sharp = 0, smooth = 1, bicubic = 2, pixelArt = 4

    static func key(_ id: UUID) -> String { "mkxpScaling.\(id.uuidString)" }

    static func current(for id: UUID) -> MkxpScaling {
        guard let raw = UserDefaults.standard.object(forKey: key(id)) as? Int, let value = MkxpScaling(rawValue: raw) else {
            return .smooth
        }
        return value
    }

    var title: String {
        switch self {
        case .sharp: return "Sharp"
        case .smooth: return "Smooth"
        case .bicubic: return "Smoother"
        case .pixelArt: return "Pixel art (xBRZ)"
        }
    }

    var detail: String {
        switch self {
        case .sharp: return "Hard pixels, fastest; uneven on a phone screen"
        case .smooth: return "Soft stretch like RPG Maker's own player"
        case .bicubic: return "Softer and a little sharper than Smooth"
        case .pixelArt: return "Redraws pixel art with clean edges; the heaviest"
        }
    }
}

struct MkxpPanel: View {
    let game: Game
    let canPause: Bool
    let onClose: () -> Void
    let onEsc: () -> Void
    let onReset: () -> Void
    let onSetPaused: (Bool) -> Void
    let onSetControlsHidden: (Bool) -> Void
    let onEditControls: () -> Void
    let onQuit: () -> Void

    @State private var tab = "game"
    @State private var question: NexMenuQuestion?
    @State private var controlsHidden: Bool
    @State private var gamePaused: Bool
    @State private var scaling: MkxpScaling

    init(game: Game, canPause: Bool, controlsHidden: Bool, paused: Bool, onClose: @escaping () -> Void,
         onEsc: @escaping () -> Void, onReset: @escaping () -> Void, onSetPaused: @escaping (Bool) -> Void,
         onSetControlsHidden: @escaping (Bool) -> Void, onEditControls: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.game = game
        self.canPause = canPause
        self.onClose = onClose
        self.onEsc = onEsc
        self.onReset = onReset
        self.onSetPaused = onSetPaused
        self.onSetControlsHidden = onSetControlsHidden
        self.onEditControls = onEditControls
        self.onQuit = onQuit
        _controlsHidden = State(initialValue: controlsHidden)
        _gamePaused = State(initialValue: paused)
        _scaling = State(initialValue: MkxpScaling.current(for: game.id))
    }

    private let tabs = [
        NexMenuTab(id: "game", title: "Game"),
        NexMenuTab(id: "picture", title: "Picture"),
        NexMenuTab(id: "controls", title: "Controls"),
    ]

    var body: some View {
        NexInGameMenu(eyebrow: game.engine.badge, title: game.name, symbol: game.engine.symbol,
                      tint: game.engine.accent, tabs: tabs, tab: $tab, question: $question, close: onClose) {
            switch tab {
            case "picture": pictureTab
            case "controls": controlsTab
            default: gameTab
            }
        }
    }

    @ViewBuilder private var gameTab: some View {
        Button {
            onClose()
        } label: {
            Label("Back to Game", systemImage: "play.fill")
        }
        .buttonStyle(NexPrimaryButtonStyle())
        NexMenuSection("Game") {
            NexMenuRow(title: "Game Menu (Esc)", detail: "Opens the game's own menu", symbol: "line.3.horizontal") {
                onEsc()
            }
            NexMenuRow(title: "Reset Game (F12)", detail: "Goes back to the game's title screen", symbol: "arrow.counterclockwise") {
                onReset()
            }
            if canPause {
                NexMenuToggleRow(title: "Pause Game", detail: "Keeps the game frozen after this menu closes",
                                 symbol: "pause.fill", isOn: gamePaused) { value in
                    gamePaused = value
                    onSetPaused(value)
                }
            }
        }
        NexMenuSection {
            NexMenuRow(title: "Quit NexPlay", detail: "The game can't be unloaded, so NexPlay closes.",
                       symbol: "power", destructive: true) {
                question = NexMenuQuestion(title: "Quit NexPlay?",
                                           message: "Progress you haven't saved in the game is lost.",
                                           answer: "Quit", destructive: true) { onQuit() }
            }
        }
    }

    @ViewBuilder private var pictureTab: some View {
        NexMenuSection("Picture quality") {
            ForEach(MkxpScaling.allCases, id: \.rawValue) { option in
                NexMenuRow(title: option.title, detail: option.detail, symbol: "sparkles.tv",
                           accessory: .check(scaling == option)) {
                    scaling = option
                    UserDefaults.standard.set(option.rawValue, forKey: MkxpScaling.key(game.id))
                }
            }
        }
        NexMenuSection {
            Text("Applies the next time the game starts: close NexPlay completely and open the game again.")
                .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var controlsTab: some View {
        NexMenuSection("Touch Controls") {
            NexMenuToggleRow(title: "Show Controls", symbol: "gamecontroller.fill", isOn: !controlsHidden) { value in
                controlsHidden = !value
                onSetControlsHidden(!value)
            }
            NexMenuRow(title: "Edit Touch Controls", detail: "Move and resize the buttons",
                       symbol: "slider.horizontal.below.square.and.square.filled", accessory: .chevron) {
                onEditControls()
            }
        }
    }
}
#endif
