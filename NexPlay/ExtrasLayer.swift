import CoreMotion
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// 8.2.1: the running side of a web-view game's extras (Extras.swift has the settings). Owned by PlayerViewController,
// which hands it an `ExtrasHost` (keys, mouse, wheel, app actions) and the views to place things between. Nothing runs
// for an extra that is off: no sensor, no recognizer, no view.

/// What the extras can do in the game (the player).
@MainActor protocol ExtrasHost: AnyObject {
    func extraKey(_ key: PadKey, _ down: Bool)
    /// A mouse button at the cursor.
    func extraMouse(right: Bool, down: Bool)
    /// Moves the cursor by points in the player's view (gyro aim, aim zone).
    func extraMoveMouse(by delta: CGPoint)
    /// The Pencil: "move" | "down" | "up" at a point in the player's view.
    func extraPointer(_ type: String, at point: CGPoint, button: Int)
    func extraWheel(_ deltaY: Int)
    func extraApp(_ kind: ExtraAction.Kind)
}

@MainActor
final class ExtrasController {
    private weak var host: ExtrasHost?
    private weak var root: UIView?
    private weak var gameView: UIView?
    private(set) var extras: GameExtras

    private var keyBar: UIHostingController<KeyBarView>?
    private var keyBarShown = false
    private var radial: RadialButton?
    private var aimZone: AimZoneView?
    private var motion: CMMotionManager?
    private var lastMotion: TimeInterval?
    private var gestureRecognizers: [UIGestureRecognizer] = []
    private var lens: LensHandle?
    private var pencil: PencilMouseRecognizer?
    private var pencilInteraction: UIPencilInteraction?
    private var pencilDelegate: PencilDelegate?

    /// Turbo: keys that repeat while held (KeyRouter asks).
    var turboKeys: Set<Int> { Set(extras.turboKeys) }
    var turboRate: Int { extras.turboRate }

    init(host: ExtrasHost, extras: GameExtras) {
        self.host = host
        self.extras = extras
    }

    /// Puts the extras that are on into `root`, above `below` (the game or the trackpad) and under `above` (the pad).
    func install(in root: UIView, game gameView: UIView, below: UIView, above: UIView?) {
        self.root = root
        self.gameView = gameView
        apply(extras, below: below, above: above)
    }

    func update(_ new: GameExtras, below: UIView, above: UIView?) {
        apply(new, below: below, above: above)
    }

    private func apply(_ new: GameExtras, below: UIView, above: UIView?) {
        extras = new
        guard let root else { return }
        setKeyBar(new.keyBar || keyBarShown, in: root)
        setRadial(new.radial, in: root)
        setAimZone(new.aimZone, in: root, below: below, above: above)
        setGyro(new.gyro)
        setGestures(new, in: root)
        setMagnifier(new.magnifier, in: root)
        setPencil(new.pencil, in: root)
    }

    func stop() {
        motion?.stopDeviceMotionUpdates()
        motion = nil
        for recognizer in gestureRecognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        gestureRecognizers = []
        keyBar?.view.removeFromSuperview()
        keyBar = nil
        radial?.close()
        radial?.removeFromSuperview()
        radial = nil
        aimZone?.removeFromSuperview()
        aimZone = nil
        lens?.removeFromSuperview()
        lens = nil
        gameView?.transform = .identity
        if let pencil { pencil.view?.removeGestureRecognizer(pencil) }
        pencil = nil
        if let pencilInteraction { pencilInteraction.view?.removeInteraction(pencilInteraction) }
        pencilInteraction = nil
    }

    /// The editor is open or a sheet covers the game: the floating extras step aside.
    func setCovered(_ covered: Bool) {
        keyBar?.view.isHidden = covered
        radial?.isHidden = covered
        if covered { radial?.close() }
        lens?.isHidden = covered
        if covered { motion?.stopDeviceMotionUpdates() } else if extras.gyro { startGyro() }
    }

    // MARK: Running an action

    func run(_ action: ExtraAction) {
        guard let host else { return }
        NexHaptics.tap()
        switch action.kind {
        case .key, .combo:
            let keys = action.keys.map(PadKey.fromKeyCode)
            for key in keys { host.extraKey(key, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak host] in
                for key in keys.reversed() { host?.extraKey(key, false) }
            }
        case .mouseLeft, .mouseRight:
            let right = action.kind == .mouseRight
            host.extraMouse(right: right, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak host] in host?.extraMouse(right: right, down: false) }
        case .wheelUp: host.extraWheel(-120)
        case .wheelDown: host.extraWheel(120)
        case .keyBar:
            keyBarShown.toggle()
            if let root { setKeyBar(extras.keyBar || keyBarShown, in: root) }
        case .gamePanel, .keyboard, .quickSave, .quickLoad:
            host.extraApp(action.kind)
        }
    }

    // MARK: Key bar

    private func setKeyBar(_ on: Bool, in root: UIView) {
        if !on {
            keyBar?.view.removeFromSuperview()
            keyBar = nil
            return
        }
        guard keyBar == nil else { return }
        let bar = KeyBarView(send: { [weak self] code, down in self?.host?.extraKey(PadKey.fromKeyCode(code), down) },
                             close: { [weak self] in
                                 guard let self else { return }
                                 self.keyBarShown = false
                                 if !self.extras.keyBar, let root = self.root { self.setKeyBar(false, in: root) }
                             },
                             closable: !extras.keyBar)
        let hosting = UIHostingController(rootView: bar)
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            hosting.view.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -150),
            hosting.view.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            hosting.view.heightAnchor.constraint(equalToConstant: 46),
        ])
        let wide = hosting.view.widthAnchor.constraint(equalToConstant: 720)
        wide.priority = .defaultLow
        wide.isActive = true
        keyBar = hosting
    }

    // MARK: Radial menu

    private func setRadial(_ on: Bool, in root: UIView) {
        if !on {
            radial?.close()
            radial?.removeFromSuperview()
            radial = nil
            return
        }
        if let radial {
            radial.slots = extras.radialSlots
            return
        }
        let button = RadialButton(slots: extras.radialSlots) { [weak self] action in self?.run(action) }
        button.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -40),
            button.widthAnchor.constraint(equalToConstant: 46),
            button.heightAnchor.constraint(equalToConstant: 46),
        ])
        radial = button
    }

    // MARK: Aim zone

    private func setAimZone(_ on: Bool, in root: UIView, below: UIView, above: UIView?) {
        if !on {
            aimZone?.removeFromSuperview()
            aimZone = nil
            return
        }
        if let aimZone {
            aimZone.speed = extras.aimSpeed
            return
        }
        let zone = AimZoneView(frame: .zero)
        zone.speed = extras.aimSpeed
        zone.onMove = { [weak self] delta in self?.host?.extraMoveMouse(by: delta) }
        zone.onTap = { [weak self] in self?.run(ExtraAction(kind: .mouseLeft)) }
        zone.translatesAutoresizingMaskIntoConstraints = false
        if let above, above.superview === root {
            root.insertSubview(zone, belowSubview: above)
        } else {
            root.insertSubview(zone, aboveSubview: below)
        }
        NSLayoutConstraint.activate([
            zone.topAnchor.constraint(equalTo: root.topAnchor),
            zone.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            zone.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            zone.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.45),
        ])
        aimZone = zone
    }

    // MARK: Gyro aim

    private func setGyro(_ on: Bool) {
        if on { startGyro() } else {
            motion?.stopDeviceMotionUpdates()
            motion = nil
        }
    }

    private func startGyro() {
        let manager = motion ?? CMMotionManager()
        motion = manager
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        lastMotion = nil
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in self?.gyroSample(data) }
        }
    }

    private func gyroSample(_ data: CMDeviceMotion) {
        defer { lastMotion = data.timestamp }
        guard let last = lastMotion else { return }
        let dt = min(max(data.timestamp - last, 0), 0.1)
        let rate = data.rotationRate
        let orientation = root?.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        // The screen's right and up in the phone's axes (as BCD's BCDGyroSettings.screenAxes).
        let right: (Double, Double), up: (Double, Double)
        switch orientation {
        case .portraitUpsideDown: right = (-1, 0); up = (0, -1)
        case .landscapeLeft: right = (0, 1); up = (-1, 0)
        case .landscapeRight: right = (0, -1); up = (1, 0)
        default: right = (1, 0); up = (0, 1)
        }
        let aboutUp = rate.x * up.0 + rate.y * up.1
        let aboutRight = rate.x * right.0 + rate.y * right.1
        let degrees = 180.0 / Double.pi
        let turnRight = -aboutUp * degrees * dt
        var lookDown = -aboutRight * degrees * dt
        if extras.gyroInvertY { lookDown = -lookDown }
        // A small dead zone keeps a resting hand from drifting the cursor.
        guard abs(turnRight) > 0.01 || abs(lookDown) > 0.01 else { return }
        host?.extraMoveMouse(by: CGPoint(x: turnRight * extras.gyroSpeed, y: lookDown * extras.gyroSpeed))
    }

    // MARK: Gestures

    private func setGestures(_ new: GameExtras, in root: UIView) {
        for recognizer in gestureRecognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        gestureRecognizers = []
        for gesture in GameExtras.Gesture.allCases where new.action(for: gesture) != nil {
            let recognizer: UIGestureRecognizer
            switch gesture {
            case .twoTap, .threeTap:
                let tap = UITapGestureRecognizer(target: GestureTarget.shared, action: #selector(GestureTarget.fired(_:)))
                tap.numberOfTouchesRequired = gesture == .twoTap ? 2 : 3
                recognizer = tap
            case .threeSwipeUp, .threeSwipeDown:
                let swipe = UISwipeGestureRecognizer(target: GestureTarget.shared, action: #selector(GestureTarget.fired(_:)))
                swipe.numberOfTouchesRequired = 3
                swipe.direction = gesture == .threeSwipeUp ? .up : .down
                recognizer = swipe
            case .pinchIn, .pinchOut:
                let pinch = UIPinchGestureRecognizer(target: GestureTarget.shared, action: #selector(GestureTarget.fired(_:)))
                recognizer = pinch
            }
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            GestureTarget.shared.register(recognizer, gesture: gesture) { [weak self] fired in
                guard let self, let action = self.extras.action(for: fired) else { return }
                self.run(action)
            }
            root.addGestureRecognizer(recognizer)
            gestureRecognizers.append(recognizer)
        }
    }

    // MARK: Magnifier

    private func setMagnifier(_ zoom: Double, in root: UIView) {
        guard let gameView else { return }
        if zoom <= 1 {
            lens?.removeFromSuperview()
            lens = nil
            gameView.transform = .identity
            return
        }
        let handle = lens ?? LensHandle(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        if lens == nil {
            handle.center = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
            handle.onMove = { [weak self] point in self?.focus(on: point) }
            root.addSubview(handle)
            lens = handle
        }
        focus(on: handle.center)
    }

    /// Enlarges the game around a point of the player's view; UIKit maps touches through the transform.
    private func focus(on point: CGPoint) {
        guard let gameView, let root, extras.magnifier > 1 else { return }
        gameView.transform = .identity
        let frame = gameView.frame
        let s = CGFloat(extras.magnifier)
        let anchor = CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
        // Scale about the anchor: the point under the lens stays where it is.
        let dx = (anchor.x - frame.midX) * (1 - s)
        let dy = (anchor.y - frame.midY) * (1 - s)
        gameView.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: s, y: s)
        _ = root
    }

    // MARK: Pencil

    private func setPencil(_ on: Bool, in root: UIView) {
        if !on {
            if let pencil { pencil.view?.removeGestureRecognizer(pencil) }
            pencil = nil
            if let pencilInteraction { pencilInteraction.view?.removeInteraction(pencilInteraction) }
            pencilInteraction = nil
            pencilDelegate = nil
            return
        }
        guard pencil == nil else { return }
        let recognizer = PencilMouseRecognizer(target: nil, action: nil)
        recognizer.onPointer = { [weak self] type, point, button in self?.host?.extraPointer(type, at: point, button: button) }
        root.addGestureRecognizer(recognizer)
        pencil = recognizer
        let delegate = PencilDelegate { [weak self] in self?.run(ExtraAction(kind: .mouseRight)) }
        let interaction = UIPencilInteraction()
        interaction.delegate = delegate
        root.addInteraction(interaction)
        pencilInteraction = interaction
        pencilDelegate = delegate
    }
}

// MARK: - Gesture target

@MainActor
final class GestureTarget: NSObject {
    static let shared = GestureTarget()
    private var handlers: [ObjectIdentifier: (GameExtras.Gesture, (GameExtras.Gesture) -> Void)] = [:]

    func register(_ recognizer: UIGestureRecognizer, gesture: GameExtras.Gesture,
                  handler: @escaping (GameExtras.Gesture) -> Void) {
        handlers[ObjectIdentifier(recognizer)] = (gesture, handler)
    }

    @objc func fired(_ recognizer: UIGestureRecognizer) {
        guard let (gesture, handler) = handlers[ObjectIdentifier(recognizer)] else { return }
        if let pinch = recognizer as? UIPinchGestureRecognizer {
            guard pinch.state == .ended else { return }
            if gesture == .pinchIn && pinch.scale < 0.75 { handler(gesture) }
            if gesture == .pinchOut && pinch.scale > 1.33 { handler(gesture) }
            return
        }
        guard recognizer.state == .ended || recognizer.state == .recognized else { return }
        handler(gesture)
    }
}

// MARK: - Key bar

struct KeyBarView: View {
    let send: (Int, Bool) -> Void
    let close: () -> Void
    let closable: Bool
    @State private var latched: Set<Int> = []

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ExtraKeys.modifiers, id: \.self) { code in
                key(code, latched.contains(code)) { toggleLatch(code) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ExtraKeys.bar, id: \.self) { code in
                        PressKey(title: ExtraKeys.name(code)) { down in
                            send(code, down)
                            if !down { releaseLatches() }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            if closable {
                Button {
                    NexHaptics.tap()
                    releaseLatches()
                    close()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NexColor.dark(.text))
            }
        }
        .padding(5)
        .nexGlassCapsule()
        .environment(\.colorScheme, .dark)
        .fontDesign(.rounded)
    }

    private func key(_ code: Int, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(ExtraKeys.name(code))
                .font(NexType.captionStrong)
                .frame(minWidth: 40, minHeight: 34)
                .padding(.horizontal, 4)
                .foregroundStyle(on ? NexColor.dark(.onAccent) : NexColor.dark(.text))
                .background(on ? NexColor.dark(.accent) : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleLatch(_ code: Int) {
        NexHaptics.selection()
        if latched.contains(code) {
            latched.remove(code)
            send(code, false)
        } else {
            latched.insert(code)
            send(code, true)
        }
    }

    private func releaseLatches() {
        for code in latched { send(code, false) }
        latched = []
    }
}

/// A key that is down while the finger is on it.
private struct PressKey: View {
    let title: String
    let changed: (Bool) -> Void
    @State private var down = false

    var body: some View {
        Text(title)
            .font(NexType.captionStrong)
            .frame(minWidth: 40, minHeight: 34)
            .padding(.horizontal, 4)
            .foregroundStyle(NexColor.dark(.text))
            .background(Color.white.opacity(down ? 0.3 : 0.08), in: Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        NexHaptics.tap()
                        changed(true)
                    }
                    .onEnded { _ in
                        guard down else { return }
                        down = false
                        changed(false)
                    }
            )
    }
}

// MARK: - Radial menu

/// The radial menu's button: hold it and slide to a slot, or tap it, then tap a slot.
final class RadialButton: UIView {
    var slots: [ExtraAction]
    private let run: (ExtraAction) -> Void
    private var ring: UIView?
    private var slotViews: [UILabel] = []
    private var highlighted: Int?
    private var openedAt = Date()
    private var tapOpen = false
    private let radius: CGFloat = 92

    init(slots: [ExtraAction], run: @escaping (ExtraAction) -> Void) {
        self.slots = slots
        self.run = run
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 23
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        let icon = UIImageView(image: UIImage(systemName: "circle.grid.cross.fill"))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(icon)
        accessibilityLabel = "Radial menu"
    }

    required init?(coder: NSCoder) { nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if ring != nil {
            close()
            return
        }
        open()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let ring else { return }
        highlight(slot(at: touch.location(in: ring)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard ring != nil else { return }
        if let highlighted, highlighted < slots.count {
            let action = slots[highlighted]
            close()
            run(action)
        } else if Date().timeIntervalSince(openedAt) < 0.35 {
            tapOpen = true   // a quick tap leaves the ring open for a tap on a slot
        } else {
            close()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { close() }

    private func open() {
        guard let root = superview else { return }
        NexHaptics.press()
        openedAt = Date()
        tapOpen = false
        let cover = RadialCover(frame: root.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.onTap = { [weak self] point in
            guard let self else { return }
            let index = self.slot(at: point)
            self.close()
            if let index, index < self.slots.count { self.run(self.slots[index]) }
        }
        root.insertSubview(cover, belowSubview: self)
        ring = cover
        let center = ringCenter(in: cover)
        let count = max(slots.count, 1)
        slotViews = slots.enumerated().map { index, action in
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(count)
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: 54, height: 54))
            label.center = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            label.text = action.short
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 12, weight: .bold)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            label.layer.cornerRadius = 27
            label.layer.masksToBounds = true
            label.layer.borderWidth = 1
            label.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
            cover.addSubview(label)
            return label
        }
        highlighted = nil
    }

    func close() {
        ring?.removeFromSuperview()
        ring = nil
        slotViews = []
        highlighted = nil
        tapOpen = false
    }

    private func ringCenter(in cover: UIView) -> CGPoint {
        let mine = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: cover)
        // Inward from the edge, so the whole ring is on screen.
        let x = min(mine.x, cover.bounds.width - radius - 40)
        let y = min(max(mine.y, radius + 40), cover.bounds.height - radius - 40)
        return CGPoint(x: x, y: y)
    }

    private func slot(at point: CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for (index, view) in slotViews.enumerated() {
            let d = hypot(point.x - view.center.x, point.y - view.center.y)
            if d < 44, best == nil || d < best!.1 { best = (index, d) }
        }
        return best?.0
    }

    private func highlight(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        if index != nil { NexHaptics.selection() }
        for (i, view) in slotViews.enumerated() {
            view.backgroundColor = i == index ? UIColor(NexColor.dark(.accent)) : UIColor.black.withAlphaComponent(0.6)
        }
    }
}

/// While the ring is open: dims nothing, catches the next tap.
private final class RadialCover: UIView {
    var onTap: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.15)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: self))
    }
}

// MARK: - Aim zone

/// The right side of the screen as a trackpad: drag moves the mouse, tap clicks.
final class AimZoneView: UIView {
    var speed = 1.6
    var onMove: ((CGPoint) -> Void)?
    var onTap: (() -> Void)?
    private var last = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { nil }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.translation(in: self)
        if gesture.state == .began { last = .zero }
        let delta = CGPoint(x: (point.x - last.x) * speed, y: (point.y - last.y) * speed)
        last = point
        if gesture.state == .changed { onMove?(delta) }
    }

    @objc private func tapped() { onTap?() }
}

// MARK: - Magnifier lens

final class LensHandle: UIView {
    var onMove: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.5)
        layer.cornerRadius = frame.width / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        let icon = UIImageView(image: UIImage(systemName: "plus.magnifyingglass"))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(icon)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        accessibilityLabel = "Magnifier lens"
    }

    required init?(coder: NSCoder) { nil }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let point = gesture.location(in: superview)
        center = CGPoint(x: min(max(point.x, 22), superview.bounds.width - 22),
                         y: min(max(point.y, 22), superview.bounds.height - 22))
        onMove?(center)
    }
}

// MARK: - Pencil

/// Pencil touches become the mouse (fingers are left alone): the tip moves and holds the left button.
final class PencilMouseRecognizer: UIGestureRecognizer {
    var onPointer: ((String, CGPoint, Int) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = true
        delaysTouchesBegan = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        onPointer?("move", point, 0)
        onPointer?("down", point, 0)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        onPointer?("move", touch.location(in: view), 0)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return }
        onPointer?("up", touch.location(in: view), 0)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view { onPointer?("up", touch.location(in: view), 0) }
        state = .cancelled
    }
}

final class PencilDelegate: NSObject, UIPencilInteractionDelegate {
    private let rightClick: () -> Void

    init(rightClick: @escaping () -> Void) {
        self.rightClick = rightClick
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        rightClick()
    }
}
