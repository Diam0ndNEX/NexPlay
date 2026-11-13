import GameController
import SwiftUI

// 7.8.0 (SPEC-7.0-review C10): drive Home and Library with a controller. D-pad or left stick moves a focus ring,
// A opens the game page (A again on the game page plays), X plays right away, B closes the game page,
// L1/R1 switch tabs, Menu opens Settings. The player's controller code replaces these handlers while a game runs;
// the library attaches them again when the game closes.

@MainActor
final class LibraryController: ObservableObject {
    enum Button {
        case a, b, x, y, menu, l1, r1
    }

    /// Column and row steps: (dx, dy), dy = 1 is down.
    var onMove: ((Int, Int) -> Void)?
    var onButton: ((Button) -> Void)?
    @Published private(set) var connected = !GCController.controllers().isEmpty

    private var observers: [NSObjectProtocol] = []
    private var lastX = 0
    private var lastY = 0

    func start() {
        stop()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in
                self?.attach(controller)
                self?.connected = true
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connected = !GCController.controllers().isEmpty }
        })
        GCController.controllers().forEach { attach($0) }
        connected = !GCController.controllers().isEmpty
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    private func attach(_ controller: GCController) {
        if let pad = controller.extendedGamepad {
            bind(pad.buttonA, .a)
            bind(pad.buttonB, .b)
            bind(pad.buttonX, .x)
            bind(pad.buttonY, .y)
            bind(pad.buttonMenu, .menu)
            bind(pad.leftShoulder, .l1)
            bind(pad.rightShoulder, .r1)
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                self?.direction(x: x, y: y)
            }
            pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
                self?.direction(x: x, y: y)
            }
        } else if let pad = controller.microGamepad {
            bind(pad.buttonA, .a)
            bind(pad.buttonX, .b)
            bind(pad.buttonMenu, .menu)
            pad.dpad.valueChangedHandler = { [weak self] _, x, y in
                self?.direction(x: x, y: y)
            }
        }
    }

    private func bind(_ input: GCControllerButtonInput, _ button: Button) {
        input.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onButton?(button)
        }
    }

    /// One step per push: the stick or pad has to come back to the middle before the next step.
    private func direction(x: Float, y: Float) {
        let dx = x > 0.5 ? 1 : (x < -0.5 ? -1 : 0)
        let dy = y > 0.5 ? -1 : (y < -0.5 ? 1 : 0)
        guard dx != lastX || dy != lastY else { return }
        lastX = dx
        lastY = dy
        if dx != 0 || dy != 0 {
            UISelectionFeedbackGenerator().selectionChanged()
            onMove?(dx, dy)
        }
    }
}

/// The ring drawn around the game that has the controller's focus.
struct FocusRing: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(NexStyle.accent, lineWidth: 3)
                        .shadow(color: NexStyle.accent.opacity(0.8), radius: 8)
                        .padding(-4)
                }
            }
            .scaleEffect(focused ? 1.04 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focused)
    }
}

extension View {
    func focusRing(_ focused: Bool) -> some View {
        modifier(FocusRing(focused: focused))
    }
}
