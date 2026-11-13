import UIKit

// The control bar (a handle you drag anywhere that opens into a bar of buttons) and the keyboard key sender are
// ideas from RPGPlayer; the code here is NexPlay's own.

extension SettingsKey {
    static let barOpacity = "barOpacity"                     // 0.3...1
    static let barScale = "barScale"                         // 0.7...1.4
    static let barDrawer = "barDrawer"                       // "horizontal" or "vertical"
    static let barGlass = "barGlass"
    static let barAutoHide = "barAutoHide"
    static let barShowFastForward = "barShowFastForward"
    static let barShowScreenshot = "barShowScreenshot"
    static let barShowKeyboard = "barShowKeyboard"
    static let barShowCheats = "barShowCheats"
    static let barPosition = "barPosition"                   // [x, y] normalized to the safe area
    static let touchPadScale = "touchPadScale"               // 0.6...1.6, multiplies every control's size
    static let touchPadOpacity = "touchPadOpacity"           // 0.2...1, multiplies every control's opacity
    static let touchDirectionalType = "touchDirectionalType" // "layout", "dpad" or "joystick"
    static let physicalControllerEnabled = "physicalControllerEnabled"
    static let hidePadWithController = "hidePadWithController"
    static let barWithController = "barWithController"
    static let autoRotateInGames = "autoRotateInGames"
    static let newGameOrientation = "newGameOrientation"     // OrientationMode raw value for new RPG Maker games
    static let autoRotateOutside = "autoRotateOutside"
    static let portraitGameOffset = "portraitGameOffset"     // 0...0.3 of the screen height, upward

    /// Keys from this file that Reset to Defaults clears.
    static let playerKeys: [String] = [
        barOpacity, barScale, barDrawer, barGlass, barAutoHide, barShowFastForward, barShowScreenshot, barShowKeyboard,
        barShowCheats, barPosition, touchPadScale, touchPadOpacity, touchDirectionalType, physicalControllerEnabled,
        hidePadWithController, barWithController, autoRotateInGames, newGameOrientation, autoRotateOutside,
        portraitGameOffset,
    ]
}

/// Player settings for the touch controls and the control bar, read when a game starts.
struct ControlPrefs {
    var barOpacity: Double
    var barScale: Double
    var verticalDrawer: Bool
    var glass: Bool
    var autoHide: Bool
    var showFastForward: Bool
    var showScreenshot: Bool
    var showKeyboard: Bool
    var showCheats: Bool
    var padScale: Double
    var padOpacity: Double
    var directional: String
    var physicalControllers: Bool
    var hidePadWithController: Bool
    var barWithController: Bool
    var portraitOffset: Double

    static func current() -> ControlPrefs {
        let defaults = UserDefaults.standard
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
            return min(max(value, range.lowerBound), range.upperBound)
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        return ControlPrefs(
            barOpacity: number(SettingsKey.barOpacity, 0.85, 0.3...1),
            barScale: number(SettingsKey.barScale, 1, 0.7...1.4),
            verticalDrawer: defaults.string(forKey: SettingsKey.barDrawer) == "vertical",
            glass: flag(SettingsKey.barGlass, true),
            autoHide: flag(SettingsKey.barAutoHide, true),
            showFastForward: flag(SettingsKey.barShowFastForward, true),
            showScreenshot: flag(SettingsKey.barShowScreenshot, true),
            showKeyboard: flag(SettingsKey.barShowKeyboard, true),
            showCheats: flag(SettingsKey.barShowCheats, true),
            padScale: number(SettingsKey.touchPadScale, 1, 0.6...1.6),
            padOpacity: number(SettingsKey.touchPadOpacity, 1, 0.2...1),
            directional: defaults.string(forKey: SettingsKey.touchDirectionalType) ?? "layout",
            physicalControllers: flag(SettingsKey.physicalControllerEnabled, true),
            hidePadWithController: flag(SettingsKey.hidePadWithController, true),
            barWithController: flag(SettingsKey.barWithController, false),
            portraitOffset: number(SettingsKey.portraitGameOffset, 0, 0...0.3)
        )
    }

    /// The layout as shown: global size and opacity applied, directional pad type swapped when the setting asks.
    func display(_ profile: LayoutProfile) -> LayoutProfile {
        var copy = profile
        copy.portrait = profile.portrait.map { shown($0) }
        copy.landscape = profile.landscape.map { shown($0) }
        return copy
    }

    /// The inverse of `display` for sizes and opacity, used before a layout is saved.
    func stored(_ profile: LayoutProfile) -> LayoutProfile {
        var copy = profile
        copy.portrait = profile.portrait.map { kept($0) }
        copy.landscape = profile.landscape.map { kept($0) }
        return copy
    }

    private func shown(_ item: ControlItem) -> ControlItem {
        var item = item
        item.size = item.size * padScale
        item.opacity = min(1, item.opacity * padOpacity)
        if item.action.isDirectional {
            if directional == "dpad" { item.action = .dpad }
            if directional == "joystick" { item.action = .joystick }
        }
        return item
    }

    private func kept(_ item: ControlItem) -> ControlItem {
        var item = item
        item.size = item.size / max(padScale, 0.1)
        item.opacity = min(1, item.opacity / max(padOpacity, 0.1))
        return item
    }
}

/// A full-screen, touch-transparent layer with a draggable handle. Tapping the handle opens a bar of buttons next to
/// it: to the right when the handle sits on the left half, to the left on the right half (or up/down when the
/// vertical drawer is chosen and fits). The bar fades out after 5 seconds without use when auto-hide is on; the
/// player wakes it when the screen is tapped.
final class ControlBarView: UIView {
    enum Item {
        case close, keyboard, gamepad, settings, screenshot, edit, fastForward, cheats
    }

    var onItem: ((Item) -> Void)?
    /// Items for the settings button's menu (the full game menu).
    var menuProvider: (() -> [UIMenuElement])?
    /// The view share sheets and popovers point at.
    var anchor: UIView { handle }

    private let handle = UIButton(type: .system)
    private var handleBackground = UIView()
    /// The game's cover inside the handle bubble (RPGPlayer idea); the grid symbol shows when there is none.
    private let iconView = UIImageView()
    private let ringLayer = CAShapeLayer()
    private let drawer = UIView()
    private var drawerBackground = UIView()
    private var buttons: [(item: Item, button: UIButton)] = []
    private var prefs = ControlPrefs.current()
    private var expanded = false
    private var asleep = false
    private var controllerConnected = false
    private var hideTimer: Timer?
    private var position = CGPoint(x: 0.97, y: 0.12)
    private var gamepadOn = true
    private var fastForwardOn = false
    /// Controls are being edited: the bar stays open, the pencil turns into a green check mark (Done) and the
    /// other buttons rest behind dashed rings.
    private var editing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        drawer.isHidden = true
        drawer.alpha = 0
        addSubview(drawer)
        addSubview(handle)
        handle.tintColor = .white
        handle.accessibilityLabel = "Game controls"
        handle.addTarget(self, action: #selector(handleTapped), for: .touchUpInside)
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:))))
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.isUserInteractionEnabled = false
        iconView.layer.magnificationFilter = .nearest
        handle.addSubview(iconView)
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor(red: 0.62, green: 0.48, blue: 1, alpha: 1).cgColor
        ringLayer.lineWidth = 2.5
        ringLayer.opacity = 0
        handle.layer.addSublayer(ringLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(prefs: ControlPrefs, showFastForward: Bool, showCheats: Bool = false, icon: UIImage? = nil) {
        self.prefs = prefs
        iconView.image = icon
        iconView.isHidden = icon == nil
        handleBackground.removeFromSuperview()
        handleBackground = makeBackground()
        handle.insertSubview(handleBackground, at: 0)
        drawerBackground.removeFromSuperview()
        drawerBackground = makeBackground()
        drawer.insertSubview(drawerBackground, at: 0)

        buttons.forEach { $0.button.removeFromSuperview() }
        buttons = []
        var items: [Item] = [.close]
        if prefs.showKeyboard { items.append(.keyboard) }
        items.append(.gamepad)
        items.append(.settings)
        if prefs.showScreenshot { items.append(.screenshot) }
        items.append(.edit)
        if showFastForward { items.append(.fastForward) }
        if showCheats { items.append(.cheats) }
        for item in items {
            let button = makeButton(for: item)
            drawer.addSubview(button)
            buttons.append((item: item, button: button))
        }
        loadPosition()
        refreshButtons()
        applyAlpha(animated: false)
        restartTimer()
        setNeedsLayout()
    }

    func setEditing(_ value: Bool) {
        editing = value
        if value {
            stopTimer()
            asleep = false
            expanded = true
            drawer.isHidden = false
        }
        refreshButtons()
        setNeedsLayout()
        layoutIfNeeded()
        applyAlpha(animated: true)
        if !value { restartTimer() }
    }

    func setState(gamepadOn: Bool, fastForwardOn: Bool) {
        self.gamepadOn = gamepadOn
        self.fastForwardOn = fastForwardOn
        refreshButtons()
    }

    /// A physical controller connected or went away. The bar hides with a controller unless the setting keeps it.
    func update(controllerConnected connected: Bool) {
        let changed = connected != controllerConnected
        controllerConnected = connected
        if connected && !prefs.barWithController {
            sleep()
        } else if changed {
            wake()
        }
    }

    /// Shows the bar again and restarts the auto-hide countdown.
    func wake() {
        asleep = false
        applyAlpha(animated: true)
        restartTimer()
    }

    func sleep() {
        if editing { return }
        stopTimer()
        asleep = true
        if expanded {
            expanded = false
            refreshButtons()
        }
        applyAlpha(animated: true)
    }

    /// Stops the timer; call when the player closes.
    func stop() {
        stopTimer()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if asleep { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: - Building

    private func makeBackground() -> UIView {
        let view: UIView
        if prefs.glass {
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        } else {
            view = UIView()
            view.backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        }
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor
        return view
    }

    private func makeButton(for item: Item) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .white
        button.accessibilityLabel = title(for: item)
        button.backgroundColor = item == .close ? UIColor.systemRed.withAlphaComponent(0.6) : UIColor(white: 1, alpha: 0.12)
        if item == .settings {
            // 7.7.0: a tap opens the Game Panel; touch and hold shows the full game menu.
            button.showsMenuAsPrimaryAction = false
            button.menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    self?.stopTimer()
                    completion(self?.menuProvider?() ?? [])
                },
            ])
            button.addAction(UIAction { [weak self] _ in self?.tapped(item) }, for: .touchUpInside)
        } else {
            button.addAction(UIAction { [weak self] _ in self?.tapped(item) }, for: .touchUpInside)
        }
        return button
    }

    private func title(for item: Item) -> String {
        switch item {
        case .close: return "Exit game"
        case .keyboard: return "Keyboard"
        case .gamepad: return "Show or hide on-screen controls"
        case .settings: return "Game Panel (hold for the game menu)"
        case .screenshot: return "Screenshot"
        case .edit: return "Edit controls"
        case .fastForward: return "Fast forward"
        case .cheats: return "Cheat engine"
        }
    }

    private func symbol(for item: Item) -> String {
        switch item {
        case .close: return "xmark"
        case .keyboard: return "keyboard"
        case .gamepad: return gamepadOn ? "gamecontroller.fill" : "gamecontroller"
        case .settings: return "gearshape.fill"
        case .screenshot: return "camera.fill"
        case .edit: return editing ? "checkmark" : "pencil"
        case .fastForward: return "forward.fill"
        case .cheats: return "wand.and.stars"
        }
    }

    private func refreshButtons() {
        let scale = CGFloat(prefs.barScale)
        let config = UIImage.SymbolConfiguration(pointSize: 16 * scale, weight: .semibold)
        for pair in buttons {
            pair.button.setImage(UIImage(systemName: symbol(for: pair.item), withConfiguration: config), for: .normal)
            if pair.item == .fastForward {
                pair.button.backgroundColor = fastForwardOn
                    ? UIColor.systemIndigo.withAlphaComponent(0.85) : UIColor(white: 1, alpha: 0.12)
            }
            if pair.item == .gamepad {
                pair.button.backgroundColor = gamepadOn ? UIColor(red: 0.36, green: 0.25, blue: 0.6, alpha: 0.9) : UIColor(white: 1, alpha: 0.12)
            }
            if pair.item == .edit {
                pair.button.backgroundColor = editing ? UIColor(red: 0.2, green: 0.62, blue: 0.3, alpha: 0.95) : UIColor(white: 1, alpha: 0.12)
            }
            let resting = editing && pair.item != .edit
            pair.button.isEnabled = !resting
            pair.button.alpha = resting ? 0.55 : 1
            setDashedRing(on: pair.button, visible: resting)
        }
        let handleConfig = UIImage.SymbolConfiguration(pointSize: 18 * scale, weight: .bold)
        if iconView.image != nil {
            handle.setImage(nil, for: .normal)
            ringLayer.opacity = expanded ? 1 : 0
            UIView.animate(withDuration: 0.2) {
                self.iconView.transform = self.expanded ? CGAffineTransform(scaleX: 0.86, y: 0.86) : .identity
            }
        } else {
            let handleSymbol = expanded ? "minus" : "square.grid.2x2.fill"
            handle.setImage(UIImage(systemName: handleSymbol, withConfiguration: handleConfig), for: .normal)
        }
    }

    private func setDashedRing(on button: UIButton, visible: Bool) {
        let name = "nexDash"
        let existing = button.layer.sublayers?.first { $0.name == name } as? CAShapeLayer
        if !visible {
            existing?.removeFromSuperlayer()
            return
        }
        let ring = existing ?? CAShapeLayer()
        ring.name = name
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(red: 0.62, green: 0.48, blue: 1, alpha: 1).cgColor
        ring.lineWidth = 2
        ring.lineDashPattern = [5, 4]
        ring.path = UIBezierPath(ovalIn: button.bounds.insetBy(dx: 1, dy: 1)).cgPath
        if existing == nil { button.layer.addSublayer(ring) }
    }

    // MARK: - Layout

    private var safeArea: CGRect {
        bounds.inset(by: safeAreaInsets).insetBy(dx: 4, dy: 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = safeArea
        guard area.width > 0, area.height > 0 else { return }
        let scale = CGFloat(prefs.barScale)
        let handleSize = 46 * scale
        let half = handleSize / 2
        var center = CGPoint(x: area.minX + position.x * area.width, y: area.minY + position.y * area.height)
        center.x = min(max(center.x, area.minX + half), area.maxX - half)
        center.y = min(max(center.y, area.minY + half), area.maxY - half)
        handle.frame = CGRect(x: center.x - half, y: center.y - half, width: handleSize, height: handleSize)
        handle.layer.cornerRadius = half
        handleBackground.frame = handle.bounds
        handleBackground.layer.cornerRadius = half
        let inset = 4 * scale
        let iconTransform = iconView.transform
        iconView.transform = .identity
        iconView.frame = handle.bounds.insetBy(dx: inset, dy: inset)
        iconView.layer.cornerRadius = iconView.bounds.width / 2
        iconView.transform = iconTransform
        ringLayer.frame = handle.bounds
        ringLayer.path = UIBezierPath(ovalIn: handle.bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath

        let size = 40 * scale
        let gap = 6 * scale
        let pad = 5 * scale
        let count = CGFloat(buttons.count)
        let length = count * size + max(count - 1, 0) * gap + pad * 2
        let thickness = size + pad * 2

        var vertical = prefs.verticalDrawer
        if vertical {
            let room = max(handle.frame.minY - bounds.minY, bounds.maxY - handle.frame.maxY) - gap
            if room < length { vertical = false }
        }
        var frame: CGRect
        var towardStart: Bool
        if vertical {
            let below = center.y < area.midY
            towardStart = !below
            let y = below ? handle.frame.maxY + gap : handle.frame.minY - gap - length
            frame = CGRect(x: center.x - thickness / 2, y: y, width: thickness, height: length)
        } else {
            let right = center.x < area.midX
            towardStart = !right
            let x = right ? handle.frame.maxX + gap : handle.frame.minX - gap - length
            frame = CGRect(x: x, y: center.y - thickness / 2, width: length, height: thickness)
        }
        frame.origin.x = min(max(frame.origin.x, bounds.minX + 2), max(bounds.maxX - frame.width - 2, bounds.minX + 2))
        frame.origin.y = min(max(frame.origin.y, bounds.minY + 2), max(bounds.maxY - frame.height - 2, bounds.minY + 2))
        drawer.frame = frame
        drawerBackground.frame = drawer.bounds
        drawerBackground.layer.cornerRadius = thickness / 2

        // The exit button always sits at the far end, away from the handle.
        let ordered = towardStart ? buttons : Array(buttons.reversed())
        for (index, pair) in ordered.enumerated() {
            let offset = pad + CGFloat(index) * (size + gap)
            pair.button.frame = vertical
                ? CGRect(x: pad, y: offset, width: size, height: size)
                : CGRect(x: offset, y: pad, width: size, height: size)
            pair.button.layer.cornerRadius = size / 2
            setDashedRing(on: pair.button, visible: editing && pair.item != .edit)
        }
    }

    // MARK: - Interaction

    private func tapped(_ item: Item) {
        onItem?(item)
        if item == .close || item == .edit || editing {
            stopTimer()
        } else {
            restartTimer()
        }
    }

    @objc private func handleTapped() {
        if asleep {
            wake()
            return
        }
        if editing { return }
        expanded.toggle()
        refreshButtons()
        setNeedsLayout()
        layoutIfNeeded()
        if expanded { drawer.isHidden = false }
        applyAlpha(animated: true)
        restartTimer()
    }

    @objc private func dragHandle(_ gesture: UIPanGestureRecognizer) {
        let area = safeArea
        guard area.width > 0, area.height > 0 else { return }
        if gesture.state == .began {
            stopTimer()
            if asleep { wake() }
        }
        let point = gesture.location(in: self)
        let x = min(max((point.x - area.minX) / area.width, 0), 1)
        let y = min(max((point.y - area.minY) / area.height, 0), 1)
        position = CGPoint(x: x, y: y)
        setNeedsLayout()
        if gesture.state == .ended || gesture.state == .cancelled {
            savePosition()
            restartTimer()
        }
    }

    private func applyAlpha(animated: Bool) {
        let level: CGFloat = asleep ? 0 : CGFloat(prefs.barOpacity)
        let drawerLevel: CGFloat = expanded ? level : 0
        let changes = {
            self.handle.alpha = level
            self.drawer.alpha = drawerLevel
        }
        let done: (Bool) -> Void = { _ in
            self.drawer.isHidden = !self.expanded
        }
        if animated {
            UIView.animate(withDuration: 0.22, animations: changes, completion: done)
        } else {
            changes()
            done(true)
        }
    }

    private func restartTimer() {
        stopTimer()
        guard prefs.autoHide, !controllerConnected, !editing else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        }
    }

    private func stopTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func loadPosition() {
        if let values = UserDefaults.standard.array(forKey: SettingsKey.barPosition) as? [Double], values.count == 2 {
            position = CGPoint(x: min(max(values[0], 0), 1), y: min(max(values[1], 0), 1))
        }
    }

    private func savePosition() {
        UserDefaults.standard.set([Double(position.x), Double(position.y)], forKey: SettingsKey.barPosition)
    }
}

/// A hidden text field that turns typing into key presses for the game (name entry, chat boxes, console plugins).
/// Letters, digits, space, Enter and Backspace become the matching keyboard keys.
final class KeySenderField: UITextField {
    var onKey: ((PadKey) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardAppearance = .dark
        returnKeyType = .default
        alpha = 0.02
        tintColor = .clear
        textColor = .clear
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { fatalError() }

    override func insertText(_ text: String) {
        for character in text {
            onKey?(KeySenderField.key(for: character))
        }
    }

    override func deleteBackward() {
        onKey?(.backspace)
    }

    static func key(for character: Character) -> PadKey {
        if character == "\n" || character == "\r" { return .enter }
        if character == " " { return .space }
        let text = String(character)
        if let ascii = character.asciiValue {
            if (97...122).contains(ascii) {
                return PadKey(keyCode: Int(ascii) - 32, key: text, code: "Key" + text.uppercased())
            }
            if (65...90).contains(ascii) {
                return PadKey(keyCode: Int(ascii), key: text, code: "Key" + text)
            }
            if (48...57).contains(ascii) {
                return PadKey.fromKeyCode(Int(ascii))
            }
        }
        return PadKey(keyCode: 0, key: text, code: "")
    }
}
