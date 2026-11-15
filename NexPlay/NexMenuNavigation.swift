import GameController
import SwiftUI

// 8.7.1: a controller in NexPlay's in-game menu (Game Panel and the Windows panel, both on NexInGameMenu), as BCD's
// in-game menu does it: the D-pad or left stick moves a ring row by row (up/left = back, down/right = on; left/right
// change a slider), A presses the row, B goes back (question, page, then closes), L1/R1 switch tabs, Menu closes.
// While the menu is open the game gets no controller input: the controllers' element handlers (set by
// PhysicalControllerManager for web games) are saved when the menu opens and put back when it closes.
// Windows games read controllers inside the engine too, so a press there may still reach the game.

/// The rows that take the ring, in the order they are drawn.
struct NexMenuOrderKey: PreferenceKey {
    static var defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

@MainActor
final class NexMenuNavigator: ObservableObject {
    @Published private(set) var focused: String?
    /// True after the first controller press, so touch users never see the ring.
    @Published private(set) var controllerActive = false

    var order: [String] = [] {
        didSet {
            if let focused, !order.contains(focused) { self.focused = order.first }
            if focused == nil && autoFocusFirst { focused = order.first }
        }
    }
    /// The game page: its first row (Play) has the focus from the start, so A plays as before (7.8.0).
    var autoFocusFirst = false
    private var actions: [String: () -> Void] = [:]
    private var steps: [String: (Int) -> Void] = [:]

    var onBack: (() -> Void)?
    var onClose: (() -> Void)?
    var onTab: ((Int) -> Void)?

    private struct Saved {
        weak var controller: GCController?
        var buttons: [(GCControllerButtonInput, GCControllerButtonValueChangedHandler?)]
        var pads: [(GCControllerDirectionPad, GCControllerDirectionPadValueChangedHandler?)]
    }
    private var saved: [Saved] = []
    private var observer: NSObjectProtocol?
    private var lastX = 0
    private var lastY = 0

    func register(_ id: String, action: @escaping () -> Void, step: ((Int) -> Void)? = nil) {
        actions[id] = action
        steps[id] = step
    }

    func unregister(_ id: String) {
        actions[id] = nil
        steps[id] = nil
    }

    /// A page or tab changed: the ring goes back to its first row.
    func reset() {
        focused = autoFocusFirst ? order.first : nil
    }

    // MARK: Controllers

    func capture() {
        guard saved.isEmpty else { return }
        GCController.controllers().forEach { take($0) }
        observer = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.take(controller) }
        }
    }

    func release() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for entry in saved where entry.controller != nil {
            for (input, handler) in entry.buttons { input.pressedChangedHandler = handler }
            for (pad, handler) in entry.pads { pad.valueChangedHandler = handler }
        }
        saved = []
    }

    private func take(_ controller: GCController) {
        guard !saved.contains(where: { $0.controller === controller }) else { return }
        var buttons: [(GCControllerButtonInput, GCControllerButtonValueChangedHandler?)] = []
        var pads: [(GCControllerDirectionPad, GCControllerDirectionPadValueChangedHandler?)] = []
        func button(_ input: GCControllerButtonInput?, _ press: (() -> Void)?) {
            guard let input else { return }
            buttons.append((input, input.pressedChangedHandler))
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed, let press else { return }
                Task { @MainActor in
                    self?.wake()
                    press()
                }
            }
        }
        func pad(_ input: GCControllerDirectionPad?) {
            guard let input else { return }
            pads.append((input, input.valueChangedHandler))
            input.valueChangedHandler = { [weak self] _, x, y in
                Task { @MainActor in self?.direction(x: x, y: y) }
            }
        }
        if let gamepad = controller.extendedGamepad {
            button(gamepad.buttonA) { [weak self] in self?.press() }
            button(gamepad.buttonB) { [weak self] in self?.back() }
            button(gamepad.buttonX, nil)
            button(gamepad.buttonY, nil)
            button(gamepad.leftShoulder) { [weak self] in self?.onTab?(-1) }
            button(gamepad.rightShoulder) { [weak self] in self?.onTab?(1) }
            button(gamepad.leftTrigger, nil)
            button(gamepad.rightTrigger, nil)
            button(gamepad.buttonMenu) { [weak self] in self?.onClose?() }
            button(gamepad.buttonOptions, nil)
            button(gamepad.leftThumbstickButton, nil)
            button(gamepad.rightThumbstickButton, nil)
            pad(gamepad.dpad)
            pad(gamepad.leftThumbstick)
        } else if let micro = controller.microGamepad {
            button(micro.buttonA) { [weak self] in self?.press() }
            button(micro.buttonX) { [weak self] in self?.back() }
            button(micro.buttonMenu) { [weak self] in self?.onClose?() }
            pad(micro.dpad)
        }
        saved.append(Saved(controller: controller, buttons: buttons, pads: pads))
    }

    // MARK: Commands

    private func wake() {
        if !controllerActive { controllerActive = true }
    }

    private func press() {
        guard let focused else {
            focused = order.first
            return
        }
        actions[focused]?()
    }

    private func back() {
        onBack?()
    }

    private func move(_ delta: Int) {
        guard !order.isEmpty else { return }
        guard let focused, let index = order.firstIndex(of: focused) else {
            self.focused = order.first
            NexHaptics.selection()
            return
        }
        let next = min(order.count - 1, max(0, index + delta))
        if next != index {
            self.focused = order[next]
            NexHaptics.selection()
        }
    }

    /// One step per push: the stick or pad has to come back to the middle before the next step.
    private func direction(x: Float, y: Float) {
        let dx = x > 0.5 ? 1 : (x < -0.5 ? -1 : 0)
        let dy = y > 0.5 ? -1 : (y < -0.5 ? 1 : 0)
        guard dx != lastX || dy != lastY else { return }
        lastX = dx
        lastY = dy
        guard dx != 0 || dy != 0 else { return }
        wake()
        if dy != 0 {
            move(dy)
        } else if let focused, let step = steps[focused] {
            step(dx)
            NexHaptics.selection()
        } else {
            move(dx)
        }
    }
}

extension EnvironmentValues {
    @Entry var nexMenuNavigator: NexMenuNavigator? = nil
}

/// Makes a menu row reachable with a controller: A runs `action`; `step` (left/right) for sliders.
private struct NexMenuFocusable: ViewModifier {
    @Environment(\.nexMenuNavigator) private var navigator
    let id: String
    let token: String
    let enabled: Bool
    let action: () -> Void
    let step: ((Int) -> Void)?

    func body(content: Content) -> some View {
        if let navigator, enabled {
            content.modifier(NexMenuRing(navigator: navigator, id: id, token: token, action: action, step: step))
        } else {
            content
        }
    }
}

private struct NexMenuRing: ViewModifier {
    @ObservedObject var navigator: NexMenuNavigator
    let id: String
    let token: String
    let action: () -> Void
    let step: ((Int) -> Void)?

    func body(content: Content) -> some View {
        let on = navigator.controllerActive && navigator.focused == id
        content
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(NexColor.accent, lineWidth: 2.5)
                        .shadow(color: NexColor.accent.opacity(0.6), radius: 6)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .id(id)
            .preference(key: NexMenuOrderKey.self, value: [id])
            .onAppear { navigator.register(id, action: action, step: step) }
            .onChange(of: token) { _ in navigator.register(id, action: action, step: step) }
            .onDisappear { navigator.unregister(id) }
    }
}

extension View {
    /// 8.7.1: a row the in-game menu's controller ring can reach (no effect outside NexInGameMenu).
    func nexMenuFocusable(_ id: String, token: String = "", enabled: Bool = true,
                          step: ((Int) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(NexMenuFocusable(id: id, token: token, enabled: enabled, action: action, step: step))
    }
}
