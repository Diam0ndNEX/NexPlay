import Foundation
import WebKit

// The RPG Maker runtime script is adapted from mvmz-apple-mobile's runtime.js (speed, pause and resume,
// focus handling). Copyright (C) 2026 Mateo M., https://github.com/mateo-m/mvmz-apple-mobile
// and https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).

/// JavaScript NexPlay injects into game pages.
enum PageScripts {
    /// A desktop Safari user agent. With a phone user agent RPG Maker MV asks for .m4a audio many games don't ship,
    /// MV drops its fixed update rate, and MZ uses only 90% of the screen height.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

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

    /// Sends console output, script errors and files that failed to load to the app's game log.
    /// Limited to 40 lines a second so a game that logs every frame can't slow itself down.
    static let diagnostics = #"""
    (function () {
        var count = 0, windowStart = Date.now();
        function allowed() {
            var now = Date.now();
            if (now - windowStart > 1000) { windowStart = now; count = 0; }
            return ++count <= 40;
        }
        function send(text) {
            try { window.webkit.messageHandlers.nexLog.postMessage(String(text).slice(0, 2000)); } catch (e) {}
        }
        function show(a) {
            try { return typeof a === 'object' ? JSON.stringify(a) : String(a); } catch (e) { return String(a); }
        }
        ['log', 'info', 'warn', 'error'].forEach(function (level) {
            var original = console[level] ? console[level].bind(console) : function () {};
            console[level] = function () {
                original.apply(null, arguments);
                if (allowed()) send('console.' + level + ': ' + Array.prototype.map.call(arguments, show).join(' '));
            };
        });
        window.addEventListener('error', function (e) {
            if (!allowed()) return;
            var t = e.target;
            if (t && t !== window && (t.src || t.href)) { send('failed to load: ' + (t.src || t.href)); return; }
            send('error: ' + e.message + ' at ' + e.filename + ':' + e.lineno);
        }, true);
        window.addEventListener('unhandledrejection', function (e) {
            if (allowed()) send('unhandled rejection: ' + e.reason);
        });
    })();
    """#

    /// RPG Maker runtime. Owns the frame loop so the game can be paused, sped up and kept focused.
    /// window.__nex.setSpeed(n), window.__nex.pause(), window.__nex.resume().
    private static let rpgRuntimeBody = #"""
    (function () {
        var cfg = window.__nexSettings || {};

        // MZ updates the game only while the page has focus, and the app window always has it.
        try { Document.prototype.hasFocus = function () { return true; }; } catch (e) {}

        var nativeRAF = window.requestAnimationFrame.bind(window);
        var waiting = new Map();
        var nextId = 1, scheduled = false, paused = false;
        var speed = 1, speedApplied = false;

        function rethrow(e) { setTimeout(function () { throw e; }, 0); }

        function applySpeed() {
            if (typeof SceneManager === 'undefined') return;
            if (SceneManager.determineRepeatNumber) {
                // MZ runs as many updates as this says for each frame.
                if (!SceneManager.__nexWrapped) {
                    SceneManager.__nexWrapped = true;
                    var repeat = SceneManager.determineRepeatNumber;
                    SceneManager.determineRepeatNumber = function (deltaTime) {
                        return repeat.call(this, deltaTime) * speed;
                    };
                }
            } else {
                // MV runs one update for each _deltaTime seconds of real time.
                SceneManager._deltaTime = 1 / 60 / speed;
            }
            speedApplied = true;
        }

        function runFrame(time) {
            scheduled = false;
            if (paused) return;
            var callbacks = Array.from(waiting.values());
            waiting.clear();
            if (!speedApplied) applySpeed();
            for (var i = 0; i < callbacks.length; i++) {
                try { callbacks[i](time); } catch (e) { rethrow(e); }
            }
        }

        function schedule() {
            if (!scheduled && !paused && waiting.size) {
                scheduled = true;
                nativeRAF(runFrame);
            }
        }

        window.requestAnimationFrame = function (callback) {
            var id = nextId++;
            waiting.set(id, callback);
            schedule();
            return id;
        };
        window.cancelAnimationFrame = function (id) { waiting.delete(id); };

        var playingMedia = [];
        function audioContext() { return typeof WebAudio !== 'undefined' ? WebAudio._context : null; }

        window.__nex = {
            pause: function () {
                paused = true;
                var context = audioContext();
                // MZ stops the game on any unhandled rejection, and WebKit rejects a pending suspend() or play()
                // with AbortError when resume() or pause() follows too soon.
                if (context && context.state === 'running') context.suspend().catch(function () {});
                playingMedia = Array.from(document.querySelectorAll('video, audio')).filter(function (m) { return !m.paused; });
                playingMedia.forEach(function (m) { m.pause(); });
            },
            resume: function () {
                paused = false;
                var context = audioContext();
                if (context && context.state === 'suspended') context.resume().catch(function () {});
                playingMedia.forEach(function (m) { var p = m.play(); if (p && p.catch) p.catch(function () {}); });
                playingMedia = [];
                // MV counts the time since its last update and would run up to 15 updates at once to catch up.
                if (typeof SceneManager !== 'undefined' && '_currentTime' in SceneManager) {
                    SceneManager._currentTime = performance.now();
                }
                schedule();
            },
            setSpeed: function (multiplier) {
                speed = multiplier;
                applySpeed();
            }
        };

        if (cfg.pixelated) {
            document.addEventListener('DOMContentLoaded', function () {
                var s = document.createElement('style');
                s.textContent = 'canvas, video { image-rendering: pixelated; }';
                document.head.appendChild(s);
            });
        }
    })();
    """#

    static func rpgRuntime(pixelated: Bool) -> String {
        "window.__nexSettings = { pixelated: \(pixelated ? "true" : "false") };\n" + rpgRuntimeBody
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
