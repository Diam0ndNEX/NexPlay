// NexPlay 8.2.0: Controls Style on the engine's side. Not part of BCD (NexPlay's own code, in this folder because it
// uses BCD's touch-control types, which only compile in builds with the Windows engine: NEXPLAY_WINDOWS).
// - PC Controls over web-view games: BCD's touch layer and editor (BCDTouchLayer, BCDTouchEditor, the shared layouts in
//   TouchControlsModel/ControlPresetsModel) with an input that sends to the web page instead of Wine:
//   keys → the player's KeyRouter (Windows virtual-key codes are DOM key codes for the keys BCD offers), mouse buttons →
//   the player's mouse, controller controls → NexPlay's pad keys (A = Z, B = X, X = Shift, Y = Esc, D-pad/left stick =
//   arrows, LB/RB = Page Up/Down, LT/RT = Q/E, View = Tab, Menu = Esc).
// - NexPlay Pad over Windows games: NexPlay's overlay sends through winios_post_key / winios_pointer, as BCD's own
//   touch controls do (BCDTouchLive.send), and BCD's touch controls are hidden while it is on.
// Uses BCD's code unchanged. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
import Combine
import SwiftUI
import UIKit

// MARK: - PC Controls over a web-view game

@MainActor
final class NexPCTouchLayer: PCControlsLayer {
    private let host: UIHostingController<NexPCTouchRoot>
    private let container: NexPCTouchView
    private let input: NexPCWebInput
    private var watch: AnyCancellable?
    var onEditingChanged: ((Bool) -> Void)?

    init(input target: PCControlsInput) {
        let made = NexPCWebInput(target: target)
        input = made
        let model = TouchControlsModel.shared
        // In NexPlay the game's On-Screen Controls switch shows or hides the layer; BCD's own switch stays on.
        if !model.visible { model.visible = true }
        if model.controls.isEmpty {
            ControlPresetsModel.shared.applyGameDefault(steam: false, reason: "nexplay-web")
        }
        let hosting = UIHostingController(rootView: NexPCTouchRoot(input: made))
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        let box = NexPCTouchView(frame: .zero)
        box.backgroundColor = .clear
        hosting.view.frame = box.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(hosting.view)
        host = hosting
        container = box
        watch = model.$editing
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] editing in
                Task { @MainActor in
                    guard let self else { return }
                    if !editing { self.input.releaseAll() }
                    self.onEditingChanged?(editing)
                }
            }
        AppLog.log("controls: PC Controls on a web game (\(model.controls.count) controls)")
    }

    var view: UIView { container }
    var isEditing: Bool { TouchControlsModel.shared.editing }

    func setEditing(_ on: Bool) {
        let model = TouchControlsModel.shared
        if on { input.releaseAll() }
        model.selected = nil
        if model.editing != on { model.editing = on }
    }

    func releaseAll() { input.releaseAll() }
}

/// Takes touches only on a control (BCD's geometric hit test, TouchControlsModel.hitsInteractive), every touch while
/// editing; everything else goes to the game below.
final class NexPCTouchView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, let hit = super.hitTest(point, with: event) else { return nil }
        let model = TouchControlsModel.shared
        if model.editing { return hit }
        return model.hitsInteractive(point, in: bounds, topBar: false) ? hit : nil
    }
}

struct NexPCTouchRoot: View {
    let input: NexPCWebInput
    @ObservedObject private var model = TouchControlsModel.shared
    @ObservedObject private var presets = ControlPresetsModel.shared
    @ObservedObject private var feel = BCDTouchFeelModel.shared
    @ObservedObject private var looks = BCDTouchLookModel.shared
    @StateObject private var focus = BCDFocus()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                BCDTouchLayer(items: BCDTouchLive.shared.items, screen: geo.size, layoutScale: model.sizeScale,
                              opacity: model.editing ? 1 : model.opacity, editing: model.editing, selected: model.selected,
                              input: input, arranging: BCDTouchLive.shared, look: looks.look)
                    .id(feel.revision)
                if model.editing {
                    BCDTouchEditor(state: BCDTouchLive.shared.editorState, screen: geo.size,
                                   insets: BCDTouchSafeArea.insets(), actions: BCDTouchLive.shared)
                }
            }
        }
        .ignoresSafeArea()
        .environmentObject(focus)
    }
}

/// BCD's touch events into the web page.
@MainActor
final class NexPCWebInput: BCDTouchInput {
    private weak var target: PCControlsInput?
    /// Keys a controller control holds, by control.
    private var padHeld: [UUID: Set<Int>] = [:]

    init(target: PCControlsInput) {
        self.target = target
    }

    func send(_ event: BCDTouchEvent) {
        guard let target else { return }
        switch event {
        case .key(let vk, let down):
            target.pcKey(PadKey.fromKeyCode(Int(vk)), down)
        case .mouse(let flags):
            switch flags {
            case BCDTouchEvent.leftDown: target.pcMouse(right: false, down: true)
            case BCDTouchEvent.leftUp: target.pcMouse(right: false, down: false)
            case BCDTouchEvent.rightDown: target.pcMouse(right: true, down: true)
            case BCDTouchEvent.rightUp: target.pcMouse(right: true, down: false)
            default: break
            }
        case .toggleKeyboard:
            target.pcToggleKeyboard()
        }
    }

    func padSurface(control: UUID, name: String, changed: @escaping (CGSize, Bool) -> Void) -> AnyView {
        AnyView(NexPCPadSurface(control: control, name: name, input: self, changed: changed))
    }

    /// A controller control's thumb moved (x right, y down, unit circle) or let go.
    func pad(_ control: UUID, _ name: String, x: Double, y: Double, held: Bool) {
        let now = held ? Self.keys(for: name, x: x, y: y) : []
        let before = padHeld[control] ?? []
        for code in before.subtracting(now) { target?.pcKey(PadKey.fromKeyCode(code), false) }
        for code in now.subtracting(before) { target?.pcKey(PadKey.fromKeyCode(code), true) }
        padHeld[control] = now.isEmpty ? nil : now
    }

    func releaseAll() {
        for (_, codes) in padHeld {
            for code in codes { target?.pcKey(PadKey.fromKeyCode(code), false) }
        }
        padHeld = [:]
    }

    /// NexPlay's pad keys for player 1's controller inputs.
    static func keys(for name: String, x: Double, y: Double) -> Set<Int> {
        switch name {
        case "A": return [PadKey.confirm.keyCode]
        case "B": return [PadKey.cancel.keyCode]
        case "X": return [PadKey.dash.keyCode]
        case "Y", "Menu": return [PadKey.menu.keyCode]
        case "View": return [PadKey.tab.keyCode]
        case "D↑": return [PadKey.up.keyCode]
        case "D↓": return [PadKey.down.keyCode]
        case "D←": return [PadKey.left.keyCode]
        case "D→": return [PadKey.right.keyCode]
        case "LB": return [PadKey.pageUp.keyCode]
        case "RB": return [PadKey.pageDown.keyCode]
        case "LT": return [81]   // Q
        case "RT": return [69]   // E
        case "LS":
            var keys: Set<Int> = []
            let dead = 0.35
            if x < -dead { keys.insert(PadKey.left.keyCode) }
            if x > dead { keys.insert(PadKey.right.keyCode) }
            if y < -dead { keys.insert(PadKey.up.keyCode) }
            if y > dead { keys.insert(PadKey.down.keyCode) }
            return keys
        default: return []
        }
    }
}

/// A controller control's surface over a web game: the thumb's travel from where it came down, as BCD's TouchPadView.
struct NexPCPadSurface: UIViewRepresentable {
    let control: UUID
    let name: String
    let input: NexPCWebInput
    let changed: (CGSize, Bool) -> Void

    func makeUIView(context: Context) -> NexPCPadView { NexPCPadView() }

    func updateUIView(_ view: NexPCPadView, context: Context) {
        view.configure(control: control, name: name, input: input, changed: changed)
    }

    static func dismantleUIView(_ view: NexPCPadView, coordinator: ()) { view.finishAll() }
}

final class NexPCPadView: UIView {
    private var starts: [ObjectIdentifier: CGPoint] = [:]
    private var control = UUID()
    private var name = ""
    private weak var input: NexPCWebInput?
    private var changed: ((CGSize, Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    func configure(control: UUID, name: String, input: NexPCWebInput, changed: @escaping (CGSize, Bool) -> Void) {
        if self.control != control || self.name != name { finishAll() }
        self.control = control
        self.name = name
        self.input = input
        self.changed = changed
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishAll() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { starts[ObjectIdentifier(touch)] = touch.location(in: self) }
        update(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func update(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let start = starts[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            let radius = max(1, bounds.width * 0.35)
            var x = Double((point.x - start.x) / radius)
            var y = Double((point.y - start.y) / radius)
            let length = (x * x + y * y).squareRoot()
            if length > 1 { x /= length; y /= length }
            send(x: x, y: y, held: true)
        }
    }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches { starts.removeValue(forKey: ObjectIdentifier(touch)) }
        if starts.isEmpty { send(x: 0, y: 0, held: false) }
    }

    func finishAll() {
        guard !starts.isEmpty else { return }
        starts.removeAll()
        send(x: 0, y: 0, held: false)
    }

    private func send(x: Double, y: Double, held: Bool) {
        let control = self.control, name = self.name
        let changed = self.changed
        input?.pad(control, name, x: x, y: y, held: held)
        changed?(CGSize(width: x, height: y), held)
    }
}

// MARK: - NexPlay Pad over a Windows game

/// NexPlay's overlay keys and mouse buttons into Wine, and BCD's touch controls hidden while the pad is on.
@MainActor
enum NexWindowsPadInput {
    private static var counts: [Int: Int] = [:]
    private static let hidKey = "nexHidBCDTouchControls"

    static func key(_ key: PadKey, _ down: Bool) {
        let code = key.keyCode
        let current = counts[code] ?? 0
        if down {
            counts[code] = current + 1
            if current == 0 { winios_post_key(Int32(code), 1) }
        } else {
            guard current > 0 else { return }
            counts[code] = current - 1
            if current == 1 { winios_post_key(Int32(code), 0) }
        }
    }

    static func mouse(right: Bool, down: Bool) {
        let flags: UInt32 = right ? (down ? BCDTouchEvent.rightDown : BCDTouchEvent.rightUp)
                                  : (down ? BCDTouchEvent.leftDown : BCDTouchEvent.leftUp)
        winios_pointer(0, 0, flags, 0)
    }

    static func toggleKeyboard() { MetalBackedView.toggleKeyboard() }

    /// BCD's editor over the running Windows game (PC Controls).
    static func editPCControls() {
        let model = TouchControlsModel.shared
        if !model.visible { model.visible = true }
        model.selected = nil
        model.editing = true
    }

    static func releaseAll() {
        for (code, count) in counts where count > 0 { winios_post_key(Int32(code), 0) }
        counts = [:]
    }

    /// BCD's touch controls follow the game's Controls Style: hidden under the NexPlay Pad, shown again for PC Controls
    /// if NexPlay hid them (a choice the player made in BCD's in-game menu is kept).
    static func applyStyle(_ style: ControlsStyle) {
        let model = TouchControlsModel.shared
        let defaults = UserDefaults.standard
        switch style {
        case .nexPad:
            if model.editing { model.editing = false }
            if model.visible {
                model.visible = false
                defaults.set(true, forKey: hidKey)
            }
        case .pc:
            if defaults.bool(forKey: hidKey) {
                defaults.removeObject(forKey: hidKey)
                if !model.visible { model.visible = true }
            }
        }
    }
}
