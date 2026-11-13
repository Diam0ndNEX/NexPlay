import UIKit
import SwiftUI

// 7.3.0: a PC keyboard for games (Esc, F1-F12, Tab, Ctrl, Alt, Shift, arrows, navigation keys). It is the input
// view of the player's KeySenderField, so it slides up like the system keyboard; the bar above it switches between
// these keys and the system keyboard (ABC) for typing names.
// Keys go down when touched and up when released, so arrows can be held. Shift, Ctrl and Alt latch: they stay
// down until the next key is released or they are tapped again.

final class SoftKeyboardView: UIInputView, UIInputViewAudioFeedback {
    var onKey: ((PadKey, Bool) -> Void)?

    private struct Key {
        let key: PadKey
        let label: String
        let width: CGFloat
    }

    private var rows: [[Key]] = []
    private var buttons: [[UIButton]] = []
    private var latched: Set<Int> = []
    private static let modifiers: Set<Int> = [16, 17, 18]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 228), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]
        rows = SoftKeyboardView.layout()
        for row in rows {
            var line: [UIButton] = []
            for key in row {
                let button = UIButton(type: .custom)
                button.setTitle(key.label, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.5
                button.setTitleColor(.white, for: .normal)
                button.backgroundColor = SoftKeyboardView.isModifier(key.key) ? UIColor(white: 0.32, alpha: 1) : UIColor(white: 0.42, alpha: 1)
                button.layer.cornerRadius = 6
                button.layer.shadowColor = UIColor.black.cgColor
                button.layer.shadowOpacity = 0.35
                button.layer.shadowRadius = 0
                button.layer.shadowOffset = CGSize(width: 0, height: 1)
                button.tag = key.key.keyCode
                button.accessibilityLabel = key.key.title
                button.addTarget(self, action: #selector(down(_:)), for: .touchDown)
                button.addTarget(self, action: #selector(up(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
                addSubview(button)
                line.append(button)
            }
            buttons.append(line)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var enableInputClicksWhenVisible: Bool { true }

    private static func isModifier(_ key: PadKey) -> Bool {
        modifiers.contains(key.keyCode)
    }

    private static func make(_ code: Int, _ label: String? = nil, _ width: CGFloat = 1) -> Key {
        let pad = PadKey.fromKeyCode(code)
        return Key(key: pad, label: label ?? pad.shortTitle, width: width)
    }

    /// Four rows, eleven units wide (the F-key row has thirteen equal keys). ↑ sits over ↓.
    private static func layout() -> [[Key]] {
        var first: [Key] = [make(27, "Esc")]
        first += (112...123).map { make($0) }
        let second: [Key] = [make(9, "Tab", 1.5), make(45), make(46), make(36), make(35), make(33), make(34), make(57), make(48)]
            .enumerated().map { index, item in
                (1...6).contains(index) ? Key(key: item.key, label: item.label, width: 1.25) : item
            }
        let third: [Key] = [make(16, "Shift", 1.5), make(17, "Ctrl", 1.5), make(18, "Alt", 1.5), make(32, "Space", 2.5),
                            make(13, "Enter", 2), make(38, "↑"), make(8, "⌫")]
        var fourth: [Key] = (49...56).map { make($0) }
        fourth += [make(37, "←"), make(40, "↓"), make(39, "→")]
        return [first, second, third, fourth]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin: CGFloat = 4
        let gap: CGFloat = 5
        let insets = safeAreaInsets
        let width = bounds.width - insets.left - insets.right - margin * 2
        let rowHeight = (bounds.height - insets.bottom - margin * 2 - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        var y = margin
        for (index, row) in rows.enumerated() {
            let units = row.reduce(CGFloat(0)) { $0 + $1.width }
            let unit = (width - gap * CGFloat(row.count - 1)) / units
            var x = insets.left + margin
            for (column, key) in row.enumerated() {
                let w = unit * key.width
                buttons[index][column].frame = CGRect(x: x, y: y, width: w, height: rowHeight)
                x += w + gap
            }
            y += rowHeight + gap
        }
    }

    private func key(for button: UIButton) -> PadKey {
        PadKey.fromKeyCode(button.tag)
    }

    @objc private func down(_ button: UIButton) {
        UIDevice.current.playInputClick()
        let pad = key(for: button)
        if SoftKeyboardView.isModifier(pad) {
            if latched.contains(pad.keyCode) {
                latched.remove(pad.keyCode)
                onKey?(pad, false)
            } else {
                latched.insert(pad.keyCode)
                onKey?(pad, true)
            }
            refreshModifiers()
            return
        }
        button.backgroundColor = UIColor(white: 0.62, alpha: 1)
        onKey?(pad, true)
    }

    @objc private func up(_ button: UIButton) {
        let pad = key(for: button)
        guard !SoftKeyboardView.isModifier(pad) else { return }
        button.backgroundColor = UIColor(white: 0.42, alpha: 1)
        onKey?(pad, false)
        releaseModifiers()
    }

    /// Lets go of latched Shift, Ctrl and Alt (after a key, or when the keyboard closes).
    func releaseModifiers() {
        guard !latched.isEmpty else { return }
        for code in latched {
            onKey?(PadKey.fromKeyCode(code), false)
        }
        latched = []
        refreshModifiers()
    }

    private func refreshModifiers() {
        for line in buttons {
            for button in line where SoftKeyboardView.modifiers.contains(button.tag) {
                button.backgroundColor = latched.contains(button.tag) ? UIColor(NexStyle.accent) : UIColor(white: 0.32, alpha: 1)
            }
        }
    }
}

/// The bar above the keyboard: PC Keys / ABC switch and Done.
final class KeyboardSwitchBar: UIInputView {
    var onSwitch: ((Bool) -> Void)?
    var onDone: (() -> Void)?
    private let picker = UISegmentedControl(items: ["PC Keys", "ABC"])
    private let done = UIButton(type: .system)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]
        picker.selectedSegmentIndex = 0
        picker.addTarget(self, action: #selector(changed), for: .valueChanged)
        addSubview(picker)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        addSubview(done)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(pcKeys: Bool) {
        picker.selectedSegmentIndex = pcKeys ? 0 : 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = safeAreaInsets
        picker.frame = CGRect(x: insets.left + 10, y: 6, width: 200, height: 32)
        done.frame = CGRect(x: bounds.width - insets.right - 80, y: 0, width: 70, height: 44)
    }

    @objc private func changed() {
        onSwitch?(picker.selectedSegmentIndex == 0)
    }

    @objc private func doneTapped() {
        onDone?()
    }
}
