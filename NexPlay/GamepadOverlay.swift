import UIKit

// Touch handling ideas (press on touch-down, eight sectors for sticks, shared-key refcount in the player's KeyRouter)
// follow Empo's ControlTouchCapture.swift and GameControls.swift.
// Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

/// One on-screen control: a button, a D-pad or a joystick. Each control handles its own touches,
/// so several fingers can press several controls at once.
final class ControlView: UIView {
    private(set) var item: ControlItem
    var onKey: ((PadKey, Bool) -> Void)?
    var onAction: ((ControlAction, Bool) -> Void)?
    var onPress: (() -> Void)?
    var isEditing = false {
        didSet { if isEditing { release() } }
    }
    var isSelected = false {
        didSet { updateLook() }
    }

    private let label = UILabel()
    private let knob = UIView()
    private var arrows: [Int: UILabel] = [:]
    private var pressed = false
    private var activeDirections: Set<Int> = []
    private var trackedTouch: UITouch?

    init(item: ControlItem) {
        self.item = item
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        backgroundColor = UIColor(white: 1, alpha: 0.14)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor(white: 1, alpha: 0.5).cgColor
        isAccessibilityElement = true
        accessibilityLabel = item.action.isDirectional ? item.action.title : item.displayLabel

        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)

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
            knob.backgroundColor = UIColor(white: 1, alpha: 0.45)
            knob.isUserInteractionEnabled = false
            addSubview(knob)
        }
        apply(item)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ newItem: ControlItem) {
        item = newItem
        label.text = item.action.isDirectional ? "" : item.displayLabel
        alpha = CGFloat(item.opacity)
        isHidden = item.hidden
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        label.frame = bounds.insetBy(dx: 6, dy: 6)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if item.action == .dpad {
            let size: CGFloat = 36
            let r = bounds.width / 2 - 26
            arrows[38]?.frame = CGRect(x: c.x - size / 2, y: c.y - r - size / 2, width: size, height: size)
            arrows[40]?.frame = CGRect(x: c.x - size / 2, y: c.y + r - size / 2, width: size, height: size)
            arrows[37]?.frame = CGRect(x: c.x - r - size / 2, y: c.y - size / 2, width: size, height: size)
            arrows[39]?.frame = CGRect(x: c.x + r - size / 2, y: c.y - size / 2, width: size, height: size)
        }
        if item.action == .joystick && trackedTouch == nil {
            let k = bounds.width * 0.42
            knob.frame = CGRect(x: c.x - k / 2, y: c.y - k / 2, width: k, height: k)
            knob.layer.cornerRadius = k / 2
        }
    }

    private func updateLook() {
        layer.borderColor = isSelected ? UIColor.systemYellow.cgColor : UIColor(white: 1, alpha: 0.5).cgColor
        layer.borderWidth = isSelected ? 3 : 1.5
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
            setNeedsLayout()
        } else {
            setPressed(false)
        }
    }

    private func setPressed(_ value: Bool) {
        guard value != pressed else { return }
        pressed = value
        backgroundColor = UIColor(white: 1, alpha: value ? 0.45 : 0.14)
        if value { onPress?() }
        if item.action == .fastForward {
            onAction?(.fastForward, value)
        } else if let key = item.padKey {
            onKey?(key, value)
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
        let keys: [Int: PadKey] = [37: .left, 38: .up, 39: .right, 40: .down]
        if !want.isEmpty && activeDirections.isEmpty { onPress?() }
        for code in activeDirections.subtracting(want) { if let k = keys[code] { onKey?(k, false) } }
        for code in want.subtracting(activeDirections) { if let k = keys[code] { onKey?(k, true) } }
        activeDirections = want
        for (code, arrow) in arrows {
            arrow.textColor = UIColor(white: 1, alpha: want.contains(code) ? 1 : 0.6)
        }
    }
}

/// Transparent layer over the game with the on-screen controls. Touches outside the controls reach the game.
/// Layouts come from a `LayoutProfile`; portrait and landscape have their own lists.
final class GamepadOverlayView: UIView {
    var onKey: ((PadKey, Bool) -> Void)?
    var onAction: ((ControlAction, Bool) -> Void)?
    /// Called with the edited profile when the user taps Done in edit mode.
    var onSave: ((LayoutProfile) -> Void)?
    /// Called when the user resets the layout in edit mode; returns the profile to show.
    var onReset: (() -> LayoutProfile)?
    var onEditingChanged: ((Bool) -> Void)?

    private(set) var profile: LayoutProfile = .builtIn
    private var views: [UUID: ControlView] = [:]
    private var shownLandscape: Bool?
    private var haptic: UIImpactFeedbackGenerator?

    // Edit mode
    private(set) var isEditing = false
    private var selectedID: UUID?
    private var undoStack: [LayoutProfile] = []
    private var gridSnap = true
    private let editBar = EditBar()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        editBar.isHidden = true
        addSubview(editBar)
        wireEditBar()
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
            insertSubview(control, belowSubview: editBar)
            views[item.id] = control
        }
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
            control.frame = CGRect(x: rect.minX + CGFloat(item.x) * rect.width - size / 2,
                                   y: rect.minY + CGFloat(item.y) * rect.height - size / 2,
                                   width: size, height: size)
        }
        let barHeight = editBar.preferredHeight(hasSelection: selectedID != nil)
        editBar.frame = CGRect(x: rect.minX + 8, y: rect.minY + 8, width: rect.width - 16, height: barHeight)
    }

    func releaseAll() {
        views.values.forEach { $0.release() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if isEditing { return view }
        return view === self ? nil : view
    }

    // MARK: - Edit mode

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        isHidden = false
        undoStack = []
        selectedID = nil
        editBar.isHidden = false
        backgroundColor = UIColor(white: 0, alpha: 0.25)
        rebuild()
        refreshEditBar()
        onEditingChanged?(true)
    }

    func endEditing(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        selectedID = nil
        editBar.isHidden = true
        backgroundColor = .clear
        rebuild()
        if save { onSave?(profile) }
        onEditingChanged?(false)
    }

    private func addEditGestures(to control: ControlView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragControl(_:)))
        control.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapControl(_:)))
        control.addGestureRecognizer(tap)
    }

    private func pushUndo() {
        undoStack.append(profile)
        if undoStack.count > 50 { undoStack.removeFirst() }
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
        selectedID = id
        for (key, control) in views { control.isSelected = key == id }
        refreshEditBar()
        setNeedsLayout()
    }

    @objc private func tapControl(_ gesture: UITapGestureRecognizer) {
        guard let control = gesture.view as? ControlView else { return }
        select(control.item.id)
    }

    @objc private func dragControl(_ gesture: UIPanGestureRecognizer) {
        guard let control = gesture.view as? ControlView else { return }
        let id = control.item.id
        if gesture.state == .began {
            pushUndo()
            select(id)
        }
        let rect = area
        guard rect.width > 0, rect.height > 0 else { return }
        let point = gesture.location(in: self)
        var x = Double((point.x - rect.minX) / rect.width)
        var y = Double((point.y - rect.minY) / rect.height)
        if gridSnap && (gesture.state == .ended || gesture.state == .cancelled) {
            x = (x * 40).rounded() / 40
            y = (y * 40).rounded() / 40
        }
        x = min(max(x, 0), 1)
        y = min(max(y, 0), 1)
        change(id) { $0.x = x; $0.y = y }
    }

    private var selectedItem: ControlItem? {
        guard let id = selectedID else { return nil }
        return currentItems.first { $0.id == id }
    }

    private func refreshEditBar() {
        editBar.update(selected: selectedItem, canUndo: !undoStack.isEmpty, gridSnap: gridSnap,
                       count: currentItems.count)
        editBar.addButton.menu = addMenu()
    }

    private func addMenu() -> UIMenu {
        let actions: [ControlAction] = [.dpad, .joystick, .confirm, .cancel, .menu, .dash, .pageUp, .pageDown, .fastForward]
        var children: [UIMenuElement] = actions.map { action in
            UIAction(title: action.title) { [weak self] _ in self?.add(action, keyCode: nil) }
        }
        let keys = PadKey.choosable.map { key in
            UIAction(title: key.title) { [weak self] _ in self?.add(.key, keyCode: key.keyCode) }
        }
        children.append(UIMenu(title: "Keyboard Key", children: keys))
        return UIMenu(title: "Add Control", children: children)
    }

    private func add(_ action: ControlAction, keyCode: Int?) {
        guard currentItems.count < LayoutProfile.maxControls else { return }
        pushUndo()
        let size: Double = action.isDirectional ? 150 : 58
        let item = ControlItem(action: action, keyCode: keyCode, x: 0.5, y: 0.5, size: size)
        var items = currentItems
        items.append(item)
        profile.setItems(items, landscape: isLandscape)
        selectedID = item.id
        rebuild()
        refreshEditBar()
        setNeedsLayout()
    }

    private func wireEditBar() {
        editBar.onDone = { [weak self] in self?.endEditing(save: true) }
        editBar.onCancel = { [weak self] in
            guard let self else { return }
            if let first = self.undoStack.first { self.profile = first }
            self.endEditing(save: false)
        }
        editBar.onUndo = { [weak self] in
            guard let self, let last = self.undoStack.popLast() else { return }
            self.profile = last
            self.selectedID = nil
            self.rebuild()
            self.refreshEditBar()
            self.setNeedsLayout()
        }
        editBar.onReset = { [weak self] in
            guard let self, let fresh = self.onReset?() else { return }
            self.pushUndo()
            self.profile = fresh
            self.selectedID = nil
            self.rebuild()
            self.refreshEditBar()
            self.setNeedsLayout()
        }
        editBar.onSnap = { [weak self] value in
            self?.gridSnap = value
            self?.refreshEditBar()
        }
        editBar.onSizeBegan = { [weak self] in self?.pushUndo() }
        editBar.onSize = { [weak self] value in
            guard let self, let id = self.selectedID else { return }
            self.change(id) { $0.size = value }
        }
        editBar.onOpacityBegan = { [weak self] in self?.pushUndo() }
        editBar.onOpacity = { [weak self] value in
            guard let self, let id = self.selectedID else { return }
            self.change(id) { $0.opacity = value }
        }
        editBar.onDelete = { [weak self] in
            guard let self, let id = self.selectedID else { return }
            self.pushUndo()
            var items = self.currentItems
            items.removeAll { $0.id == id }
            self.profile.setItems(items, landscape: self.isLandscape)
            self.selectedID = nil
            self.rebuild()
            self.refreshEditBar()
            self.setNeedsLayout()
        }
        editBar.onLabel = { [weak self] in self?.askLabel() }
        editBar.onDirections = { [weak self] in
            guard let self, let id = self.selectedID else { return }
            self.pushUndo()
            self.change(id) { $0.eightWay = !($0.eightWay ?? true) }
            self.refreshEditBar()
        }
    }

    private func askLabel() {
        guard let item = selectedItem, let host = window?.rootViewController else { return }
        var top = host
        while let next = top.presentedViewController { top = next }
        let alert = UIAlertController(title: "Label", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = item.displayLabel }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let text = alert?.textFields?.first?.text ?? ""
            self.pushUndo()
            self.change(item.id) { $0.label = text.isEmpty ? nil : String(text.prefix(8)) }
            self.refreshEditBar()
        })
        top.present(alert, animated: true)
    }
}

/// The bar shown at the top in edit mode.
final class EditBar: UIView {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onReset: (() -> Void)?
    var onSnap: ((Bool) -> Void)?
    var onSize: ((Double) -> Void)?
    var onSizeBegan: (() -> Void)?
    var onOpacity: ((Double) -> Void)?
    var onOpacityBegan: (() -> Void)?
    var onDelete: (() -> Void)?
    var onLabel: (() -> Void)?
    var onDirections: (() -> Void)?

    let addButton = UIButton(type: .system)
    private let topRow = UIStackView()
    private let itemRow = UIStackView()
    private let undoButton = UIButton(type: .system)
    private let snapButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private let sizeSlider = UISlider()
    private let opacitySlider = UISlider()
    private let labelButton = UIButton(type: .system)
    private let directionsButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var gridSnap = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 0.92)
        layer.cornerRadius = 14
        tintColor = .white

        func button(_ button: UIButton, _ symbol: String, _ title: String, _ action: Selector) {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = title
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        let cancel = UIButton(type: .system)
        button(cancel, "xmark", "Cancel", #selector(cancelTapped))
        addButton.setImage(UIImage(systemName: "plus.circle"), for: .normal)
        addButton.accessibilityLabel = "Add control"
        addButton.showsMenuAsPrimaryAction = true
        button(undoButton, "arrow.uturn.backward", "Undo", #selector(undoTapped))
        let reset = UIButton(type: .system)
        button(reset, "arrow.counterclockwise", "Reset layout", #selector(resetTapped))
        button(snapButton, "grid", "Grid snap", #selector(snapTapped))
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .boldSystemFont(ofSize: 16)
        done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .lightGray

        topRow.axis = .horizontal
        topRow.distribution = .equalSpacing
        topRow.alignment = .center
        [cancel, addButton, undoButton, reset, snapButton, countLabel, done].forEach { topRow.addArrangedSubview($0) }
        addSubview(topRow)

        sizeSlider.minimumValue = 36
        sizeSlider.maximumValue = 220
        sizeSlider.addTarget(self, action: #selector(sizeChanged), for: .valueChanged)
        sizeSlider.addTarget(self, action: #selector(sizeBegan), for: .touchDown)
        sizeSlider.accessibilityLabel = "Size"
        opacitySlider.minimumValue = 0.1
        opacitySlider.maximumValue = 1
        opacitySlider.addTarget(self, action: #selector(opacityChanged), for: .valueChanged)
        opacitySlider.addTarget(self, action: #selector(opacityBegan), for: .touchDown)
        opacitySlider.accessibilityLabel = "Opacity"
        button(labelButton, "textformat", "Label", #selector(labelTapped))
        button(directionsButton, "arrow.up.and.down.and.arrow.left.and.right", "Four or eight directions", #selector(directionsTapped))
        button(deleteButton, "trash", "Delete control", #selector(deleteTapped))
        deleteButton.tintColor = .systemRed

        let sizeIcon = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
        let opacityIcon = UIImageView(image: UIImage(systemName: "circle.lefthalf.filled"))
        itemRow.axis = .horizontal
        itemRow.spacing = 8
        itemRow.alignment = .center
        [sizeIcon, sizeSlider, opacityIcon, opacitySlider, labelButton, directionsButton, deleteButton].forEach {
            itemRow.addArrangedSubview($0)
        }
        addSubview(itemRow)
    }

    required init?(coder: NSCoder) { fatalError() }

    func preferredHeight(hasSelection: Bool) -> CGFloat { hasSelection ? 92 : 48 }

    override func layoutSubviews() {
        super.layoutSubviews()
        topRow.frame = CGRect(x: 12, y: 4, width: bounds.width - 24, height: 40)
        itemRow.frame = CGRect(x: 12, y: 48, width: bounds.width - 24, height: 40)
    }

    func update(selected: ControlItem?, canUndo: Bool, gridSnap: Bool, count: Int) {
        self.gridSnap = gridSnap
        undoButton.isEnabled = canUndo
        snapButton.tintColor = gridSnap ? .systemYellow : .white
        countLabel.text = "\(count)/\(LayoutProfile.maxControls)"
        addButton.isEnabled = count < LayoutProfile.maxControls
        itemRow.isHidden = selected == nil
        if let selected {
            sizeSlider.value = Float(selected.size)
            opacitySlider.value = Float(selected.opacity)
            directionsButton.isHidden = !selected.action.isDirectional
            labelButton.isHidden = selected.action.isDirectional
        }
        setNeedsLayout()
    }

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func resetTapped() { onReset?() }
    @objc private func snapTapped() { onSnap?(!gridSnap) }
    @objc private func sizeBegan() { onSizeBegan?() }
    @objc private func sizeChanged() { onSize?(Double(sizeSlider.value)) }
    @objc private func opacityBegan() { onOpacityBegan?() }
    @objc private func opacityChanged() { onOpacity?(Double(opacitySlider.value)) }
    @objc private func labelTapped() { onLabel?() }
    @objc private func directionsTapped() { onDirections?() }
    @objc private func deleteTapped() { onDelete?() }
}
