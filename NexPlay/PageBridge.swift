import Foundation
import WebKit

// The RPG Maker runtime script and the NW.js shim are adapted from mvmz-apple-mobile's runtime.js (speed, pause and
// resume, focus handling, require/process/nw, fs over synchronous requests).
// Copyright (C) 2026 Mateo M., https://github.com/mateo-m/mvmz-apple-mobile
// and https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms).
// NexPlay keeps the Gamepad API untouched (Empo disables it): physical controllers reach games through it.

/// JavaScript NexPlay injects into game pages.
enum PageScripts {
    /// A desktop Safari user agent. With a phone user agent RPG Maker MV asks for .m4a audio many games don't ship,
    /// MV drops its fixed update rate, and MZ uses only 90% of the screen height.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// A JavaScript string literal for `text` (quotes and backslashes escaped).
    static func jsString(_ text: String) -> String {
        if let data = try? JSONEncoder().encode([text]),
           let array = String(data: data, encoding: .utf8),
           array.count >= 2 {
            return String(array.dropFirst().dropLast())
        }
        return "\"\""
    }

    /// Lets games know they run in NexPlay: window.nexplay.version.
    static func identity(version: String) -> String {
        "window.nexplay = Object.freeze({ version: \(jsString(version)), platform: 'ios' });"
    }

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
        var size = '';

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

        function reportSize() {
            // A game or a plugin can change the resolution from any script, and no event reports it.
            if (typeof Graphics === 'undefined' || !Graphics.width) return;
            var next = Graphics.width + 'x' + Graphics.height;
            if (next === size) return;
            size = next;
            try { window.webkit.messageHandlers.nexSize.postMessage({ width: Graphics.width, height: Graphics.height }); } catch (e) {}
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
            reportSize();
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

        // Screen scaling: "fit" is RPG Maker's own letterbox. "fill" crops to cover the screen, "stretch" fills it
        // and changes the aspect. Both replace Graphics._centerElement and map touches through the canvas rect.
        if (cfg.scaling === 'fill' || cfg.scaling === 'stretch') {
            (function patchScaling() {
                if (typeof Graphics === 'undefined' || !Graphics._centerElement) { setTimeout(patchScaling, 30); return; }
                if (Graphics.__nexScaled) return;
                Graphics.__nexScaled = true;
                var fill = cfg.scaling === 'fill';
                Graphics._centerElement = function (element) {
                    if (!element) return;
                    var vw = window.innerWidth, vh = window.innerHeight;
                    var w = element.width || this._width, h = element.height || this._height;
                    if (!w || !h || !vw || !vh) return;
                    var sx = vw / w, sy = vh / h;
                    if (fill) { sx = sy = Math.max(sx, sy); }
                    var cw = w * sx, ch = h * sy;
                    var style = element.style;
                    style.position = 'absolute';
                    style.margin = '0';
                    style.right = 'auto';
                    style.bottom = 'auto';
                    style.left = ((vw - cw) / 2) + 'px';
                    style.top = ((vh - ch) / 2) + 'px';
                    style.width = cw + 'px';
                    style.height = ch + 'px';
                };
                Graphics.pageToCanvasX = function (x) {
                    var c = this._canvas;
                    if (!c) return 0;
                    var r = c.getBoundingClientRect();
                    return Math.round((x - r.left) * c.width / (r.width || 1));
                };
                Graphics.pageToCanvasY = function (y) {
                    var c = this._canvas;
                    if (!c) return 0;
                    var r = c.getBoundingClientRect();
                    return Math.round((y - r.top) * c.height / (r.height || 1));
                };
                try { if (Graphics._updateAllElements && Graphics._canvas) Graphics._updateAllElements(); } catch (e) {}
            })();
        }

        if (cfg.pixelated) {
            document.addEventListener('DOMContentLoaded', function () {
                var s = document.createElement('style');
                s.textContent = 'canvas, video { image-rendering: pixelated; }';
                document.head.appendChild(s);
            });
        }
    })();
    """#

    static func rpgRuntime(pixelated: Bool, scaling: ScreenScaling = .fit) -> String {
        "window.__nexSettings = { pixelated: \(pixelated ? "true" : "false"), scaling: '\(scaling.rawValue)' };\n"
            + rpgRuntimeBody
    }

    /// NW.js shim for RPG Maker games: window.require (fs, path, os, nw.gui), window.nw, window.process.
    /// With it Utils.isNwjs() is true and MV/MZ keep saves as files in save/ next to index.html.
    /// fs calls become synchronous requests to NexSchemeHandler. "/" is the folder of the entry page.
    private static let nwShimBody = #"""
    (function () {
        'use strict';
        var base = String(window.__nexBase || '').split('/').map(encodeURIComponent).join('/');
        var origin = location.protocol + '//' + location.host;
        function exit() {
            try { window.webkit.messageHandlers.nexExit.postMessage('exit'); } catch (e) {}
        }
        function noop() {}

        var proc = {
            platform: 'linux',
            env: {},
            argv: [],
            execPath: '/',
            // No "node" version here: Emscripten code (MZ's Effekseer, some plugins) would think it runs in Node.js,
            // look for __dirname and stop the game before it draws anything. Empo leaves versions empty too.
            versions: {},
            cwd: function () { return '/'; },
            exit: exit,
            on: noop,
            once: noop,
            nextTick: function (fn) { setTimeout(fn, 0); },
            // MZ's main.js stops when this starts with /private/var, so it stays relative to the game folder.
            mainModule: { filename: '/index.html' }
        };

        // MARK: path
        function normalize(p) {
            var parts = [];
            String(p).split('/').forEach(function (part) {
                if (part === '..') parts.pop();
                else if (part && part !== '.') parts.push(part);
            });
            var tail = String(p).slice(-1) === '/' && parts.length ? '/' : '';
            return ((String(p).charAt(0) === '/' ? '/' : '') + parts.join('/') + tail) || '.';
        }
        var path = {
            sep: '/',
            delimiter: ':',
            normalize: normalize,
            join: function () { return normalize(Array.prototype.filter.call(arguments, Boolean).join('/')); },
            resolve: function () {
                var out = proc.cwd();
                Array.prototype.forEach.call(arguments, function (part) {
                    part = String(part);
                    out = part.charAt(0) === '/' ? part : out + '/' + part;
                });
                return normalize(out).replace(/(.)\/$/, '$1');
            },
            isAbsolute: function (p) { return String(p).charAt(0) === '/'; },
            dirname: function (p) {
                var trimmed = String(p).replace(/\/+$/, '');
                var i = trimmed.lastIndexOf('/');
                return i < 0 ? '.' : i === 0 ? '/' : trimmed.slice(0, i);
            },
            basename: function (p, ext) {
                var b = String(p).replace(/\/+$/, '').split('/').pop();
                return ext && b.slice(-ext.length) === ext ? b.slice(0, -ext.length) : b;
            },
            extname: function (p) {
                var b = path.basename(p);
                var i = b.lastIndexOf('.');
                return i > 0 ? b.slice(i) : '';
            },
            relative: function (from, to) {
                var a = path.resolve(from).split('/').filter(Boolean);
                var b = path.resolve(to).split('/').filter(Boolean);
                while (a.length && b.length && a[0] === b[0]) { a.shift(); b.shift(); }
                return a.map(function () { return '..'; }).concat(b).join('/');
            }
        };
        path.posix = path;

        // MARK: fs
        function urlFor(p) {
            return origin + base + path.resolve(String(p)).split('/').map(encodeURIComponent).join('/');
        }
        function send(method, p, body, binary, list) {
            var xhr = new XMLHttpRequest();
            xhr.open(method, urlFor(p), false);
            if (binary) xhr.overrideMimeType('text/plain; charset=x-user-defined');
            if (list) xhr.setRequestHeader('X-Nex-List', '1');
            xhr.send(body === undefined ? null : body);
            return xhr;
        }
        function fail(xhr, op, p) {
            var code = xhr.status === 404 ? 'ENOENT' : xhr.status === 403 ? 'EPERM' : 'EIO';
            var error = new Error(code + ': ' + op + " '" + p + "' (" + xhr.status + ')');
            error.code = code;
            throw error;
        }
        function ok(xhr, op, p) {
            if (xhr.status === 0 || xhr.status >= 300) fail(xhr, op, p);
            return xhr;
        }
        function decodeUTF8(bytes) {
            try { return new TextDecoder('utf-8').decode(bytes); } catch (e) { return ''; }
        }
        function stat(p) {
            var xhr = ok(send('HEAD', p), 'stat', p);
            var directory = xhr.getResponseHeader('X-Nex-Kind') === 'directory';
            var mtime = new Date(Number(xhr.getResponseHeader('X-Nex-Mtime')) || 0);
            return {
                size: Number(xhr.getResponseHeader('Content-Length')) || 0,
                mtime: mtime, mtimeMs: mtime.getTime(), ctime: mtime, birthtime: mtime,
                isFile: function () { return !directory; },
                isDirectory: function () { return directory; },
                isSymbolicLink: function () { return false; }
            };
        }
        function bodyFor(data) {
            if (data === undefined || data === null) return '';
            if (typeof data === 'string') return data;
            if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) return data;
            return String(data);
        }

        var fs = {
            existsSync: function (p) { try { return send('HEAD', p).status === 200; } catch (e) { return false; } },
            statSync: stat,
            lstatSync: stat,
            readFileSync: function (p, options) {
                var encoding = typeof options === 'string' ? options : options && options.encoding;
                var xhr = ok(send('GET', p, null, !encoding), 'open', p);
                if (encoding) return xhr.responseText;
                var text = xhr.responseText;
                var bytes = new Uint8Array(text.length);
                for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
                bytes.toString = function () { return decodeUTF8(this); };
                return bytes;
            },
            writeFileSync: function (p, data) { ok(send('PUT', p, bodyFor(data)), 'open', p); },
            appendFileSync: function (p, data) {
                var old = fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
                fs.writeFileSync(p, old + String(data));
            },
            copyFileSync: function (from, to) { fs.writeFileSync(to, fs.readFileSync(from)); },
            unlinkSync: function (p) { ok(send('DELETE', p), 'unlink', p); },
            rmdirSync: function (p) { ok(send('DELETE', p), 'rmdir', p); },
            rmSync: function (p) { if (fs.existsSync(p)) ok(send('DELETE', p), 'rm', p); },
            mkdirSync: function (p) { ok(send('MKCOL', p), 'mkdir', p); },
            readdirSync: function (p) { return JSON.parse(ok(send('GET', p, null, false, true), 'scandir', p).responseText); },
            renameSync: function (from, to) {
                var xhr = new XMLHttpRequest();
                xhr.open('MOVE', urlFor(from), false);
                xhr.setRequestHeader('Destination', urlFor(to));
                xhr.send(null);
                ok(xhr, 'rename', from);
            }
        };
        // Some plugins use the callback forms. They run the same requests one tick later.
        ['readFile', 'writeFile', 'appendFile', 'copyFile', 'unlink', 'mkdir', 'readdir', 'stat', 'lstat', 'rename', 'rmdir'].forEach(function (name) {
            fs[name] = function () {
                var args = Array.prototype.slice.call(arguments);
                var callback = typeof args[args.length - 1] === 'function' ? args.pop() : noop;
                setTimeout(function () {
                    var result;
                    try { result = fs[name + 'Sync'].apply(null, args); } catch (error) { callback(error); return; }
                    callback(null, result);
                }, 0);
            };
        });
        fs.exists = function (p, callback) { setTimeout(function () { callback(fs.existsSync(p)); }, 0); };

        // MARK: NW.js
        var nwWindow = new Proxy({}, { get: function (target, key) { return key in target ? target[key] : noop; } });
        var nwApp = { argv: [], manifest: {}, dataPath: '/', quit: exit, closeAllWindows: exit };
        function NwMenu() {}
        NwMenu.prototype.createMacBuiltin = noop;
        NwMenu.prototype.append = noop;
        var nwGui = { App: nwApp, Window: { get: function () { return nwWindow; } }, Menu: NwMenu, Shell: { openExternal: noop } };
        var os = {
            platform: function () { return 'linux'; },
            type: function () { return 'Linux'; },
            homedir: function () { return '/'; },
            tmpdir: function () { return '/'; },
            EOL: '\n'
        };
        var modules = { fs: fs, path: path, os: os, 'nw.gui': nwGui };

        window.nw = nwGui;
        window.require = function (name) {
            var found = modules[String(name).replace(/^node:/, '')];
            if (found) return found;
            var error = new Error("Cannot find module '" + name + "'");
            error.code = 'MODULE_NOT_FOUND';
            throw error;
        };
        window.process = proc;
        window.chrome = Object.assign(window.chrome || {}, { runtime: { reload: function () { location.reload(); } } });
        window.close = exit;
    })();
    """#

    /// `entryFolder` is the folder of the entry page relative to the game folder ("" or "www").
    static func nwShim(entryFolder: String) -> String {
        let base = entryFolder.isEmpty ? "" : "/" + entryFolder
        return "window.__nexBase = \(jsString(base));\n" + nwShimBody
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

/// Receives simple messages from a game page (exit requests, size reports).
final class MessageReceiver: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message.body)
    }
}
