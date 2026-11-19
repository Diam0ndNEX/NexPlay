// 8.13.19: NexPlay's in-game menu for RPG Maker XP/VX/Ace games (the mkxp core). The same panel the web and
// Windows engines use (NexInGameMenu), opened by the round menu button over the game. Only compiled with NEXPLAY_MKXP.

#if NEXPLAY_MKXP
import SwiftUI

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
    }

    private let tabs = [
        NexMenuTab(id: "game", title: "Game"),
        NexMenuTab(id: "controls", title: "Controls"),
    ]

    var body: some View {
        NexInGameMenu(eyebrow: game.engine.badge, title: game.name, symbol: game.engine.symbol,
                      tint: game.engine.accent, tabs: tabs, tab: $tab, question: $question, close: onClose) {
            switch tab {
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
