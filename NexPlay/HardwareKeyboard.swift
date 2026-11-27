import GameController
import UIKit
import WebKit

// 9.0.0: hardware keyboards (iPad keyboard cases, Bluetooth keyboards) in web-view games.
//
// The player is a GCEventViewController with controllerUserInteractionEnabled = false, so the Game Controller
// framework owns controller input. Whether a hardware keyboard still reaches WKWebView through UIKit then is not
// documented, so NexPlay listens to GCKeyboard as well and forwards keys itself, until the page shows that real
// (trusted) key events arrive on their own; from then on only the ⌘ shortcuts are handled here. A key that comes
// both ways within 150 ms is dropped once in the page (`HardwareKeyboardScripts.dedupe`), so nothing is pressed twice.
//
// Shortcuts (hold ⌘): G Game Panel, S Quick Save, L Quick Load, F Fast Forward, I Performance HUD, P Screenshot,
// E Edit Controls, W Exit. Keys are not forwarded while a sheet or the on-screen keyboard is open.

extension SettingsKey {
    /// Hide the on-screen controls while a hardware keyboard is connected (the control bar's gamepad button shows
    /// them again for the session).
    static let hidePadWithKeyboard = "hidePadWithKeyboard"
    /// ⌘ shortcuts in games.
    static let keyboardShortcutsInGames = "keyboardShortcutsInGames"

    static let keyboardKeys: [String] = [hidePadWithKeyboard, keyboardShortcutsInGames]
}

/// GCKeyCode (USB HID usage) → the DOM key the game should see.
enum NexKeyboardMap {
    static func padKey(for usage: Int) -> PadKey? {
        switch usage {
        case 4...29:
            let index = usage - 4
            let scalar = UnicodeScalar(UInt8(97 + index))
            let letter = String(Character(scalar))
            return PadKey(keyCode: 65 + index, key: letter, code: "Key" + letter.uppercased())
        case 30...38:
            let digit = usage - 29
            return PadKey(keyCode: 48 + digit, key: "\(digit)", code: "Digit\(digit)")
        case 39: return PadKey(keyCode: 48, key: "0", code: "Digit0")
        case 40, 88: return .enter
        case 41: return .menu
        case 42: return .backspace
        case 43: return .tab
        case 44: return .space
        case 45: return PadKey(keyCode: 189, key: "-", code: "Minus")
        case 46: return PadKey(keyCode: 187, key: "=", code: "Equal")
        case 47: return PadKey(keyCode: 219, key: "[", code: "BracketLeft")
        case 48: return PadKey(keyCode: 221, key: "]", code: "BracketRight")
        case 49: return PadKey(keyCode: 220, key: "\\", code: "Backslash")
        case 51: return PadKey(keyCode: 186, key: ";", code: "Semicolon")
        case 52: return PadKey(keyCode: 222, key: "'", code: "Quote")
        case 53: return PadKey(keyCode: 192, key: "`", code: "Backquote")
        case 54: return PadKey(keyCode: 188, key: ",", code: "Comma")
        case 55: return PadKey(keyCode: 190, key: ".", code: "Period")
        case 56: return PadKey(keyCode: 191, key: "/", code: "Slash")
        case 57: return PadKey(keyCode: 20, key: "CapsLock", code: "CapsLock")
        case 58...69:
            let number = usage - 57
            return PadKey(keyCode: 111 + number, key: "F\(number)", code: "F\(number)")
        case 73: return .insert
        case 74: return .home
        case 75: return .pageUp
        case 76: return .delete
        case 77: return .end
        case 78: return .pageDown
        case 79: return .right
        case 80: return .left
        case 81: return .down
        case 82: return .up
        case 224: return .control
        case 225: return .dash
        case 226: return .alt
        case 228: return PadKey(keyCode: 17, key: "Control", code: "ControlRight")
        case 229: return PadKey(keyCode: 16, key: "Shift", code: "ShiftRight")
        case 230: return PadKey(keyCode: 18, key: "Alt", code: "AltRight")
        default: return nil
        }
    }

    /// ⌘ (left or right GUI key).
    static func isCommand(_ usage: Int) -> Bool { usage == 227 || usage == 231 }
}

enum HardwareKeyboardScripts {
    /// `window.__nexHWKey` (keys NexPlay forwards from GCKeyboard) and a capture listener for trusted key events:
    /// a key seen both ways within 150 ms reaches the game once; trusted keys are reported (`nexNativeKeys`, at most
    /// once a second). Uses `new Date()`, which the speed/pause clock warp leaves alone.
    static let dedupe = #"""
    (function () {
        if (window.__nexHWKey) return;
        var nativeAt = {}, synthAt = {}, lastTold = 0;
        function t() { return new Date().getTime(); }
        window.__nexHWKey = function (kc, key, code, down) {
            var id = code + (down ? 'd' : 'u');
            if (t() - (nativeAt[id] || 0) < 150) return;
            synthAt[id] = t();
            if (window.__nexKey) window.__nexKey(kc, key, code, down);
        };
        function onNative(e) {
            if (!e.isTrusted || !e.code) return;
            var id = e.code + (e.type === 'keydown' ? 'd' : 'u');
            var now = t();
            if (e.type === 'keydown' && now - lastTold > 1000) {
                lastTold = now;
                try { window.webkit.messageHandlers.nexNativeKeys.postMessage(e.code); } catch (err) {}
            }
            if (now - (synthAt[id] || 0) < 150) {
                e.stopImmediatePropagation();
                e.preventDefault();
                return;
            }
            nativeAt[id] = now;
        }
        window.addEventListener('keydown', onNative, true);
        window.addEventListener('keyup', onNative, true);
    })();
    """#
}

@MainActor
final class HardwareKeyboardFeature: PlayerFeature {
    private var started = false
    private var observers: [NSObjectProtocol] = []
    /// Keys this feature pressed in the game, by HID usage.
    private var pressed: [Int: PadKey] = [:]
    /// True once a trusted key event arrived right after a GCKeyboard key: WebKit gets the keys itself.
    private var nativeKeysWork = false
    private var lastKeyboardEvent = Date.distantPast
    private weak var keyboardInput: GCKeyboardInput?

    override func userScripts(for game: Game) -> [WKUserScript] {
        [WKUserScript(source: HardwareKeyboardScripts.dedupe, injectionTime: .atDocumentStart, forMainFrameOnly: true)]
    }

    override var messageNames: [String] { ["nexNativeKeys"] }

    override func receive(name: String, body: Any) {
        guard name == "nexNativeKeys", !nativeKeysWork else { return }
        // Only proof when a hardware key was just pressed (the on-screen keyboard in a web text field is trusted too).
        guard Date().timeIntervalSince(lastKeyboardEvent) < 0.4 else { return }
        nativeKeysWork = true
        releaseAll()
        context.gameLog.add("keyboard: the hardware keyboard reaches the game directly; NexPlay only handles ⌘ shortcuts")
    }

    override func didFinishLoad() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        })
        attach()
    }

    override func shutdown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        releaseAll()
        keyboardInput?.keyChangedHandler = nil
        keyboardInput = nil
    }

    private func attach() {
        let input = GCKeyboard.coalesced?.keyboardInput
        if let input, input !== keyboardInput {
            keyboardInput?.keyChangedHandler = nil
            keyboardInput = input
            input.keyChangedHandler = { [weak self] keyboard, _, keyCode, down in
                self?.handle(keyboard, usage: keyCode.rawValue, down: down)
            }
            context.gameLog.add("keyboard: hardware keyboard connected")
        } else if input == nil {
            releaseAll()
            keyboardInput = nil
        }
        context.keyboardChanged(input != nil)
    }

    private func handle(_ keyboard: GCKeyboardInput, usage: Int, down: Bool) {
        lastKeyboardEvent = Date()
        if NexKeyboardMap.isCommand(usage) { return }
        let command = (keyboard.button(forKeyCode: .leftGUI)?.isPressed ?? false)
            || (keyboard.button(forKeyCode: .rightGUI)?.isPressed ?? false)
        if command {
            if down { shortcut(usage, shift: isShift(keyboard)) }
            return
        }
        if !down, let key = pressed.removeValue(forKey: usage) {
            context.sendHardwareKey(key, false)
            return
        }
        guard down, !nativeKeysWork, !context.inputBusy(), pressed[usage] == nil,
              let key = NexKeyboardMap.padKey(for: usage) else { return }
        pressed[usage] = key
        context.sendHardwareKey(key, true)
    }

    private func isShift(_ keyboard: GCKeyboardInput) -> Bool {
        (keyboard.button(forKeyCode: .leftShift)?.isPressed ?? false) || (keyboard.button(forKeyCode: .rightShift)?.isPressed ?? false)
    }

    private func shortcut(_ usage: Int, shift: Bool) {
        guard UserDefaults.standard.object(forKey: SettingsKey.keyboardShortcutsInGames) as? Bool ?? true else { return }
        guard !context.inputBusy() else { return }
        releaseAll()
        switch usage {
        case 10: context.runAction(.gamePanel)       // G
        case 22: context.runAction(.quickSave)       // S
        case 15: context.runAction(.quickLoad)       // L
        case 9: context.runAction(.fastForward)      // F
        case 12: context.toggleStats()               // I
        case 19: context.screenshot()                // P
        case 8: context.editControls()               // E
        case 26: context.exitGame()                  // W
        default: break
        }
    }

    private func releaseAll() {
        for key in pressed.values { context.sendHardwareKey(key, false) }
        pressed = [:]
    }
}
