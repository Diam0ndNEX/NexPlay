import UIKit
import WebKit

// Game Tools (6.0.0), shown in the Game Panel (6.1.0):
// - Volume for every web-view game: Web Audio connections to a context's destination go through one master gain per
//   context; at 0, <audio>/<video> are muted too (iOS ignores media element volume).
// - Pause and Game Speed for the other web engines (HTML5, Godot, Construct, Twine, Tyrano, Ren'Py, Flash): a clock
//   warp (performance.now, Date.now, requestAnimationFrame timestamps, timer delays); pause also holds animation
//   frames and suspends audio. The time script gives these engines `window.__nex.pause/resume`, so they pause when
//   NexPlay goes to the background like RPG Maker games. Speed works for games that time themselves with the clock;
//   games running in a worker (some Construct exports, threaded Godot) are not affected.
// - Twine (SugarCube): Back / Forward through the story history (Engine.backward/forward).
// - Ren'Py: Python through renpy_exec (Quick Save, preferences).

enum WebTools {
    static func audioScript(volume: Double) -> String {
        "window.__nexStartVolume = \(volume);\n" + audioBody
    }

    private static let audioBody = #"""
    (function () {
        var W = window.__nexWeb = window.__nexWeb || {};
        if (W.audio) return;
        W.audio = true;
        W.volume = typeof window.__nexStartVolume === 'number' ? window.__nexStartVolume : 1;
        var contexts = [];
        function eachMedia(fn) {
            var list = document.querySelectorAll('audio, video');
            for (var i = 0; i < list.length; i++) { try { fn(list[i]); } catch (e) {} }
        }
        function muteMedia(el) {
            if (W.volume === 0) {
                if (!el.muted) { el.muted = true; el.__nexMuted = true; }
            } else if (el.__nexMuted) {
                el.muted = false;
                el.__nexMuted = false;
            }
        }
        W.setVolume = function (v) {
            v = Math.max(0, Math.min(1, Number(v) || 0));
            W.volume = v;
            for (var i = 0; i < contexts.length; i++) {
                try { contexts[i].__nexGain.gain.value = v; } catch (e) {}
            }
            eachMedia(muteMedia);
            return v;
        };
        W.suspendAudio = function () {
            for (var i = 0; i < contexts.length; i++) {
                var ctx = contexts[i];
                try {
                    if (ctx.state === 'running') {
                        ctx.__nexWasRunning = true;
                        var p = ctx.suspend();
                        if (p && p.catch) p.catch(function () {});
                    }
                } catch (e) {}
            }
        };
        W.resumeAudio = function () {
            for (var i = 0; i < contexts.length; i++) {
                var ctx = contexts[i];
                try {
                    if (ctx.__nexWasRunning) {
                        ctx.__nexWasRunning = false;
                        var p = ctx.resume();
                        if (p && p.catch) p.catch(function () {});
                    }
                } catch (e) {}
            }
        };
        document.addEventListener('play', function (event) {
            var el = event.target;
            if (el && (el.tagName === 'AUDIO' || el.tagName === 'VIDEO')) muteMedia(el);
        }, true);
        if (typeof AudioNode === 'undefined' || !AudioNode.prototype.connect || typeof AudioDestinationNode === 'undefined') return;
        var origConnect = AudioNode.prototype.connect;
        var origDisconnect = AudioNode.prototype.disconnect;
        function live(ctx) { return typeof OfflineAudioContext === 'undefined' || !(ctx instanceof OfflineAudioContext); }
        function master(ctx) {
            if (!ctx.__nexGain) {
                var g = ctx.createGain();
                g.gain.value = W.volume;
                origConnect.call(g, ctx.destination);
                ctx.__nexGain = g;
                contexts.push(ctx);
                if (W.paused) {
                    try { ctx.__nexWasRunning = true; var p = ctx.suspend(); if (p && p.catch) p.catch(function () {}); } catch (e) {}
                }
            }
            return ctx.__nexGain;
        }
        AudioNode.prototype.connect = function (target) {
            try {
                if (target instanceof AudioDestinationNode && live(target.context) && this !== target.context.__nexGain) {
                    var args = Array.prototype.slice.call(arguments);
                    args[0] = master(target.context);
                    origConnect.apply(this, args);
                    return target;
                }
            } catch (e) {}
            return origConnect.apply(this, arguments);
        };
        AudioNode.prototype.disconnect = function (target) {
            if (target instanceof AudioDestinationNode && target.context && target.context.__nexGain && this !== target.context.__nexGain) {
                var args = Array.prototype.slice.call(arguments);
                args[0] = target.context.__nexGain;
                try { return origDisconnect.apply(this, args); } catch (e) { return undefined; }
            }
            return origDisconnect.apply(this, arguments);
        };
    })();
    """#

    static let timeScript = #"""
    (function () {
        var W = window.__nexWeb = window.__nexWeb || {};
        if (W.clock) return;
        W.clock = true;
        W.speed = 1; W.user = false; W.sys = false; W.paused = false;
        var perf = window.performance;
        var realDateNow = Date.now;
        var realNow = (perf && perf.now) ? perf.now.bind(perf) : function () { return realDateNow.call(Date); };
        var baseReal = realNow(), baseFake = baseReal;
        var dateReal = realDateNow.call(Date), dateFake = dateReal;
        function rate() { return W.paused ? 0 : W.speed; }
        function fakeNow() { return baseFake + (realNow() - baseReal) * rate(); }
        function fakeDate() { return dateFake + (realDateNow.call(Date) - dateReal) * rate(); }
        function rebase() {
            var f = fakeNow(), d = fakeDate();
            baseReal = realNow(); baseFake = f;
            dateReal = realDateNow.call(Date); dateFake = d;
        }
        if (perf && perf.now) { try { perf.now = fakeNow; } catch (e) {} }
        Date.now = function () { return Math.floor(fakeDate()); };

        var realRAF = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : null;
        var held = [];
        if (realRAF) {
            window.requestAnimationFrame = function (callback) {
                return realRAF(function () {
                    if (W.paused) { held.push(callback); return; }
                    callback(fakeNow());
                });
            };
        }
        var realSetTimeout = window.setTimeout, realSetInterval = window.setInterval;
        function scaled(args) {
            if (W.speed !== 1 && typeof args[1] === 'number' && args[1] > 0) args[1] = args[1] / W.speed;
            return args;
        }
        window.setTimeout = function () { return realSetTimeout.apply(window, scaled(Array.prototype.slice.call(arguments))); };
        window.setInterval = function () { return realSetInterval.apply(window, scaled(Array.prototype.slice.call(arguments))); };

        function eachMedia(fn) {
            var list = document.querySelectorAll('audio, video');
            for (var i = 0; i < list.length; i++) { try { fn(list[i]); } catch (e) {} }
        }
        function apply() {
            var want = W.user || W.sys;
            if (want === W.paused) return;
            rebase();
            W.paused = want;
            if (want) {
                if (W.suspendAudio) W.suspendAudio();
                eachMedia(function (el) { if (!el.paused) { el.__nexWasPlaying = true; el.pause(); } });
            } else {
                if (W.resumeAudio) W.resumeAudio();
                eachMedia(function (el) {
                    if (el.__nexWasPlaying) {
                        el.__nexWasPlaying = false;
                        var p = el.play();
                        if (p && p.catch) p.catch(function () {});
                    }
                });
                var list = held;
                held = [];
                if (realRAF) {
                    for (var i = 0; i < list.length; i++) {
                        (function (cb) { realRAF(function () { cb(fakeNow()); }); })(list[i]);
                    }
                }
            }
        }
        W.userPause = function (on) { W.user = !!on; apply(); return W.paused; };
        W.setSpeed = function (s) {
            s = Number(s);
            rebase();
            W.speed = s > 0 ? s : 1;
            return W.speed;
        };
        if (!window.__nex) {
            window.__nex = {
                pause: function () { W.sys = true; apply(); },
                resume: function () { W.sys = false; apply(); },
                setSpeed: function (s) { W.setSpeed(s); }
            };
        }
    })();
    """#

    /// Runs Python in Ren'Py (renpy_exec, Ren'Py 7 and 8) and writes the save folder to IndexedDB afterwards.
    static let renpyRunScript = """
    if (typeof renpy_exec !== 'function') { return "Ren'Py is not running yet. Wait for the main menu."; }
    const out = await renpy_exec(code);
    if (typeof FS !== 'undefined' && FS.syncfs) {
        await new Promise(function (resolve) { FS.syncfs(false, function () { resolve(); }); });
    }
    return String(out);
    """

    /// Wraps Python lines so they return 'ok' or the error text in `result`.
    static func renpyPython(_ body: String) -> String {
        let indented = body.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }.joined(separator: "\n")
        return "try:\n" + indented + "\n    renpy.restart_interaction()\n    result = 'ok'\nexcept Exception as e:\n    result = \"Ren'Py: \" + str(e)\n"
    }
}

extension PlayerContext {
    /// Runs a script that returns a string (completion-handler API: the async one traps when a script returns
    /// nothing on some iOS versions).
    func evaluateString(_ script: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    /// A small JPEG of what the game shows.
    func snapshotJPEG(width: CGFloat = 320) async -> Data? {
        guard let webView else { return nil }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(width))
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image?.jpegData(compressionQuality: 0.75))
            }
        }
    }

    /// A short note at the top of the game screen.
    func toast(_ text: String) {
        guard let host = webView?.superview else { return }
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 3
        label.backgroundColor = UIColor(white: 0.08, alpha: 0.9)
        label.layer.cornerRadius = 14
        label.clipsToBounds = true
        label.isUserInteractionEnabled = false
        let maxWidth = min(host.bounds.width - 48, 380)
        let fit = label.sizeThatFits(CGSize(width: maxWidth - 28, height: 120))
        let width = min(fit.width + 28, maxWidth)
        let height = fit.height + 18
        label.frame = CGRect(x: (host.bounds.width - width) / 2, y: host.safeAreaInsets.top + 14, width: width, height: height)
        label.alpha = 0
        host.addSubview(label)
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 2.0, options: [], animations: { label.alpha = 0 }, completion: { _ in
            label.removeFromSuperview()
        })
    }
}

/// Scripts and actions behind the Game Panel's Playback, Sound, Story and Ren'Py cards.
final class WebToolsFeature: PlayerFeature {
    private(set) var speed: Double = 1
    private(set) var paused = false

    override func userScripts(for game: Game) -> [WKUserScript] {
        let volume = AssistOptions.load(for: game.id).volume
        var scripts = [WKUserScript(source: WebTools.audioScript(volume: volume), injectionTime: .atDocumentStart, forMainFrameOnly: true)]
        if game.engine.isWebGame {
            scripts.append(WKUserScript(source: WebTools.timeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        return scripts
    }

    override func didFinishLoad() {
        // A reload starts the game at normal speed, not paused.
        speed = 1
        paused = false
        let volume = AssistOptions.load(for: context.game().id).volume
        previewVolume(volume)
    }

    static func speedText(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%.1f×", value)
    }

    func setPaused(_ on: Bool, quiet: Bool = false) {
        paused = on
        context.evaluate("window.__nexWeb && window.__nexWeb.userPause && window.__nexWeb.userPause(\(on))")
        context.gameLog.add(on ? "game paused" : "game resumed")
        if !quiet { context.toast(on ? "Paused" : "Resumed") }
    }

    func setSpeed(_ value: Double, quiet: Bool = false) {
        speed = value
        context.evaluate("window.__nexWeb && window.__nexWeb.setSpeed && window.__nexWeb.setSpeed(\(value))")
        context.gameLog.add("game speed \(WebToolsFeature.speedText(value))")
        if !quiet { context.toast(value == 1 ? "Normal speed" : "Speed \(WebToolsFeature.speedText(value))") }
    }

    /// Changes the volume in the page without saving it (while a slider moves).
    func previewVolume(_ value: Double) {
        context.evaluate("window.__nexWeb && window.__nexWeb.setVolume && window.__nexWeb.setVolume(\(value))")
    }

    /// Changes the volume and keeps it for the game.
    func setVolume(_ value: Double, quiet: Bool = false) {
        let id = context.game().id
        var options = AssistOptions.load(for: id)
        options.volume = value
        options.save(for: id)
        previewVolume(value)
        if !quiet { context.toast(value == 0 ? "Muted" : "Volume \(Int(value * 100))%") }
    }

    /// Twine (SugarCube) "back" or "forward". Returns "ok" or why it didn't work.
    func runTwine(_ action: String) async -> String {
        let safe = action == "back" ? "back" : "forward"
        let script = "window.__nexAssist && window.__nexAssist.\(safe) ? window.__nexAssist.\(safe)() : 'The story is still starting.'"
        return await context.evaluateString(script) ?? "The story didn't answer."
    }

    /// Runs Ren'Py Python; returns `done` when it worked, else Ren'Py's error text.
    func runRenPy(_ body: String, done: String) async -> String {
        guard let webView = context.webView else { return "The game isn't running." }
        let python = WebTools.renpyPython(body)
        do {
            let value = try await webView.callAsyncJavaScript(WebTools.renpyRunScript, arguments: ["code": python],
                                                              in: nil, contentWorld: .page)
            let text = value as? String ?? ""
            if text == "ok" {
                context.gameLog.add("ren'py: \(done)")
                return done
            }
            context.gameLog.add("ren'py tools: \(text)")
            return text.isEmpty ? "Ren'Py didn't answer." : text
        } catch {
            context.gameLog.add("ren'py tools failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
