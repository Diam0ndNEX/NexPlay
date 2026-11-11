import Foundation
import CoreGraphics

// The controls model (normalized positions, per-orientation layouts, at most 21 controls, "Automatic" resolution
// chain from game to default profile to built-in) follows the ideas of Empo's ControlsLayout.swift,
// LayoutProfilesManager.swift and docs/controls-format.md.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

/// A keyboard key a control or a controller button presses in the game.
struct PadKey: Codable, Hashable {
    let keyCode: Int
    let key: String
    let code: String

    static let left = PadKey(keyCode: 37, key: "ArrowLeft", code: "ArrowLeft")
    static let up = PadKey(keyCode: 38, key: "ArrowUp", code: "ArrowUp")
    static let right = PadKey(keyCode: 39, key: "ArrowRight", code: "ArrowRight")
    static let down = PadKey(keyCode: 40, key: "ArrowDown", code: "ArrowDown")
    static let confirm = PadKey(keyCode: 90, key: "z", code: "KeyZ")       // Z: OK
    static let cancel = PadKey(keyCode: 88, key: "x", code: "KeyX")        // X: Cancel
    static let dash = PadKey(keyCode: 16, key: "Shift", code: "ShiftLeft") // Shift: Dash (held)
    static let menu = PadKey(keyCode: 27, key: "Escape", code: "Escape")   // Esc: Menu
    static let pageUp = PadKey(keyCode: 33, key: "PageUp", code: "PageUp")
    static let pageDown = PadKey(keyCode: 34, key: "PageDown", code: "PageDown")
    static let enter = PadKey(keyCode: 13, key: "Enter", code: "Enter")
    static let space = PadKey(keyCode: 32, key: " ", code: "Space")
    static let backspace = PadKey(keyCode: 8, key: "Backspace", code: "Backspace")
    static let tab = PadKey(keyCode: 9, key: "Tab", code: "Tab")
    static let control = PadKey(keyCode: 17, key: "Control", code: "ControlLeft")
    static let alt = PadKey(keyCode: 18, key: "Alt", code: "AltLeft")
    static let home = PadKey(keyCode: 36, key: "Home", code: "Home")
    static let end = PadKey(keyCode: 35, key: "End", code: "End")
    static let insert = PadKey(keyCode: 45, key: "Insert", code: "Insert")
    static let delete = PadKey(keyCode: 46, key: "Delete", code: "Delete")

    /// Punctuation keys (US layout): DOM keyCode, key, code.
    static let symbols: [PadKey] = [
        PadKey(keyCode: 186, key: ";", code: "Semicolon"),
        PadKey(keyCode: 187, key: "=", code: "Equal"),
        PadKey(keyCode: 188, key: ",", code: "Comma"),
        PadKey(keyCode: 189, key: "-", code: "Minus"),
        PadKey(keyCode: 190, key: ".", code: "Period"),
        PadKey(keyCode: 191, key: "/", code: "Slash"),
        PadKey(keyCode: 192, key: "`", code: "Backquote"),
        PadKey(keyCode: 219, key: "[", code: "BracketLeft"),
        PadKey(keyCode: 220, key: "\\", code: "Backslash"),
        PadKey(keyCode: 221, key: "]", code: "BracketRight"),
        PadKey(keyCode: 222, key: "'", code: "Quote"),
    ]

    /// The key for a DOM keyCode: letters, digits, F1-F12, punctuation and the named keys above.
    static func fromKeyCode(_ keyCode: Int) -> PadKey {
        let named: [PadKey] = [.left, .up, .right, .down, .dash, .menu, .pageUp, .pageDown, .enter, .space,
                               .backspace, .tab, .control, .alt, .home, .end, .insert, .delete]
        if let found = named.first(where: { $0.keyCode == keyCode }) { return found }
        if let found = symbols.first(where: { $0.keyCode == keyCode }) { return found }
        if (65...90).contains(keyCode), let scalar = UnicodeScalar(keyCode) {
            let letter = String(Character(scalar))
            return PadKey(keyCode: keyCode, key: letter.lowercased(), code: "Key" + letter)
        }
        if (48...57).contains(keyCode) {
            let digit = String(keyCode - 48)
            return PadKey(keyCode: keyCode, key: digit, code: "Digit" + digit)
        }
        if (112...123).contains(keyCode) {
            let name = "F\(keyCode - 111)"
            return PadKey(keyCode: keyCode, key: name, code: name)
        }
        return PadKey(keyCode: keyCode, key: "Unidentified", code: "")
    }

    /// Keys offered when adding a key button or remapping a controller button.
    static let choosable: [PadKey] = {
        var keys: [PadKey] = [.enter, .space, .backspace, .tab, .control, .alt, .pageUp, .pageDown]
        keys += (65...90).map { PadKey.fromKeyCode($0) }
        keys += (48...57).map { PadKey.fromKeyCode($0) }
        keys += (112...123).map { PadKey.fromKeyCode($0) }
        keys += [.left, .up, .right, .down, .menu, .dash, .home, .end, .insert, .delete]
        keys += symbols
        return keys
    }()

    /// Key picker groups (the Select Key screen).
    static let letters: [PadKey] = (65...90).map { PadKey.fromKeyCode($0) }
    static let digits: [PadKey] = (48...57).map { PadKey.fromKeyCode($0) }
    static let navigation: [PadKey] = [.left, .up, .right, .down, .pageUp, .pageDown, .home, .end, .insert, .delete]
    static let controlKeys: [PadKey] = [.enter, .menu, .dash, .control, .alt, .tab, .space, .backspace]
    static let functionKeys: [PadKey] = (112...123).map { PadKey.fromKeyCode($0) }

    /// A short label for a key tile.
    var shortTitle: String {
        switch keyCode {
        case 37: return "←"
        case 38: return "↑"
        case 39: return "→"
        case 40: return "↓"
        case 33: return "PgUp"
        case 34: return "PgDn"
        case 36: return "Home"
        case 35: return "End"
        case 45: return "Ins"
        case 46: return "Del"
        case 8: return "Back"
        case 27: return "Esc"
        case 13: return "Enter"
        default: return title
        }
    }

    var title: String {
        switch keyCode {
        case 13: return "Enter"
        case 32: return "Space"
        case 8: return "Backspace"
        case 9: return "Tab"
        case 16: return "Shift"
        case 17: return "Ctrl"
        case 18: return "Alt"
        case 27: return "Esc"
        case 33: return "Page Up"
        case 34: return "Page Down"
        case 37: return "Left"
        case 38: return "Up"
        case 39: return "Right"
        case 40: return "Down"
        case 35: return "End"
        case 36: return "Home"
        case 45: return "Insert"
        case 46: return "Delete"
        default: return key.count == 1 ? key.uppercased() : key
        }
    }
}

/// What an on-screen control or a controller button does.
enum ControlAction: String, Codable, CaseIterable, Identifiable {
    case dpad, joystick, confirm, cancel, menu, dash, pageUp, pageDown, fastForward, key, none, scrollUp, scrollDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dpad: return "D-Pad"
        case .joystick: return "Joystick"
        case .confirm: return "OK (Z)"
        case .cancel: return "Cancel (X)"
        case .menu: return "Menu (Esc)"
        case .dash: return "Dash (Shift)"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .fastForward: return "Fast Forward"
        case .key: return "Key"
        case .none: return "Nothing"
        case .scrollUp: return "Scroll Up"
        case .scrollDown: return "Scroll Down"
        }
    }

    var defaultLabel: String {
        switch self {
        case .dpad, .joystick, .none: return ""
        case .confirm: return "A"
        case .cancel: return "B"
        case .menu: return "Menu"
        case .dash: return "Dash"
        case .pageUp: return "L"
        case .pageDown: return "R"
        case .fastForward: return "▶▶"
        case .key: return "Key"
        case .scrollUp: return "▲"
        case .scrollDown: return "▼"
        }
    }

    /// The key a button action presses (nil for directions, fast forward and nothing).
    var padKey: PadKey? {
        switch self {
        case .confirm: return .confirm
        case .cancel: return .cancel
        case .menu: return .menu
        case .dash: return .dash
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .dpad, .joystick, .fastForward, .key, .none, .scrollUp, .scrollDown: return nil
        }
    }

    var isDirectional: Bool { self == .dpad || self == .joystick }
}

/// One on-screen control. The center is normalized to the safe area (0...1); size is in points.
struct ControlItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var action: ControlAction
    /// For `.key`: the DOM keyCode the button presses.
    var keyCode: Int?
    var x: Double
    var y: Double
    var size: Double
    var opacity: Double
    var hidden: Bool
    var label: String?
    /// For the D-pad and joystick: eight directions (true) or four.
    var eightWay: Bool?
    /// Tint (ControlColor raw value); nil is the default dark glass.
    var color: String?

    init(action: ControlAction, keyCode: Int? = nil, x: Double, y: Double, size: Double,
         opacity: Double = 0.75, label: String? = nil) {
        self.action = action
        self.keyCode = keyCode
        self.x = x
        self.y = y
        self.size = size
        self.opacity = opacity
        self.hidden = false
        self.label = label
        self.eightWay = true
    }

    var displayLabel: String {
        if let label, !label.isEmpty { return label }
        if action == .key, let keyCode { return PadKey.fromKeyCode(keyCode).title }
        return action.defaultLabel
    }

    /// The key this control presses, for button controls.
    var padKey: PadKey? {
        if action == .key, let keyCode { return PadKey.fromKeyCode(keyCode) }
        return action.padKey
    }
}

/// Colours a control can take in edit mode.
enum ControlColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink

    var id: String { rawValue }

    /// Red, green, blue in 0...1.
    var rgb: (Double, Double, Double) {
        switch self {
        case .red: return (0.92, 0.33, 0.31)
        case .orange: return (0.95, 0.6, 0.27)
        case .yellow: return (0.97, 0.84, 0.3)
        case .green: return (0.4, 0.8, 0.42)
        case .mint: return (0.38, 0.83, 0.75)
        case .teal: return (0.36, 0.8, 0.86)
        case .cyan: return (0.42, 0.8, 0.98)
        case .blue: return (0.24, 0.55, 0.96)
        case .indigo: return (0.44, 0.47, 0.98)
        case .purple: return (0.75, 0.28, 0.9)
        case .pink: return (0.92, 0.3, 0.42)
        }
    }
}

/// A named set of controls: one layout for portrait, one for landscape.
struct LayoutProfile: Codable, Equatable {
    var name: String
    var portrait: [ControlItem]
    var landscape: [ControlItem]

    static let maxControls = 21

    func items(landscape isLandscape: Bool) -> [ControlItem] {
        isLandscape ? landscape : portrait
    }

    mutating func setItems(_ items: [ControlItem], landscape isLandscape: Bool) {
        if isLandscape { landscape = items } else { portrait = items }
    }

    /// The built-in layout for an engine: RPG Maker keys (Z/X/Esc/Shift) or the keys most web and Godot games use
    /// (Enter, Escape, Space, Shift).
    static func builtIn(for engine: GameEngine) -> LayoutProfile {
        if engine.isRPGMaker || engine.isRuby { return builtIn }
        return LayoutProfile(
            name: "Built-in",
            portrait: [
                ControlItem(action: .joystick, x: 0.25, y: 0.80, size: 150),
                ControlItem(action: .key, keyCode: 13, x: 0.86, y: 0.80, size: 62),
                ControlItem(action: .key, keyCode: 27, x: 0.70, y: 0.88, size: 58),
                ControlItem(action: .key, keyCode: 32, x: 0.70, y: 0.72, size: 54),
                ControlItem(action: .key, keyCode: 16, x: 0.86, y: 0.66, size: 54),
            ],
            landscape: [
                ControlItem(action: .joystick, x: 0.12, y: 0.74, size: 150),
                ControlItem(action: .key, keyCode: 27, x: 0.84, y: 0.66, size: 62),
                ControlItem(action: .key, keyCode: 13, x: 0.93, y: 0.66, size: 62),
                ControlItem(action: .key, keyCode: 32, x: 0.84, y: 0.86, size: 62),
                ControlItem(action: .key, keyCode: 16, x: 0.93, y: 0.86, size: 62),
            ]
        )
    }

    static let builtIn = LayoutProfile(
        name: "Built-in",
        portrait: [
            ControlItem(action: .dpad, x: 0.25, y: 0.80, size: 150),
            ControlItem(action: .confirm, x: 0.86, y: 0.80, size: 62),
            ControlItem(action: .cancel, x: 0.70, y: 0.88, size: 58),
            ControlItem(action: .dash, x: 0.70, y: 0.72, size: 54),
            ControlItem(action: .menu, x: 0.86, y: 0.66, size: 54),
        ],
        landscape: [
            ControlItem(action: .dpad, x: 0.13, y: 0.72, size: 150),
            ControlItem(action: .confirm, x: 0.92, y: 0.78, size: 62),
            ControlItem(action: .cancel, x: 0.84, y: 0.88, size: 58),
            ControlItem(action: .dash, x: 0.84, y: 0.64, size: 54),
            ControlItem(action: .menu, x: 0.92, y: 0.52, size: 54),
        ]
    )
}

/// Stores layouts as JSON in Application Support/NexPlay/Layouts: default.json and <game-uuid>.json.
/// "Automatic": a game's own layout, else the default profile, else the built-in one.
enum LayoutStore {
    static let folder: URL = {
        let dir = Paths.support.appendingPathComponent("Layouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(for gameID: UUID?) -> URL {
        folder.appendingPathComponent(gameID.map { "\($0.uuidString).json" } ?? "default.json")
    }

    private static func read(_ url: URL) -> LayoutProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LayoutProfile.self, from: data)
    }

    static func hasGameLayout(_ gameID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: gameID).path)
    }

    static func defaultProfile() -> LayoutProfile {
        read(url(for: nil)) ?? .builtIn
    }

    static func load(for gameID: UUID) -> LayoutProfile {
        read(url(for: gameID)) ?? defaultProfile()
    }

    /// The game's layout, else the default profile for RPG Maker games, else the engine's built-in layout.
    static func load(for game: Game) -> LayoutProfile {
        if let own = read(url(for: game.id)) { return own }
        if game.engine.isRPGMaker || game.engine.isRuby { return defaultProfile() }
        return .builtIn(for: game.engine)
    }

    /// Saves a game's layout, or the default profile when `gameID` is nil.
    static func save(_ profile: LayoutProfile, for gameID: UUID?) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: url(for: gameID), options: .atomic)
    }

    /// The game follows the default profile again.
    static func reset(_ gameID: UUID) {
        try? FileManager.default.removeItem(at: url(for: gameID))
    }

    static func resetDefault() {
        try? FileManager.default.removeItem(at: url(for: nil))
    }

    static func delete(for gameID: UUID) {
        reset(gameID)
    }
}
