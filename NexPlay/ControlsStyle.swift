import SwiftUI
import UIKit

// 8.2.0: Controls Style. Every game has one of two touch-control systems:
// - NexPlay Pad: NexPlay's overlay and layouts (GamepadOverlay.swift, ControlsLayout.swift).
// - PC Controls: BCD's touch controls and editor (NexPlay/Windows/BCD/BCDTouch*.swift), which only exist in builds with
//   the Windows engine. Web-view games reach them through `PCControls` (NexPlayPCControls.swift, engine builds only).
// `Game.controlsStyle` nil = Automatic: PC Controls for Windows games, desktop Godot and Flash; NexPlay Pad for the rest.

enum ControlsStyle: String, Codable, CaseIterable, Identifiable {
    case nexPad, pc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nexPad: return "NexPlay Pad"
        case .pc: return "PC Controls"
        }
    }

    var shortTitle: String {
        switch self {
        case .nexPad: return "NexPlay"
        case .pc: return "PC"
        }
    }

    var symbol: String {
        switch self {
        case .nexPad: return "gamecontroller.fill"
        case .pc: return "keyboard.fill"
        }
    }

    var detail: String {
        switch self {
        case .nexPad:
            return "NexPlay's pad and layouts. Best for RPG Maker, visual novels and HTML5 games."
        case .pc:
            return "Keys, mouse buttons and sticks you place anywhere, with their own editor and layouts. Best for Windows and mouse/keyboard games."
        }
    }

    /// What Automatic picks for this game.
    static func automatic(for game: Game) -> ControlsStyle {
        if isWindows(game) || game.isGodotDesktop || game.engine == .flash { return .pc }
        return .nexPad
    }

    /// The style the game plays with. PC Controls need the Windows engine build; without it web-view games use the pad.
    static func resolved(for game: Game) -> ControlsStyle {
        let style = game.controlsStyle ?? automatic(for: game)
        if style == .pc && !PCControls.available { return .nexPad }
        return style
    }

    static func isWindows(_ game: Game) -> Bool {
        game.runtime == .windows || game.engine == .windows
    }

    /// The line under a picker that says what Automatic means for this game.
    static func automaticNote(for game: Game) -> String {
        var note = "Automatic uses \(automatic(for: game).title) for this game."
        if !PCControls.available { note += " PC Controls need a build with the Windows engine; until then the NexPlay Pad is used." }
        return note
    }
}

// MARK: - PC Controls for web-view games

/// Where PC Controls send their input in a web-view game (the player).
@MainActor protocol PCControlsInput: AnyObject {
    func pcKey(_ key: PadKey, _ down: Bool)
    /// A mouse button at the cursor (Trackpad) or in the middle of the game (Direct Touch).
    func pcMouse(right: Bool, down: Bool)
    func pcToggleKeyboard()
}

/// BCD's touch controls over a web-view game: a view that takes touches only on its controls (everywhere while editing).
@MainActor protocol PCControlsLayer: AnyObject {
    var view: UIView { get }
    var isEditing: Bool { get }
    /// Called when the editor opens or closes.
    var onEditingChanged: ((Bool) -> Void)? { get set }
    func setEditing(_ on: Bool)
    func releaseAll()
}

enum PCControls {
    /// BCD's touch controls are compiled into this build.
    static var available: Bool {
        #if NEXPLAY_WINDOWS
        return true
        #else
        return false
        #endif
    }

    /// 8.2.1: a NexPlay layout preset as BCD's touch layout (shared by every game with PC Controls).
    @MainActor static func applyPreset(_ profile: LayoutProfile) {
        #if NEXPLAY_WINDOWS
        NexPCPresets.apply(profile)
        #endif
    }

    @MainActor static func makeLayer(input: PCControlsInput) -> PCControlsLayer? {
        #if NEXPLAY_WINDOWS
        return NexPCTouchLayer(input: input)
        #else
        return nil
        #endif
    }
}

// MARK: - Picker

/// The Controls Style choice for the Game Panel and the Windows panel: Automatic, NexPlay Pad or PC Controls.
struct ControlsStylePicker: View {
    let game: Game
    /// nil = Automatic.
    let choice: ControlsStyle?
    let onChoose: (ControlsStyle?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NexMetrics.spacingS) {
            HStack(spacing: NexMetrics.spacingS) {
                option(nil, title: "Auto", symbol: "wand.and.stars")
                ForEach(ControlsStyle.allCases) { style in
                    option(style, title: style.shortTitle, symbol: style.symbol)
                }
            }
            Text(choice?.detail ?? ControlsStyle.automaticNote(for: game))
                .font(NexType.caption)
                .foregroundStyle(NexColor.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ style: ControlsStyle?, title: String, symbol: String) -> some View {
        let selected = choice == style
        let disabled = style == .pc && !PCControls.available && !ControlsStyle.isWindows(game)
        return Button {
            NexHaptics.selection()
            NexMotion.run(NexMotion.snappy) { onChoose(style) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(NexType.captionStrong).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(selected ? NexColor.onAccent : NexColor.text)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NexColor.accent)
                }
            }
            .nexGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(style?.title ?? "Automatic")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
