import UIKit

// Touch handling ideas (press on touch-down, eight sectors for sticks, shared-key refcount in the player's KeyRouter)
// follow Empo's ControlTouchCapture.swift and GameControls.swift.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).
// The look and the edit mode (dashed yellow frames with move arrows, green add and orange reset buttons, a red
// delete badge and a resize grip on the selected control, a full Edit Button page) follow RPGPlayer's screenshots;
// the code is NexPlay's own.

enum PadStyle {
    static let fill = UIColor(white: 0.1, alpha: 0.78)
    static let border = UIColor(white: 1, alpha: 0.22)
    static let knob = UIColor(red: 0.36, green: 0.25, blue: 0.6, alpha: 1)
    static let knobRing = UIColor(red: 0.6, green: 0.48, blue: 0.9, alpha: 1)
    static let editYellow = UIColor(red: 0.98, green: 0.8, blue: 0.12, alpha: 1)

    static func color(_ raw: String?) -> UIColor? {
        guard let raw, let tint = ControlColor(rawValue: raw) else { return nil }
        let rgb = tint.rgb
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}

/// One on-screen control: a button, a D-pad or a joystick. Each control handles its own touches,
/// so several fingers can press several controls at once.
final class ControlView: UIView {
    private(set) var item: ControlItem
    var onKey: ((PadKey, Bool) -> Void)?
    var onAction: ((ControlAction, Bool) -> Void)?
    var onPress: (() -> Void)?
    var isEditing = false {
        didSet {
            if isEditing { release() }
            updateLook()
        }
    }
    var isSelected = false {
        didSet { updateLook() }
    }

    private let label = UILabel()
    private let knob = UIView()
    private let ticks = CAShapeLayer()
    private let dash = CAShapeLayer()
    private let moveIcon = UIImageView()
    private var arrows: [Int: UILabel] = [:]
    private var pressed = false
    private var activeDirections: Set<Int> = []
    private var trackedTouch: UITouch?

    init(item: ControlItem) {
        self.item = item
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        layer.borderWidth = 1.5
        layer.borderColor = PadStyle.border.cgColor
        isAccessibilityElement = true

        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.4
        label.isUserInteractionEnabled = false
        addSubview(label)

        ticks.strokeColor = UIColor(white: 1, alpha: 0.28).cgColor
        ticks.lineWidth = 2
        ticks.lineCap = .round
        layer.addSublayer(ticks)

        if item.action == .dpad {
            let symbols: [(Int, String)] = [(38, "▲"), (40, "▼"), (37, "◀"), (39, "▶")]
            for (code, symbol) in symbols {
                let arrow = UILabel()
                arrow.text = symbol
                arrow.textColor = UIColor(white: 1, alpha: 0.6)
                arrow.font = .systemFont(ofSize: 20)
                arrow.textAlignment = .center
                addSubview(arrow)
                arrows[code] = arrow
            }
        }
        if item.action == .joystick {
            knob.backgroundColor = PadStyle.knob
            knob.layer.borderColor = PadStyle.knobRing.cgColor
            knob.layer.borderWidth = 3
            knob.isUserInteractionEnabled = false
            addSubview(knob)
        }

        dash.fillColor = UIColor(red: 0.98, green: 0.8, blue: 0.12, alpha: 0.07).cgColor
        dash.strokeColor = PadStyle.editYellow.cgColor
        dash.lineWidth = 3
        dash.lineDashPattern = [10, 7]
        dash.isHidden = true
        layer.addSublayer(dash)
        moveIcon.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right",
                                 withConfiguration: UIImage.SymbolConfiguration(weight: .heavy))
        moveIcon.tintColor = PadStyle.editYellow
        moveIcon.contentMode = .scaleAspectFit
        moveIcon.isHidden = true
        moveIcon.isUserInteractionEnabled = false
        addSubview(moveIcon)
        apply(item)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ newItem: ControlItem) {
        item = newItem
        label.text = item.action.isDirectional ? "" : item.displayLabel
        accessibilityLabel = item.action.isDirectional ? item.action.title : item.displayLabel
        alpha = CGFloat(item.opacity)
        isHidden = item.hidden
        updateLook()
        setNeedsLayout()
    }

    private var baseFill: UIColor {
        PadStyle.color(item.color)?.withAlphaComponent(0.82) ?? PadStyle.fill
    }

    private func updateLook() {
        let editingFrame = isEditing && !isSelected
        dash.isHidden = !editingFrame
        moveIcon.isHidden = !editingFrame
        label.alpha = editingFrame ? 0.45 : 1
        knob.alpha = editingFrame ? 0.5 : 1
        backgroundColor = pressed ? baseFill.withAlphaComponent(1).blended(with: .white, amount: 0.25) : baseFill
        layer.borderColor = (isEditing && isSelected) ? UIColor.white.cgColor : PadStyle.border.cgColor
        layer.borderWidth = (isEditing && isSelected) ? 2.5 : 1.5
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width
        layer.cornerRadius = side / 2
        label.frame = bounds.insetBy(dx: side * 0.12, dy: side * 0.12)
        label.font = NexFont.ui(max(12, min(26, side * 0.3)))
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if item.action == .dpad {
            let size: CGFloat = 36
            let r = side / 2 - 26
            arrows[38]?.frame = CGRect(x: c.x - size / 2, y: c.y - r - size / 2, width: size, height: size)
            arrows[40]?.frame = CGRect(x: c.x - size / 2, y: c.y + r - size / 2, width: size, height: size)
            arrows[37]?.frame = CGRect(x: c.x - r - size / 2, y: c.y - size / 2, width: size, height: size)
            arrows[39]?.frame = CGRect(x: c.x + r - size / 2, y: c.y - size / 2, width: size, height: size)
        }
        if item.action == .joystick {
            let path = UIBezierPath()
            let outer = side / 2 - 8
            let inner = outer - side * 0.1
            for angle in [0.0, Double.pi / 2, Double.pi, Double.pi * 1.5] {
                let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
                path.move(to: CGPoint(x: c.x + dx * inner, y: c.y + dy * inner))
                path.addLine(to: CGPoint(x: c.x + dx * outer, y: c.y + dy * outer))
            }
            ticks.path = path.cgPath
            if trackedTouch == nil {
                let k = side * 0.44
                knob.frame = CGRect(x: c.x - k / 2, y: c.y - k / 2, width: k, height: k)
                knob.layer.cornerRadius = k / 2
            }
        } else {
            ticks.path = nil
        }
        let inset: CGFloat = -6
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerRadius: side * 0.28).cgPath
        let icon = side * 0.36
        moveIcon.frame = CGRect(x: c.x - icon / 2, y: c.y - icon / 2, width: icon, height: icon)
    }

    // MARK: - Play touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isEditing, let touch = touches.first else { return }
        trackedTouch = touch
        if item.action.isDirectional {
            updateDirections(touch.location(in: self))
        } else {
            setPressed(true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isEditing, let touch = trackedTouch, touches.contains(touch) else { return }
        if item.action.isDirectional { updateDirections(touch.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        release()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    func release() {
        trackedTouch = nil
        if item.action.isDirectional {
            updateDirections(nil)
            UIView.animate(withDuration: 0.12) { self.setNeedsLayout(); self.layoutIfNeeded() }
        } else {
            setPressed(false)
        }
    }

    private func setPressed(_ value: Bool) {
        guard value != pressed else { return }
        pressed = value
        updateLook()
        UIView.animate(withDuration: 0.08) {
            self.transform = value ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
        }
        if value { onPress?() }
        if let key = item.padKey {
            onKey?(key, value)
        } else if item.action.isAppAction {
            onAction?(item.action, value)
        }
    }

    /// Eight sectors (or four) around the center, with a dead zone in the middle.
    private func updateDirections(_ point: CGPoint?) {
        var want = Set<Int>()
        if let p = point {
            let dx = p.x - bounds.midX
            let dy = p.y - bounds.midY
            let distance = hypot(dx, dy)
            if item.action == .joystick {
                let limit = bounds.width / 2 - knob.bounds.width / 4
                let scale = distance > limit && distance > 0 ? limit / distance : 1
                knob.center = CGPoint(x: bounds.midX + dx * scale, y: bounds.midY + dy * scale)
            }
            if distance > bounds.width * 0.12 {
                let angle = atan2(-dy, dx)
                let eight = item.eightWay ?? true
                let step = eight ? Double.pi / 4 : Double.pi / 2
                var sector = Int((Double(angle) / step).rounded())
                let count = eight ? 8 : 4
                sector = ((sector % count) + count) % count
                let index = eight ? sector : sector * 2
                // 0 right, 1 up-right, 2 up, 3 up-left, 4 left, 5 down-left, 6 down, 7 down-right
                switch index {
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
        }
        let keys = item.directionKeys
        if !want.isEmpty && activeDirections.isEmpty { onPress?() }
        for code in activeDirections.subtracting(want) { if let k = keys[code] { onKey?(k, false) } }
        for code in want.subtracting(activeDirections) { if let k = keys[code] { onKey?(k, true) } }
        activeDirections = want
        for (code, arrow) in arrows {
            arrow.textColor = UIColor(white: 1, alpha: want.contains(code) ? 1 : 0.6)
        }
    }
}

private extension UIColor {
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: a1)
    }
}

/// Transparent layer over the game with the on-screen controls. Touches outside the controls reach the game.
/// Layouts come from a `LayoutProfile`; portrait and landscape have their own lists.
///
/// Edit mode: every control shows a dashed yellow frame with move arrows; drag to move. Tap one to select it (red
/// delete badge, resize grip), tap it again to open the Edit Button page. The green + adds a control, the orange
/// arrow resets the layout. The control bar's check mark (in the player) ends editing and saves.
final class GamepadOverlayView: UIView {
    var onKey: ((PadKey, Bool) -> Void)?
    var onAction: ((ControlAction, Bool) -> Void)?
    /// Called with the edited profile when editing ends with saving.
    var onSave: ((LayoutProfile) -> Void)?
    /// Called when the user resets the layout in edit mode; returns the profile to show.
    var onReset: (() -> LayoutProfile)?
    var onEditingChanged: ((Bool) -> Void)?
    /// Opens the Edit Button page for a control; the completion gets the changed control, or nil to delete it.
    var onEditItem: ((ControlItem, @escaping (ControlItem?) -> Void) -> Void)?
    /// Asks the player to confirm the reset (shows an alert); the closure resets.
    var onConfirmReset: ((@escaping () -> Void) -> Void)?
    /// 7.3.0: the layout for a preset, ready to show (global pad size applied).
    var onPreset: ((LayoutPreset) -> LayoutProfile)?

    private(set) var profile: LayoutProfile = .builtIn
    private var views: [UUID: ControlView] = [:]
    private var shownLandscape: Bool?
    private var haptic: UIImpactFeedbackGenerator?
    private let selection = UISelectionFeedbackGenerator()

    // Edit mode
    private(set) var isEditing = false
    private var selectedID: UUID?
    private var startProfile: LayoutProfile?
    private let addButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let deleteBadge = UIButton(type: .system)
    private let resizeGrip = UIButton(type: .system)
    private let hint = UILabel()
    private var resizeStart: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        buildEditChrome()
        configureHaptics()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configureHaptics() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.hapticsEnabled) else {
            haptic = nil
            return
        }
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch defaults.integer(forKey: SettingsKey.hapticStrength) {
        case 0: style = .light
        case 2: style = .heavy
        default: style = .medium
        }
        haptic = UIImpactFeedbackGenerator(style: style)
        haptic?.prepare()
    }

    private var isLandscape: Bool { bounds.width > bounds.height }

    private var area: CGRect { bounds.inset(by: safeAreaInsets) }

    func setProfile(_ newProfile: LayoutProfile) {
        profile = newProfile
        shownLandscape = nil
        setNeedsLayout()
    }

    private var currentItems: [ControlItem] {
        profile.items(landscape: isLandscape)
    }

    /// Rebuilds the control views for the current orientation.
    private func rebuild() {
        releaseAll()
        views.values.forEach { $0.removeFromSuperview() }
        views = [:]
        for item in currentItems {
            let control = ControlView(item: item)
            control.onKey = { [weak self] key, down in self?.onKey?(key, down) }
            control.onAction = { [weak self] action, down in self?.onAction?(action, down) }
            control.onPress = { [weak self] in self?.haptic?.impactOccurred() }
            control.isEditing = isEditing
            control.isSelected = item.id == selectedID
            if isEditing { addEditGestures(to: control) }
            insertSubview(control, belowSubview: hint)
            views[item.id] = control
        }
        bringEditChromeToFront()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if shownLandscape != isLandscape {
            shownLandscape = isLandscape
            selectedID = nil
            rebuild()
        }
        let rect = area
        for item in currentItems {
            guard let control = views[item.id] else { continue }
            let size = CGFloat(item.size)
            let transform = control.transform
            control.transform = .identity
            control.frame = CGRect(x: rect.minX + CGFloat(item.x) * rect.width - size / 2,
                                   y: rect.minY + CGFloat(item.y) * rect.height - size / 2,
                                   width: size, height: size)
            control.transform = transform
        }
        layoutEditChrome()
    }

    func releaseAll() {
        views.values.forEach { $0.release() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if isEditing { return view }
        return view === self ? nil : view
    }

    // MARK: - Edit chrome

    private func circle(_ button: UIButton, symbol: String, color: UIColor, size: CGFloat) {
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.42, weight: .heavy)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.backgroundColor = color
        button.layer.cornerRadius = size / 2
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 3)
        button.isHidden = true
    }

    private func buildEditChrome() {
        circle(addButton, symbol: "plus", color: UIColor(red: 0.2, green: 0.72, blue: 0.33, alpha: 1), size: 56)
        addButton.accessibilityLabel = "Add a button"
        addButton.showsMenuAsPrimaryAction = true
        circle(resetButton, symbol: "arrow.counterclockwise", color: UIColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1), size: 56)
        resetButton.accessibilityLabel = "Reset layout"
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        circle(deleteBadge, symbol: "xmark", color: UIColor(red: 0.9, green: 0.22, blue: 0.24, alpha: 1), size: 30)
        deleteBadge.layer.borderColor = UIColor.white.cgColor
        deleteBadge.layer.borderWidth = 2
        deleteBadge.accessibilityLabel = "Delete this button"
        deleteBadge.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        circle(resizeGrip, symbol: "arrow.up.left.and.arrow.down.right", color: UIColor(white: 0.15, alpha: 0.9), size: 30)
        resizeGrip.layer.borderColor = UIColor.white.cgColor
        resizeGrip.layer.borderWidth = 2
        resizeGrip.accessibilityLabel = "Drag to resize"
        resizeGrip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resizeDrag(_:))))

        hint.font = NexFont.ui(12)
        hint.textColor = UIColor(white: 1, alpha: 0.85)
        hint.textAlignment = .center
        hint.numberOfLines = 2
        hint.isHidden = true
        hint.isUserInteractionEnabled = false
        hint.text = "Drag to move · tap to select · tap again to edit"

        [hint, addButton, resetButton, deleteBadge, resizeGrip].forEach { addSubview($0) }
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    private func bringEditChromeToFront() {
        [hint, addButton, resetButton, deleteBadge, resizeGrip].forEach { bringSubviewToFront($0) }
    }

    private func layoutEditChrome() {
        let rect = area
        let size: CGFloat = 56
        let gap: CGFloat = 16
        let top = rect.minY + 10
        addButton.frame = CGRect(x: rect.midX - size - gap / 2, y: top, width: size, height: size)
        resetButton.frame = CGRect(x: rect.midX + gap / 2, y: top, width: size, height: size)
        hint.frame = CGRect(x: rect.midX - 180, y: top + size + 6, width: 360, height: 32)

        if isEditing, let id = selectedID, let control = views[id] {
            let frame = control.frame
            deleteBadge.isHidden = false
            resizeGrip.isHidden = false
            deleteBadge.frame = CGRect(x: frame.minX - 10, y: frame.minY - 10, width: 30, height: 30)
            resizeGrip.frame = CGRect(x: frame.maxX - 20, y: frame.minY - 10, width: 30, height: 30)
        } else {
            deleteBadge.isHidden = true
            resizeGrip.isHidden = true
        }
    }

    // MARK: - Edit mode

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        isHidden = false
        startProfile = profile
        selectedID = nil
        backgroundColor = UIColor(white: 0, alpha: 0.28)
        addButton.isHidden = false
        resetButton.isHidden = false
        hint.isHidden = false
        addButton.menu = addMenu()
        rebuild()
        setNeedsLayout()
        onEditingChanged?(true)
    }

    func endEditing(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        selectedID = nil
        backgroundColor = .clear
        addButton.isHidden = true
        resetButton.isHidden = true
        deleteBadge.isHidden = true
        resizeGrip.isHidden = true
        hint.isHidden = true
        if !save, let start = startProfile { profile = start }
        startProfile = nil
        rebuild()
        setNeedsLayout()
        if save { onSave?(profile) }
        onEditingChanged?(false)
    }

    private func addEditGestures(to control: ControlView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragControl(_:)))
        control.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapControl(_:)))
        control.addGestureRecognizer(tap)
    }

    private func change(_ id: UUID, _ edit: (inout ControlItem) -> Void) {
        var items = currentItems
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[index])
        profile.setItems(items, landscape: isLandscape)
        views[id]?.apply(items[index])
        setNeedsLayout()
    }

    private func select(_ id: UUID?) {
        if id != selectedID { selection.selectionChanged() }
        selectedID = id
        for (key, control) in views { control.isSelected = key == id }
        setNeedsLayout()
    }

    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        guard isEditing else { return }
        let point = gesture.location(in: self)
        if views.values.contains(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }) { return }
        if deleteBadge.frame.contains(point) || resizeGrip.frame.contains(point) { return }
        select(nil)
    }

    @objc private func tapControl(_ gesture: UITapGestureRecognizer) {
        guard let control = gesture.view as? ControlView else { return }
        let id = control.item.id
        if selectedID == id {
            openEditor(id)
        } else {
            select(id)
        }
    }

    private func openEditor(_ id: UUID) {
        guard let item = currentItems.first(where: { $0.id == id }) else { return }
        onEditItem?(item) { [weak self] result in
            guard let self else { return }
            if let result {
                self.change(id) { $0 = result }
                self.views[id]?.removeFromSuperview()
                self.rebuild()
            } else {
                self.remove(id)
            }
            self.setNeedsLayout()
        }
    }

    @objc private func dragControl(_ gesture: UIPanGestureRecognizer) {
        guard let control = gesture.view as? ControlView else { return }
        let id = control.item.id
        if gesture.state == .began { select(id) }
        let rect = area
        guard rect.width > 0, rect.height > 0 else { return }
        let point = gesture.location(in: self)
        var x = Double((point.x - rect.minX) / rect.width)
        var y = Double((point.y - rect.minY) / rect.height)
        if gesture.state == .ended || gesture.state == .cancelled {
            x = (x * 80).rounded() / 80
            y = (y * 80).rounded() / 80
        }
        x = min(max(x, 0), 1)
        y = min(max(y, 0), 1)
        change(id) { $0.x = x; $0.y = y }
    }

    @objc private func resizeDrag(_ gesture: UIPanGestureRecognizer) {
        guard let id = selectedID, let control = views[id] else { return }
        if gesture.state == .began { resizeStart = control.item.size }
        let point = gesture.location(in: self)
        let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
        let distance = Double(max(abs(point.x - center.x), abs(point.y - center.y)))
        let size = min(max(distance * 2, 36), 260)
        change(id) { $0.size = size.rounded() }
    }

    @objc private func deleteTapped() {
        guard let id = selectedID else { return }
        remove(id)
    }

    private func remove(_ id: UUID) {
        var items = currentItems
        items.removeAll { $0.id == id }
        profile.setItems(items, landscape: isLandscape)
        selectedID = nil
        rebuild()
        setNeedsLayout()
        addButton.menu = addMenu()
    }

    @objc private func resetTapped() {
        let reset = { [weak self] in
            guard let self, let fresh = self.onReset?() else { return }
            self.profile = fresh
            self.selectedID = nil
            self.rebuild()
            self.setNeedsLayout()
        }
        if let confirm = onConfirmReset { confirm(reset) } else { reset() }
    }

    private func addMenu() -> UIMenu {
        let full = currentItems.count >= LayoutProfile.maxControls
        func entry(_ title: String, _ symbol: String, _ action: ControlAction, _ keyCode: Int? = nil, _ label: String? = nil) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: full ? .disabled : []) { [weak self] _ in
                self?.add(action, keyCode: keyCode, label: label)
            }
        }
        let main: [UIMenuElement] = [
            entry("Button", "circle.fill", .key, 13, "Btn"),
            entry("Joystick", "circle.circle", .joystick),
            entry("D-Pad", "dpad", .dpad),
        ]
        let actions: [UIMenuElement] = [
            entry("OK", "checkmark.circle", .confirm),
            entry("Cancel", "xmark.circle", .cancel),
            entry("Menu", "line.3.horizontal", .menu),
            entry("Dash", "hare", .dash),
            entry("Fast Forward", "forward", .fastForward),
            entry("Scroll Up", "arrow.up.to.line", .scrollUp),
            entry("Scroll Down", "arrow.down.to.line", .scrollDown),
        ]
        let mouse: [UIMenuElement] = [
            entry("Left Click", "cursorarrow.click", .mouseLeft),
            entry("Right Click", "cursorarrow.click.2", .mouseRight),
        ]
        let app: [UIMenuElement] = [
            entry("Quick Save", "bolt.circle", .quickSave),
            entry("Quick Load", "bolt.horizontal.circle", .quickLoad),
            entry("Game Panel", "square.grid.2x2", .gamePanel),
            entry("Show Keyboard", "keyboard", .showKeyboard),
        ]
        let presets: [UIMenuElement] = LayoutPreset.allCases.map { preset in
            UIAction(title: preset.title, image: UIImage(systemName: preset.symbol)) { [weak self] _ in
                self?.usePreset(preset)
            }
        }
        return UIMenu(title: full ? "Up to \(LayoutProfile.maxControls) controls" : "Add",
                      children: [UIMenu(options: .displayInline, children: main),
                                 UIMenu(title: "Game Action", image: UIImage(systemName: "gamecontroller"), children: actions),
                                 UIMenu(title: "Mouse", image: UIImage(systemName: "computermouse"), children: mouse),
                                 UIMenu(title: "NexPlay", image: UIImage(systemName: "square.grid.2x2"), children: app),
                                 UIMenu(title: "Presets", image: UIImage(systemName: "square.on.square"), children: presets)])
    }

    /// Edit mode: replaces both orientations with a preset (Done saves it, the reset arrow undoes it).
    private func usePreset(_ preset: LayoutPreset) {
        guard let fresh = onPreset?(preset) else { return }
        profile = fresh
        selectedID = nil
        rebuild()
        setNeedsLayout()
        addButton.menu = addMenu()
        haptic?.impactOccurred()
    }

    /// Outside edit mode (Game Panel): shows a preset and saves it as the game's layout.
    func applyPreset(_ preset: LayoutPreset) {
        guard !isEditing, let fresh = onPreset?(preset) else { return }
        profile = fresh
        shownLandscape = nil
        setNeedsLayout()
        onSave?(fresh)
    }

    private func add(_ action: ControlAction, keyCode: Int?, label: String?) {
        guard currentItems.count < LayoutProfile.maxControls else { return }
        let size: Double = action.isDirectional ? 150 : 62
        var item = ControlItem(action: action, keyCode: keyCode, x: 0.5, y: 0.5, size: size, label: label)
        if action == .key { item.color = ControlColor.red.rawValue }
        var items = currentItems
        items.append(item)
        profile.setItems(items, landscape: isLandscape)
        selectedID = item.id
        rebuild()
        setNeedsLayout()
        addButton.menu = addMenu()
        haptic?.impactOccurred()
    }
}
