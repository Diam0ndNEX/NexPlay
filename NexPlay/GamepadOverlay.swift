import UIKit

struct PadKey {
    let keyCode: Int
    let key: String
    let code: String

    static let left = PadKey(keyCode: 37, key: "ArrowLeft", code: "ArrowLeft")
    static let up = PadKey(keyCode: 38, key: "ArrowUp", code: "ArrowUp")
    static let right = PadKey(keyCode: 39, key: "ArrowRight", code: "ArrowRight")
    static let down = PadKey(keyCode: 40, key: "ArrowDown", code: "ArrowDown")
    static let confirm = PadKey(keyCode: 90, key: "z", code: "KeyZ")      // Z: OK
    static let cancel = PadKey(keyCode: 88, key: "x", code: "KeyX")       // X: Cancel
    static let dash = PadKey(keyCode: 16, key: "Shift", code: "ShiftLeft") // Shift: Dash (held)
    static let menu = PadKey(keyCode: 27, key: "Escape", code: "Escape")  // Esc: Menu
}

final class PadButton: UIView {
    let padKey: PadKey
    var onChange: ((PadKey, Bool) -> Void)?
    private let label = UILabel()
    private var pressed = false

    init(title: String, key: PadKey) {
        self.padKey = key
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 1, alpha: 0.16)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor(white: 1, alpha: 0.5).cgColor
        label.text = title
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        label.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    func set(_ value: Bool) {
        guard value != pressed else { return }
        pressed = value
        backgroundColor = UIColor(white: 1, alpha: value ? 0.45 : 0.16)
        onChange?(padKey, value)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { set(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { set(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { set(false) }
}

final class DPadView: UIView {
    var onChange: ((PadKey, Bool) -> Void)?
    private var active: Set<Int> = []
    private let keys: [Int: PadKey] = [37: .left, 38: .up, 39: .right, 40: .down]
    private var arrows: [Int: UILabel] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: 0.12)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor(white: 1, alpha: 0.4).cgColor
        let symbols: [(Int, String)] = [(38, "▲"), (40, "▼"), (37, "◀"), (39, "▶")]
        for (code, symbol) in symbols {
            let label = UILabel()
            label.text = symbol
            label.textColor = UIColor(white: 1, alpha: 0.6)
            label.font = .systemFont(ofSize: 20)
            label.textAlignment = .center
            addSubview(label)
            arrows[code] = label
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let size: CGFloat = 36
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = bounds.width / 2 - 26
        arrows[38]?.frame = CGRect(x: c.x - size / 2, y: c.y - r - size / 2, width: size, height: size)
        arrows[40]?.frame = CGRect(x: c.x - size / 2, y: c.y + r - size / 2, width: size, height: size)
        arrows[37]?.frame = CGRect(x: c.x - r - size / 2, y: c.y - size / 2, width: size, height: size)
        arrows[39]?.frame = CGRect(x: c.x + r - size / 2, y: c.y - size / 2, width: size, height: size)
    }

    private func update(_ point: CGPoint?) {
        var want = Set<Int>()
        if let p = point {
            let dx = p.x - bounds.midX
            let dy = p.y - bounds.midY
            let distance = hypot(dx, dy)
            if distance > bounds.width * 0.1 {
                let threshold = distance * 0.4
                if dx < -threshold { want.insert(37) }
                if dx > threshold { want.insert(39) }
                if dy < -threshold { want.insert(38) }
                if dy > threshold { want.insert(40) }
            }
        }
        for code in active.subtracting(want) { if let k = keys[code] { onChange?(k, false) } }
        for code in want.subtracting(active) { if let k = keys[code] { onChange?(k, true) } }
        active = want
        for (code, label) in arrows {
            label.textColor = UIColor(white: 1, alpha: want.contains(code) ? 1 : 0.6)
        }
    }

    func releaseAll() { update(nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(touches.first?.location(in: self))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        update(touches.first?.location(in: self))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { update(nil) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { update(nil) }
}

/// Transparent layer over the game with a D-pad and buttons. Touches outside the controls reach the game.
final class GamepadOverlayView: UIView {
    var onKey: ((PadKey, Bool) -> Void)?

    private let dpad = DPadView()
    private let buttonA = PadButton(title: "A", key: .confirm)
    private let buttonB = PadButton(title: "B", key: .cancel)
    private let buttonDash = PadButton(title: "Dash", key: .dash)
    private let buttonMenu = PadButton(title: "Menu", key: .menu)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        alpha = 0.7
        addSubview(dpad)
        [buttonA, buttonB, buttonDash, buttonMenu].forEach { addSubview($0) }
        dpad.onChange = { [weak self] key, down in self?.onKey?(key, down) }
        [buttonA, buttonB, buttonDash, buttonMenu].forEach { button in
            button.onChange = { [weak self] key, down in self?.onKey?(key, down) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = safeAreaInsets
        let margin: CGFloat = 20

        let pad: CGFloat = 150
        dpad.frame = CGRect(x: inset.left + margin,
                            y: bounds.height - inset.bottom - margin - pad,
                            width: pad, height: pad)

        let size: CGFloat = 58
        let ax = bounds.width - inset.right - margin - 40
        let ay = bounds.height - inset.bottom - margin - 70
        func place(_ view: UIView, dx: CGFloat, dy: CGFloat) {
            view.frame = CGRect(x: ax + dx - size / 2, y: ay + dy - size / 2, width: size, height: size)
        }
        place(buttonA, dx: 0, dy: 0)
        place(buttonB, dx: -72, dy: 34)
        place(buttonDash, dx: -72, dy: -38)
        place(buttonMenu, dx: 0, dy: -72)
    }

    func releaseAll() {
        dpad.releaseAll()
        [buttonA, buttonB, buttonDash, buttonMenu].forEach { $0.set(false) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }
}
