import UIKit

// 7.3.0 input overhaul: mouse modes for web-view games. Direct touch is the browser's own touch handling; Trackpad
// moves a cursor (one finger), clicks with a tap, right-clicks with a two-finger tap, scrolls with two fingers and
// drags after touch-and-hold. Mouse events reach the page through window.__nexMouse.

/// How touches on the game act as a mouse.
enum MouseMode: String, Codable, CaseIterable, Identifiable {
    case direct, trackpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "Direct Touch"
        case .trackpad: return "Trackpad"
        }
    }

    var shortTitle: String {
        switch self {
        case .direct: return "Touch"
        case .trackpad: return "Trackpad"
        }
    }

    var detail: String {
        switch self {
        case .direct:
            return "The game is clicked where your finger touches it."
        case .trackpad:
            return "Drag to move the cursor, tap to click, two-finger tap to right-click, two-finger drag to scroll, touch and hold then drag to drag."
        }
    }

    static func resolved(for game: Game) -> MouseMode {
        game.mouseMode ?? .direct
    }
}

enum MouseScripts {
    /// window.__nexMouse(type, x, y, arg): type is "move", "down", "up" (arg = button 0 left, 1 middle, 2 right)
    /// or "wheel" (arg = deltaY). x and y are CSS pixels in the page. Pointer and mouse events are both sent, as a
    /// real mouse does; a left "up" adds click, a right "up" adds contextmenu.
    static let bridge = #"""
    (function () {
        if (window.__nexMouse) return;
        var held = 0;
        function targetAt(x, y) {
            var el = null;
            try { el = document.elementFromPoint(x, y); } catch (err) {}
            return el || document.querySelector('canvas') || document.body || document;
        }
        function fire(el, kind, x, y, button) {
            var init = { clientX: x, clientY: y, screenX: x, screenY: y, button: button, buttons: held,
                         bubbles: true, cancelable: true, composed: true, view: window };
            var e = null;
            try {
                if (kind.indexOf('pointer') === 0) {
                    if (!window.PointerEvent) return;
                    init.pointerId = 1;
                    init.pointerType = 'mouse';
                    init.isPrimary = true;
                    e = new PointerEvent(kind, init);
                } else {
                    e = new MouseEvent(kind, init);
                }
            } catch (err) {
                return;
            }
            el.dispatchEvent(e);
        }
        window.__nexMouse = function (type, x, y, arg) {
            var el = targetAt(x, y);
            var button = arg === 2 ? 2 : (arg === 1 ? 1 : 0);
            var bit = button === 2 ? 2 : (button === 1 ? 4 : 1);
            if (type === 'move') {
                fire(el, 'pointermove', x, y, -1);
                fire(el, 'mousemove', x, y, 0);
            } else if (type === 'down') {
                held |= bit;
                fire(el, 'pointerdown', x, y, button);
                fire(el, 'mousedown', x, y, button);
            } else if (type === 'up') {
                held &= ~bit;
                fire(el, 'pointerup', x, y, button);
                fire(el, 'mouseup', x, y, button);
                if (button === 0) fire(el, 'click', x, y, 0);
                if (button === 2) fire(el, 'contextmenu', x, y, 2);
            } else if (type === 'wheel') {
                var w;
                try {
                    w = new WheelEvent('wheel', { deltaY: arg, deltaMode: 0, clientX: x, clientY: y, bubbles: true, cancelable: true });
                } catch (err) {
                    w = new Event('wheel', { bubbles: true, cancelable: true });
                    try { Object.defineProperty(w, 'deltaY', { get: function () { return arg; } }); } catch (err2) {}
                }
                el.dispatchEvent(w);
            }
        };
    })();
    """#
}

/// Covers the game in Trackpad mode and turns touches into cursor moves, clicks, scrolls and drags.
/// Lies under the on-screen controls, so they keep working.
final class TrackpadView: UIView {
    /// Mouse events in this view's coordinates: ("move" | "down" | "up", point, button) and ("wheel", point, deltaY).
    var onMouse: ((String, CGPoint, Int) -> Void)?
    /// The area the cursor stays in (the game's frame, in this view's coordinates).
    var limits: () -> CGRect = { .zero }

    private(set) var cursor = CGPoint.zero
    private let arrow = UIImageView()
    private var lastPan = CGPoint.zero
    private var lastHold = CGPoint.zero
    private var lastScroll = CGPoint.zero
    private var placed = false
    private let speed: CGFloat = 1.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        arrow.image = UIImage(systemName: "cursorarrow", withConfiguration: config)
        arrow.tintColor = .white
        arrow.contentMode = .topLeft
        arrow.isUserInteractionEnabled = false
        arrow.layer.shadowColor = UIColor.black.cgColor
        arrow.layer.shadowOpacity = 0.8
        arrow.layer.shadowRadius = 2
        arrow.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(arrow)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
        twoTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        addGestureRecognizer(scroll)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 10
        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = limits()
        if !placed, area.width > 0 {
            placed = true
            cursor = CGPoint(x: area.midX, y: area.midY)
        }
        cursor = clamp(cursor)
        placeArrow()
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let area = limits()
        guard area.width > 0, area.height > 0 else { return point }
        return CGPoint(x: min(max(point.x, area.minX), area.maxX - 1), y: min(max(point.y, area.minY), area.maxY - 1))
    }

    private func placeArrow() {
        let size = arrow.image?.size ?? CGSize(width: 20, height: 24)
        // The arrow's tip sits near the image's top-left corner.
        arrow.frame = CGRect(x: cursor.x - size.width * 0.28, y: cursor.y - size.height * 0.12,
                             width: size.width, height: size.height)
    }

    private func moveCursor(by delta: CGPoint) {
        cursor = clamp(CGPoint(x: cursor.x + delta.x * speed, y: cursor.y + delta.y * speed))
        placeArrow()
        onMouse?("move", cursor, 0)
    }

    @objc private func tapped() {
        onMouse?("move", cursor, 0)
        onMouse?("down", cursor, 0)
        onMouse?("up", cursor, 0)
    }

    @objc private func twoFingerTapped() {
        onMouse?("down", cursor, 2)
        onMouse?("up", cursor, 2)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            lastPan = point
        case .changed:
            moveCursor(by: CGPoint(x: point.x - lastPan.x, y: point.y - lastPan.y))
            lastPan = point
        default:
            lastPan = .zero
        }
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            lastScroll = point
        case .changed:
            let dy = point.y - lastScroll.y
            guard abs(dy) >= 6 else { return }
            // Fingers moving up scroll down, as on a trackpad with natural scrolling.
            onMouse?("wheel", cursor, Int((-dy * 4).rounded()))
            lastScroll = point
        default:
            lastScroll = .zero
        }
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            lastHold = point
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onMouse?("down", cursor, 0)
        case .changed:
            moveCursor(by: CGPoint(x: point.x - lastHold.x, y: point.y - lastHold.y))
            lastHold = point
        case .ended, .cancelled, .failed:
            onMouse?("up", cursor, 0)
        default:
            break
        }
    }
}
