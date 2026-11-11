import Foundation
import WebKit

/// JavaScript NexPlay injects into every game page.
enum PageScripts {
    /// Stops the long-press magnifier, text selection and tap flash that make games feel like web pages.
    static let noSelect = #"""
    (function () {
        var s = document.createElement('style');
        s.textContent = '*{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}' +
            'input,textarea,[contenteditable]{-webkit-user-select:text;user-select:text}' +
            'html,body{overscroll-behavior:none}';
        (document.head || document.documentElement).appendChild(s);
    })();
    """#

    /// window.__nexKey(keyCode, key, code, down) lets the on-screen controls press keyboard keys.
    static let keyBridge = #"""
    (function () {
        window.__nexKey = function (kc, key, code, down) {
            var e = new Event(down ? 'keydown' : 'keyup', { bubbles: true, cancelable: true });
            Object.defineProperty(e, 'keyCode', { get: function () { return kc; } });
            Object.defineProperty(e, 'which', { get: function () { return kc; } });
            Object.defineProperty(e, 'key', { get: function () { return key; } });
            Object.defineProperty(e, 'code', { get: function () { return code; } });
            document.dispatchEvent(e);
        };
    })();
    """#

    /// window.__nexStats(true/false) starts or stops frame-rate reporting to the app.
    static let stats = #"""
    (function () {
        var on = false, frames = 0, last = 0;
        function loop(t) {
            if (!on) return;
            frames++;
            if (t - last >= 1000) {
                try { window.webkit.messageHandlers.nexStats.postMessage(Math.round(frames * 1000 / (t - last))); } catch (e) {}
                frames = 0; last = t;
            }
            requestAnimationFrame(loop);
        }
        window.__nexStats = function (v) {
            if (v && !on) { on = true; frames = 0; last = performance.now(); requestAnimationFrame(loop); }
            else if (!v) { on = false; }
        };
    })();
    """#

    /// Runs RPG Maker's update step several times per frame. The page keeps its own frame rate, the game runs faster.
    static func fastForward(_ multiplier: Int) -> String {
        """
        (function (m) {
            if (typeof SceneManager === 'undefined') return 'no';
            SceneManager.__nexMul = m;
            if (!SceneManager.__nexWrapped) {
                SceneManager.__nexWrapped = true;
                var orig = SceneManager.updateScene;
                SceneManager.updateScene = function () {
                    var n = SceneManager.__nexMul || 1;
                    orig.call(this);
                    for (var i = 1; i < n; i++) {
                        if (this.updateInputData) this.updateInputData();
                        orig.call(this);
                    }
                };
            }
            return 'ok';
        })(\(multiplier));
        """
    }
}

/// Receives the frame rate the stats script reports.
final class StatsReceiver: NSObject, WKScriptMessageHandler {
    var onFPS: ((Int) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let number = message.body as? NSNumber {
            onFPS?(number.intValue)
        }
    }
}
