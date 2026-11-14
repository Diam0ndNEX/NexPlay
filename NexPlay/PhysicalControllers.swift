import UIKit
import SwiftUI
import GameController

// Default button map, global/per-game scope and controller buttons that trigger app actions follow the ideas of
// Empo's ControllerInputManager.swift, BindingStore.swift and BindingsView.swift.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

/// Buttons of a physical controller that can be remapped. Directions (D-pad, left stick) always send arrows.
enum ControllerButton: String, CaseIterable, Codable, Identifiable {
    case a, b, x, y, l1, r1, l2, r2, l3, r3, menu, options

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l1: return "L1 / LB"
        case .r1: return "R1 / RB"
        case .l2: return "L2 / LT"
        case .r2: return "R2 / RT"
        case .l3: return "Left Stick Press"
        case .r3: return "Right Stick Press"
        case .menu: return "Menu / Start"
        case .options: return "Options / Select"
        }
    }
}

/// What a controller button does: one of the app actions, or a keyboard key.
struct ControllerBinding: Codable, Equatable {
    var action: ControlAction
    var keyCode: Int?

    static let nothing = ControllerBinding(action: .none, keyCode: nil)

    var title: String {
        if action == .key, let keyCode { return "Key " + PadKey.fromKeyCode(keyCode).title }
        return action.title
    }

    var padKey: PadKey? {
        if action == .key, let keyCode { return PadKey.fromKeyCode(keyCode) }
        return action.padKey
    }
}

/// Button maps, stored as JSON in UserDefaults: one for all games and optional ones per game.
enum ControllerMapStore {
    static let defaults: [ControllerButton: ControllerBinding] = [
        .a: ControllerBinding(action: .confirm),
        .b: ControllerBinding(action: .cancel),
        .x: ControllerBinding(action: .menu),
        .y: ControllerBinding(action: .dash),
        .l1: ControllerBinding(action: .pageUp),
        .r1: ControllerBinding(action: .pageDown),
        .l2: .nothing,
        .r2: ControllerBinding(action: .fastForward),
        .l3: .nothing,
        .r3: .nothing,
        .menu: ControllerBinding(action: .menu),
        .options: .nothing,
    ]

    private static func key(for gameID: UUID?) -> String {
        gameID.map { "controllerMap.\($0.uuidString)" } ?? "controllerMap"
    }

    static func stored(for gameID: UUID?) -> [ControllerButton: ControllerBinding]? {
        guard let data = UserDefaults.standard.data(forKey: key(for: gameID)),
              let raw = try? JSONDecoder().decode([String: ControllerBinding].self, from: data)
        else { return nil }
        var map: [ControllerButton: ControllerBinding] = [:]
        for (name, binding) in raw {
            if let button = ControllerButton(rawValue: name) { map[button] = binding }
        }
        return map
    }

    /// Game map, else the map for all games, else the defaults (button by button).
    static func effective(for gameID: UUID?) -> [ControllerButton: ControllerBinding] {
        var map = defaults
        if let global = stored(for: nil) { map.merge(global) { _, new in new } }
        if let gameID, let game = stored(for: gameID) { map.merge(game) { _, new in new } }
        return map
    }

    static func save(_ map: [ControllerButton: ControllerBinding], for gameID: UUID?) {
        var raw: [String: ControllerBinding] = [:]
        for (button, binding) in map { raw[button.rawValue] = binding }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key(for: gameID))
        }
    }

    static func reset(for gameID: UUID?) {
        UserDefaults.standard.removeObject(forKey: key(for: gameID))
    }
}

/// Reads physical controllers (GCController) and turns them into key presses and app actions.
/// Directions from the D-pad and the left stick become arrow keys (eight sectors with a dead zone).
/// The Gamepad API is left alone, so games that read it still see the controller.
@MainActor
final class PhysicalControllerManager {
    var onKey: ((PadKey, Bool) -> Void)?
    var onAction: ((ControlAction, Bool) -> Void)?

    private var map: [ControllerButton: ControllerBinding]
    private var directionsHeld: Set<Int> = []
    private var stickHeld: Set<Int> = []
    private var observers: [NSObjectProtocol] = []

    init(gameID: UUID?) {
        map = ControllerMapStore.effective(for: gameID)
    }

    func reloadMap(gameID: UUID?) {
        map = ControllerMapStore.effective(for: gameID)
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.attach(controller) }
        })
        GCController.controllers().forEach { attach($0) }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.microGamepad?.valueChangedHandler = nil
        }
        releaseDirections()
    }

    private func attach(_ controller: GCController) {
        if let pad = controller.extendedGamepad {
            bind(pad.buttonA, .a, controller)
            bind(pad.buttonB, .b, controller)
            bind(pad.buttonX, .x, controller)
            bind(pad.buttonY, .y, controller)
            bind(pad.leftShoulder, .l1, controller)
            bind(pad.rightShoulder, .r1, controller)
            bind(pad.leftTrigger, .l2, controller)
            bind(pad.rightTrigger, .r2, controller)
            bind(pad.buttonMenu, .menu, controller)
            if let options = pad.buttonOptions { bind(options, .options, controller) }
            if let l3 = pad.leftThumbstickButton { bind(l3, .l3, controller) }
            if let r3 = pad.rightThumbstickButton { bind(r3, .r3, controller) }
            pad.dpad.valueChangedHandler = { [weak self, weak controller] _, x, y in
                guard let self, self.accepts(controller) else { return }
                self.updateDirections(x: x, y: y, fromStick: false)
            }
            pad.leftThumbstick.valueChangedHandler = { [weak self, weak controller] _, x, y in
                guard let self, self.accepts(controller) else { return }
                self.updateDirections(x: x, y: y, fromStick: true)
            }
            AppLog.log("controller connected: \(controller.vendorName ?? "unknown") (extended)")
        } else if let pad = controller.microGamepad {
            bind(pad.buttonA, .a, controller)
            bind(pad.buttonX, .b, controller)
            bind(pad.buttonMenu, .menu, controller)
            pad.dpad.valueChangedHandler = { [weak self, weak controller] _, x, y in
                guard let self, self.accepts(controller) else { return }
                self.updateDirections(x: x, y: y, fromStick: false)
            }
            AppLog.log("controller connected: \(controller.vendorName ?? "unknown") (basic)")
        }
    }

    private func bind(_ input: GCControllerButtonInput, _ button: ControllerButton, _ controller: GCController) {
        input.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
            guard let self, self.accepts(controller) else { return }
            self.handle(button, pressed)
        }
    }

    /// 8.2.2: with Settings > Controls > Controllers > Only Player 1 Presses Keys, other pads are left to the game.
    private func accepts(_ controller: GCController?) -> Bool {
        guard UserDefaults.standard.bool(forKey: SettingsKey.controllerKeysPlayerOne) else { return true }
        guard let one = NexControllerHub.shared.playerOne, let controller else { return true }
        return controller === one
    }

    private func handle(_ button: ControllerButton, _ pressed: Bool) {
        let binding = map[button] ?? .nothing
        switch binding.action {
        case .none, .dpad, .joystick:
            return
        default:
            if let key = binding.padKey {
                onKey?(key, pressed)
            } else if binding.action.isAppAction {
                onAction?(binding.action, pressed)
            }
        }
    }

    private func updateDirections(x: Float, y: Float, fromStick: Bool) {
        var want = Set<Int>()
        let distance = hypot(Double(x), Double(y))
        if distance > 0.35 {
            let angle = atan2(Double(y), Double(x))
            var sector = Int((angle / (Double.pi / 4)).rounded())
            sector = ((sector % 8) + 8) % 8
            switch sector {
            case 0: want = [39]
            case 1: want = [39, 38]
            case 2: want = [38]
            case 3: want = [37, 38]
            case 4: want = [37]
            case 5: want = [37, 40]
            case 6: want = [40]
            default: want = [39, 40]
            }
        }
        let keys: [Int: PadKey] = [37: .left, 38: .up, 39: .right, 40: .down]
        let old = fromStick ? stickHeld : directionsHeld
        for code in old.subtracting(want) { if let k = keys[code] { onKey?(k, false) } }
        for code in want.subtracting(old) { if let k = keys[code] { onKey?(k, true) } }
        if fromStick { stickHeld = want } else { directionsHeld = want }
    }

    private func releaseDirections() {
        updateDirections(x: 0, y: 0, fromStick: false)
        updateDirections(x: 0, y: 0, fromStick: true)
    }
}

/// Remap screen. With a game it edits "This game" or "All games"; without one only "All games".
struct ControllerMapView: View {
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID?
    let gameName: String?

    @State private var scopeIsGame: Bool
    @State private var map: [ControllerButton: ControllerBinding] = [:]

    init(gameID: UUID?, gameName: String?) {
        self.gameID = gameID
        self.gameName = gameName
        _scopeIsGame = State(initialValue: gameID != nil)
    }

    private var scopeID: UUID? { scopeIsGame ? gameID : nil }

    private static let actions: [ControlAction] = [.none, .confirm, .cancel, .menu, .dash, .pageUp, .pageDown, .fastForward,
                                                   .quickSave, .quickLoad, .gamePanel, .showKeyboard, .mouseLeft, .mouseRight]

    var body: some View {
        NavigationStack {
            Form {
                if let gameName, gameID != nil {
                    Picker("Applies to", selection: $scopeIsGame) {
                        Text("This game").tag(true)
                        Text("All games").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .accessibilityHint("Choose whether changes apply to \(gameName) or to every game")
                }
                Section {
                    ForEach(ControllerButton.allCases) { button in
                        Menu {
                            ForEach(ControllerMapView.actions) { action in
                                Button(action.title) { set(button, ControllerBinding(action: action)) }
                            }
                            Menu("Keyboard Key") {
                                ForEach(PadKey.choosable, id: \.keyCode) { key in
                                    Button(key.title) { set(button, ControllerBinding(action: .key, keyCode: key.keyCode)) }
                                }
                            }
                        } label: {
                            LabeledContent(button.title, value: (map[button] ?? .nothing).title)
                        }
                    }
                } footer: {
                    Text("The D-pad and the left stick always move (arrow keys). Games that read controllers themselves also still see them.")
                }
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        ControllerMapStore.reset(for: scopeID)
                        load()
                    }
                }
            }
            .navigationTitle("Controller Buttons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { SheetCloseButton { dismiss() } }
            }
            .onAppear { load() }
            .onChange(of: scopeIsGame) { _ in load() }
        }
    }

    private func load() {
        map = ControllerMapStore.effective(for: scopeID)
    }

    private func set(_ button: ControllerButton, _ binding: ControllerBinding) {
        map[button] = binding
        ControllerMapStore.save(map, for: scopeID)
    }
}
