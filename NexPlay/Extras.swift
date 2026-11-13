import SwiftUI
import UIKit

// 8.2.1: Extras for web-view games, with either Controls Style (NexPlay Pad or PC Controls): key bar, radial menu, turbo,
// gyro aim, aim zone, touch gestures, magnifier and Apple Pencil as a mouse. Ideas from BCD's round 603/604 extras
// (BCDExtraKeys, BCDRadial, BCDTurbo, BCDGyroAim, BCDGestureMap, BCDMagnifier, BCDPencil); NexPlay's own code, which works in
// every build. Windows games use BCD's own extras (its in-game menu). Per game, everything off until the player turns it on:
// Application Support/NexPlay/Extras/<game-uuid>.json. The running part is ExtrasLayer.swift.

// MARK: - What an extra does

struct ExtraAction: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case key, combo, mouseLeft, mouseRight, wheelUp, wheelDown, gamePanel, keyboard, keyBar, quickSave, quickLoad
    }

    var kind: Kind
    /// DOM key codes: one for `key`, held together in order for `combo` (Alt+Enter = [18, 13]).
    var keys: [Int] = []

    var id: String { kind.rawValue + keys.map(String.init).joined(separator: "+") }

    static func key(_ code: Int) -> ExtraAction { ExtraAction(kind: .key, keys: [code]) }
    static func combo(_ codes: [Int]) -> ExtraAction { ExtraAction(kind: .combo, keys: codes) }

    var title: String {
        switch kind {
        case .key, .combo: return keys.map(ExtraKeys.name).joined(separator: "+")
        case .mouseLeft: return "Left Click"
        case .mouseRight: return "Right Click"
        case .wheelUp: return "Wheel Up"
        case .wheelDown: return "Wheel Down"
        case .gamePanel: return "Game Panel"
        case .keyboard: return "Keyboard"
        case .keyBar: return "Key Bar"
        case .quickSave: return "Quick Save"
        case .quickLoad: return "Quick Load"
        }
    }

    /// Short words for a radial slot.
    var short: String {
        switch kind {
        case .key, .combo: return keys.map(ExtraKeys.name).joined(separator: "+")
        case .mouseLeft: return "LMB"
        case .mouseRight: return "RMB"
        case .wheelUp: return "▲"
        case .wheelDown: return "▼"
        case .gamePanel: return "Panel"
        case .keyboard: return "⌨︎"
        case .keyBar: return "Keys"
        case .quickSave: return "Save"
        case .quickLoad: return "Load"
        }
    }

    /// The choices the pickers offer.
    static let choices: [ExtraChoiceGroup] = [
        ExtraChoiceGroup(id: "Keys", actions: [.key(13), .key(27), .key(32), .key(9), .key(16), .key(17), .key(18), .key(90), .key(88),
                  .key(38), .key(40), .key(37), .key(39), .key(69), .key(81), .key(82), .key(70), .key(73), .key(77),
                  .key(49), .key(50), .key(51), .key(52)]),
        ExtraChoiceGroup(id: "F Keys", actions: (112...123).map { ExtraAction.key($0) }),
        ExtraChoiceGroup(id: "Combinations", actions: [.combo([18, 13]), .combo([17, 83]), .combo([17, 90]), .combo([18, 115])]),
        ExtraChoiceGroup(id: "Mouse", actions: [ExtraAction(kind: .mouseLeft), ExtraAction(kind: .mouseRight),
                                                 ExtraAction(kind: .wheelUp), ExtraAction(kind: .wheelDown)]),
        ExtraChoiceGroup(id: "NexPlay", actions: [ExtraAction(kind: .gamePanel), ExtraAction(kind: .keyboard),
                                                   ExtraAction(kind: .keyBar), ExtraAction(kind: .quickSave),
                                                   ExtraAction(kind: .quickLoad)]),
    ]
}

struct ExtraChoiceGroup: Identifiable {
    let id: String
    let actions: [ExtraAction]
}

enum ExtraKeys {
    static func name(_ code: Int) -> String {
        switch code {
        case 8: return "⌫"
        case 9: return "Tab"
        case 13: return "Enter"
        case 16: return "Shift"
        case 17: return "Ctrl"
        case 18: return "Alt"
        case 27: return "Esc"
        case 32: return "Space"
        case 33: return "PgUp"
        case 34: return "PgDn"
        case 35: return "End"
        case 36: return "Home"
        case 37: return "←"
        case 38: return "↑"
        case 39: return "→"
        case 40: return "↓"
        case 45: return "Ins"
        case 46: return "Del"
        case 112...123: return "F\(code - 111)"
        default:
            let key = PadKey.fromKeyCode(code).key
            return key.count == 1 ? key.uppercased() : key
        }
    }

    /// The key bar's row: Ctrl, Alt and Shift latch; the rest are pressed and let go.
    static let modifiers = [17, 18, 16]
    static let bar: [Int] = [27, 9, 13, 32, 8, 46, 45, 36, 35, 33, 34, 38, 40, 37, 39] + Array(112...123)
}

// MARK: - A game's extras

struct GameExtras: Codable, Equatable {
    enum Gesture: String, Codable, CaseIterable, Identifiable {
        case twoTap, threeTap, threeSwipeUp, threeSwipeDown, pinchIn, pinchOut
        var id: String { rawValue }
        var title: String {
            switch self {
            case .twoTap: return "Two-finger tap"
            case .threeTap: return "Three-finger tap"
            case .threeSwipeUp: return "Three-finger swipe up"
            case .threeSwipeDown: return "Three-finger swipe down"
            case .pinchIn: return "Pinch in"
            case .pinchOut: return "Pinch out"
            }
        }
    }

    var keyBar = false
    var radial = false
    var radialSlots: [ExtraAction] = [.key(27), .key(9), .key(13), .key(32), .combo([18, 13]), ExtraAction(kind: .mouseRight),
                                      ExtraAction(kind: .quickSave), ExtraAction(kind: .gamePanel)]
    /// Keys that repeat while held (DOM key codes); empty = turbo off.
    var turboKeys: [Int] = []
    /// Presses a second.
    var turboRate = 10
    var gyro = false
    /// Mouse points per degree turned.
    var gyroSpeed = 8.0
    var gyroInvertY = false
    var aimZone = false
    var aimSpeed = 1.6
    var gestures: [String: ExtraAction] = [:]
    /// 1 = off; 1.5, 2 or 3.
    var magnifier = 1.0
    var pencil = false

    var anyOn: Bool {
        keyBar || radial || !turboKeys.isEmpty || gyro || aimZone || !gestures.isEmpty || magnifier > 1 || pencil
    }

    func action(for gesture: Gesture) -> ExtraAction? { gestures[gesture.rawValue] }
}

enum ExtrasStore {
    static let folder: URL = {
        let dir = Paths.support.appendingPathComponent("Extras", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    static func load(_ id: UUID) -> GameExtras {
        guard let data = try? Data(contentsOf: url(id)),
              let extras = try? JSONDecoder().decode(GameExtras.self, from: data) else { return GameExtras() }
        return extras
    }

    static func save(_ extras: GameExtras, for id: UUID) {
        if extras == GameExtras() {
            try? FileManager.default.removeItem(at: url(id))
            return
        }
        guard let data = try? JSONEncoder().encode(extras) else { return }
        try? data.write(to: url(id), options: .atomic)
    }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}

// MARK: - Settings sheet

/// The game's extras (Game Panel > Extras, NexPlay Pad editor > Add > Extras, Game Settings > Controls).
struct ExtrasView: View {
    let gameName: String
    @State var extras: GameExtras
    let onChange: (GameExtras) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NexMetrics.spacingL) {
                    card("On Screen", symbol: "rectangle.on.rectangle") {
                        toggle("Key Bar", "Ctrl, Alt and Shift latch; Esc, Tab, F1–F12 and the navigation keys in one row.", $extras.keyBar)
                        toggle("Radial Menu", "A button at the screen's edge: hold it, slide to a slot, let go.", $extras.radial)
                        if extras.radial {
                            ForEach(extras.radialSlots.indices, id: \.self) { index in
                                actionMenu("Slot \(index + 1)", current: extras.radialSlots[index]) { picked in
                                    if let picked { extras.radialSlots[index] = picked }
                                }
                            }
                        }
                    }
                    card("Turbo", symbol: "bolt.horizontal.fill") {
                        Text("Held keys repeat, from the touch controls and the key bar.")
                            .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        FlowKeys(selected: $extras.turboKeys)
                        if !extras.turboKeys.isEmpty {
                            Stepper("\(extras.turboRate) presses a second", value: $extras.turboRate, in: 2...20)
                                .font(NexType.body)
                        }
                    }
                    card("Aiming", symbol: "scope") {
                        toggle("Gyro Aim", "Turning the phone moves the mouse (the cursor in Trackpad mode).", $extras.gyro)
                        if extras.gyro {
                            slider("Speed", value: $extras.gyroSpeed, range: 2...24)
                            Toggle("Invert Up and Down", isOn: $extras.gyroInvertY).font(NexType.body)
                        }
                        toggle("Aim Zone", "The right side of the screen is a trackpad: drag to move the mouse, tap to click.", $extras.aimZone)
                        if extras.aimZone { slider("Speed", value: $extras.aimSpeed, range: 0.6...4) }
                    }
                    card("Gestures", symbol: "hand.draw.fill") {
                        ForEach(GameExtras.Gesture.allCases) { gesture in
                            actionMenu(gesture.title, current: extras.action(for: gesture), allowsNone: true) {
                                extras.gestures[gesture.rawValue] = $0
                            }
                        }
                        Text("Gestures with two or more fingers still reach the game too.")
                            .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                    }
                    card("Seeing and Pointing", symbol: "plus.magnifyingglass") {
                        Picker("Magnifier", selection: $extras.magnifier) {
                            Text("Off").tag(1.0)
                            Text("1.5×").tag(1.5)
                            Text("2×").tag(2.0)
                            Text("3×").tag(3.0)
                        }
                        .pickerStyle(.segmented)
                        Text("Enlarges the game around a point you drag with the lens button. Taps still land on what you see.")
                            .font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        toggle("Apple Pencil as Mouse", "The tip moves and clicks, hovering moves, a double tap or squeeze is a right click (iPad).", $extras.pencil)
                    }
                    Button(role: .destructive) {
                        NexHaptics.warning()
                        extras = GameExtras()
                    } label: {
                        Label("Turn Everything Off", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(extras == GameExtras())
                }
                .padding(NexMetrics.spacingL)
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Extras")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SheetCloseButton { dismiss() } }
            }
        }
        .fontDesign(.rounded)
        .onChange(of: extras) { _, now in onChange(now) }
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NexMetrics.spacingM) {
            Label(title, systemImage: symbol).font(NexType.heading).foregroundStyle(NexColor.text)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nexCard()
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NexType.label).foregroundStyle(NexColor.text)
                Text(detail).font(NexType.caption).foregroundStyle(NexColor.textSoft)
            }
        }
        .tint(NexColor.accent)
        .onChange(of: value.wrappedValue) { _, _ in NexHaptics.selection() }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(NexType.body)
            Slider(value: value, in: range).tint(NexColor.accent)
        }
    }

    private func actionMenu(_ title: String, current: ExtraAction?, allowsNone: Bool = false,
                            set: @escaping (ExtraAction?) -> Void) -> some View {
        HStack {
            Text(title).font(NexType.body).foregroundStyle(NexColor.text)
            Spacer()
            Menu {
                if allowsNone { Button("Nothing") { set(nil) } }
                ForEach(ExtraAction.choices) { group in
                    Menu(group.id) {
                        ForEach(group.actions) { action in Button(action.title) { set(action) } }
                    }
                }
            } label: {
                Text(current?.title ?? "Nothing")
                    .font(NexType.captionStrong)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .nexGlassCapsule(interactive: true)
            }
        }
    }
}

/// Turbo key chips.
private struct FlowKeys: View {
    @Binding var selected: [Int]
    private let keys = [90, 88, 13, 32, 16, 17, 27, 38, 40, 37, 39, 87, 65, 83, 68, 69, 81, 70]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
            ForEach(keys, id: \.self) { code in
                let on = selected.contains(code)
                Button {
                    NexHaptics.selection()
                    if on { selected.removeAll { $0 == code } } else { selected.append(code) }
                } label: {
                    Text(ExtraKeys.name(code))
                        .font(NexType.captionStrong)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(on ? NexColor.onAccent : NexColor.text)
                        .background(on ? NexColor.accent : Color.clear, in: Capsule())
                        .nexGlassCapsule(interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
