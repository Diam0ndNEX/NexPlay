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

    /// Replaces service workers with an inert stub for RenPyWeb, which registers one to cache its files: a worker
    /// would keep serving old files after the game or the runtime changes. A stub, not undefined: code that checks
    /// `'serviceWorker' in navigator` (Godot's web runtime) would then call methods on undefined and fail.
    static let noServiceWorker = #"""
    (function () {
        var stub = {
            controller: null,
            ready: new Promise(function () {}),
            register: function () { return Promise.resolve(undefined); },
            getRegistration: function () { return Promise.resolve(undefined); },
            getRegistrations: function () { return Promise.resolve([]); },
            addEventListener: function () {},
            removeEventListener: function () {},
            startMessages: function () {}
        };
        try { Object.defineProperty(navigator, 'serviceWorker', { value: stub, configurable: true }); } catch (e) {}
    })();
    """#

    /// 8.18.0: the page is laid out at the web view's real size (1 CSS pixel = 1 point) and can't be zoomed.
    /// RPG Maker MV's index.html only has `user-scalable=no`, so WebKit laid it out 980 px wide and zoomed it, and
    /// kept a zoom from before a rotation: the game came up zoomed in or cut off until the screen size changed.
    /// `force` (RPG Maker) replaces the page's viewport; otherwise only a viewport without a width is fixed.
    static func viewport(force: Bool) -> String {
        let body = #"""
        (function () {
            var WANT = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
            function fix() {
                var head = document.head || document.documentElement;
                if (!head) return;
                var metas = document.querySelectorAll('meta[name="viewport"]');
                if (!metas.length) {
                    var m = document.createElement('meta');
                    m.name = 'viewport';
                    m.content = WANT;
                    head.insertBefore(m, head.firstChild);
                    return;
                }
                for (var i = 0; i < metas.length; i++) {
                    var c = String(metas[i].getAttribute('content') || '');
                    if (FORCE || !/width\s*=/.test(c)) {
                        if (metas[i].getAttribute('content') !== WANT) metas[i].setAttribute('content', WANT);
                    }
                }
            }
            fix();
            document.addEventListener('DOMContentLoaded', fix);
            window.addEventListener('load', fix);
        })();
        """#
        return "var FORCE = \(force ? "true" : "false");\n" + body
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

    /// 8.12.2: a tap that never turned into a click (iOS skips the click when the page changes on hover, or a
    /// touch handler cancels it) is sent as a click to the element under the finger, once, after 350 ms.
    static let tapFallback = #"""
    (function () {
        var sx = 0, sy = 0, moved = false, lastClick = 0, t0 = 0;
        document.addEventListener('click', function () { lastClick = Date.now(); }, true);
        document.addEventListener('touchstart', function (e) {
            if (e.touches.length !== 1) { moved = true; return; }
            moved = false; t0 = Date.now();
            sx = e.touches[0].clientX; sy = e.touches[0].clientY;
        }, { capture: true, passive: true });
        document.addEventListener('touchmove', function (e) {
            var t = e.touches[0];
            if (t && (Math.abs(t.clientX - sx) > 10 || Math.abs(t.clientY - sy) > 10)) moved = true;
        }, { capture: true, passive: true });
        document.addEventListener('touchend', function (e) {
            if (moved || Date.now() - t0 > 500) return;
            var t = e.changedTouches[0];
            if (!t) return;
            var x = t.clientX, y = t.clientY, stamp = Date.now();
            setTimeout(function () {
                if (lastClick >= stamp - 20) return;
                var el = document.elementFromPoint(x, y);
                if (!el) return;
                var tag = (el.tagName || '').toLowerCase();
                if (tag === 'canvas' || tag === 'video' || tag === 'html' || tag === 'body') return;
                try {
                    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
                } catch (err) {}
            }, 350);
        }, { capture: true, passive: true });
    })();
    """#

    /// window.__nexKey(keyCode, key, code, down) lets the on-screen controls press keyboard keys.
    static let keyBridge = #"""
    (function () {
        // Keys go to the focused element when there is one (text fields, Godot's focused canvas), else to the
        // first canvas, and bubble up to document and window, so RPG Maker (document), Godot and Construct (canvas
        // or window) and plain pages all see them.
        function target() {
            var a = document.activeElement;
            if (a && a !== document.body && a !== document.documentElement) return a;
            return document.querySelector('canvas') || document;
        }
        window.__nexKey = function (kc, key, code, down) {
            var type = down ? 'keydown' : 'keyup';
            var e;
            try {
                e = new KeyboardEvent(type, { key: key, code: code, bubbles: true, cancelable: true, composed: true });
            } catch (err) {
                e = new Event(type, { bubbles: true, cancelable: true });
            }
            try {
                Object.defineProperty(e, 'keyCode', { get: function () { return kc; } });
                Object.defineProperty(e, 'which', { get: function () { return kc; } });
                Object.defineProperty(e, 'charCode', { get: function () { return 0; } });
                Object.defineProperty(e, 'key', { get: function () { return key; } });
                Object.defineProperty(e, 'code', { get: function () { return code; } });
            } catch (err) {}
            target().dispatchEvent(e);
            if (down && key && key.length === 1) {
                try {
                    var p = new KeyboardEvent('keypress', { key: key, code: code, bubbles: true, cancelable: true });
                    Object.defineProperty(p, 'keyCode', { get: function () { return key.charCodeAt(0); } });
                    Object.defineProperty(p, 'charCode', { get: function () { return key.charCodeAt(0); } });
                    Object.defineProperty(p, 'which', { get: function () { return key.charCodeAt(0); } });
                    target().dispatchEvent(p);
                } catch (err) {}
            }
        };
        // A mouse-wheel notch at the middle of the game (scroll buttons on the touch controls).
        window.__nexWheel = function (dy) {
            var el = document.querySelector('canvas') || document.body || document;
            var r = el.getBoundingClientRect ? el.getBoundingClientRect() : { left: 0, top: 0, width: innerWidth, height: innerHeight };
            var x = r.left + r.width / 2, y = r.top + r.height / 2;
            var e;
            try {
                e = new WheelEvent('wheel', { deltaY: dy, deltaMode: 0, clientX: x, clientY: y, bubbles: true, cancelable: true });
            } catch (err) {
                e = new Event('wheel', { bubbles: true, cancelable: true });
                try { Object.defineProperty(e, 'deltaY', { get: function () { return dy; } }); } catch (err2) {}
            }
            el.dispatchEvent(e);
        };
    })();
    """#

    /// window.__nexStats(true/false) starts or stops frame-rate reporting to the app.
    static let stats = #"""
    (function () {
        var on = false, frames = 0, last = 0, prev = 0, worst = 0;
        function loop(t) {
            if (!on) return;
            frames++;
            if (prev > 0 && t - prev > worst) worst = t - prev;
            prev = t;
            if (t - last >= 1000) {
                try { window.webkit.messageHandlers.nexStats.postMessage([Math.round(frames * 1000 / (t - last)), Math.round(worst)]); } catch (e) {}
                frames = 0; last = t; worst = 0;
            }
            requestAnimationFrame(loop);
        }
        window.__nexStats = function (v) {
            if (v && !on) { on = true; frames = 0; worst = 0; prev = 0; last = performance.now(); requestAnimationFrame(loop); }
            else if (!v) { on = false; }
        };
    })();
    """#

    /// Sends console output, script errors and files that failed to load to the app's game log.
    /// Limited to 20 lines a second so a game that logs every frame can't slow itself down.
    static let diagnostics = #"""
    (function () {
        var count = 0, windowStart = Date.now();
        function allowed() {
            var now = Date.now();
            if (now - windowStart > 1000) { windowStart = now; count = 0; }
            return ++count <= 20;
        }
        function send(text) {
            try { window.webkit.messageHandlers.nexLog.postMessage(String(text).slice(0, 2000)); } catch (e) {}
        }
        // 8.18.0: objects are written with a budget (depth 3, ~1500 characters). JSON.stringify of a whole game
        // object (a game that logs $gameParty in every battle) cost a frame each time.
        function brief(v, depth, budget) {
            if (budget.left <= 0) return '…';
            if (v === null || v === undefined) return String(v);
            var t = typeof v;
            if (t === 'string') { budget.left -= v.length + 2; return JSON.stringify(v.length > 300 ? v.slice(0, 300) + '…' : v); }
            if (t === 'number' || t === 'boolean') { budget.left -= 6; return String(v); }
            if (t === 'function') { budget.left -= 10; return 'function'; }
            if (t !== 'object') return String(v);
            if (v instanceof Error) return String(v.stack || v);
            if (depth <= 0) { budget.left -= 6; return Array.isArray(v) ? '[…]' : '{…}'; }
            var out = [], n = 0;
            if (Array.isArray(v)) {
                for (var i = 0; i < v.length && budget.left > 0; i++) { if (++n > 40) { out.push('…'); break; } out.push(brief(v[i], depth - 1, budget)); }
                return '[' + out.join(',') + ']';
            }
            for (var k in v) {
                if (!Object.prototype.hasOwnProperty.call(v, k)) continue;
                if (budget.left <= 0 || ++n > 40) { out.push('…'); break; }
                budget.left -= k.length + 3;
                var item;
                try { item = brief(v[k], depth - 1, budget); } catch (e) { item = '?'; }
                out.push(JSON.stringify(k) + ':' + item);
            }
            return '{' + out.join(',') + '}';
        }
        function show(a) {
            try { return typeof a === 'object' && a !== null ? brief(a, 3, { left: 1500 }) : String(a); } catch (e) { return String(a); }
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

    /// 8.18.0 RPG Maker MV/MZ speed-ups for iOS (menus opened with a delay and dropped frames):
    /// - Sound effects are kept after their first load: MV and MZ load (and MV decodes) the file again every time a
    ///   sound plays, so every cursor move in a menu was a file request plus a decode. MV keeps the decoded sound
    ///   (up to ~16 MB), MZ the file bytes.
    /// - A cheaper blur for the menu background (MV blurs the map picture with 26 full-screen canvas draws).
    /// - Videos: the .mp4 is used when the game has one (iOS decodes WebM in software), the other file is tried
    ///   when one fails, and a video that can't play is skipped instead of stopping the game with a load error.
    static let rpgSpeedups = #"""
    (function () {
        if (window.__nexSpeedups) return;
        window.__nexSpeedups = true;
        function note(text) { try { window.webkit.messageHandlers.nexLog.postMessage('speed-ups: ' + text); } catch (e) {} }
        function cacheable(url) { return /\/se\//i.test(String(url || '')); }

        // MARK: MZ: sound effect bytes (fetch)
        var bytes = {}, bytesTotal = 0;
        if (window.fetch) {
            var nativeFetch = window.fetch.bind(window);
            window.fetch = function (input, init) {
                var url = typeof input === 'string' ? input : (input && input.url) || '';
                if (!cacheable(url) || (init && init.method && String(init.method).toUpperCase() !== 'GET')) return nativeFetch.apply(null, arguments);
                var hit = bytes[url];
                if (hit) return Promise.resolve(new Response(hit.slice(0), { status: 200, headers: { 'Content-Type': 'application/octet-stream' } }));
                return nativeFetch.apply(null, arguments).then(function (response) {
                    if (!response.ok || bytesTotal > 12e6) return response;
                    return response.arrayBuffer().then(function (buf) {
                        if (!bytes[url]) { bytes[url] = buf; bytesTotal += buf.byteLength; }
                        return new Response(buf.slice(0), { status: response.status, headers: { 'Content-Type': 'application/octet-stream' } });
                    });
                });
            };
        }

        // MARK: MV: decoded sound effects (XHR + decodeAudioData)
        var decoded = {}, order = [], decodedBytes = 0, decodeKey = null;
        function keep(key, raw, buffer) {
            if (decoded[key]) return;
            var size = (buffer.length || 0) * (buffer.numberOfChannels || 1) * 4 + (raw ? raw.byteLength : 0);
            decoded[key] = { raw: raw, buffer: buffer, size: size };
            order.push(key);
            decodedBytes += size;
            while (decodedBytes > 16e6 && order.length > 1) {
                var old = order.shift();
                if (decoded[old]) { decodedBytes -= decoded[old].size; delete decoded[old]; }
            }
        }
        function wrapContext(ctx) {
            if (!ctx || ctx.__nexDecode || !ctx.decodeAudioData) return;
            ctx.__nexDecode = true;
            var nativeDecode = ctx.decodeAudioData.bind(ctx);
            ctx.decodeAudioData = function (data, ok, fail) {
                var job = decodeKey;
                decodeKey = null;
                if (job && decoded[job.key]) {
                    var b = decoded[job.key].buffer;
                    if (ok) setTimeout(function () { ok(b); }, 0);
                    return Promise.resolve(b);
                }
                var p = nativeDecode(data, function (buffer) {
                    if (job) keep(job.key, job.raw, buffer);
                    if (ok) ok(buffer);
                }, function (e) { if (fail) fail(e); });
                if (p && p.catch) p.catch(function () {});
                return p;
            };
        }
        (function hookMV(tries) {
            if (typeof WebAudio === 'undefined') { if ((tries || 0) < 400) setTimeout(function () { hookMV((tries || 0) + 1); }, 50); return; }
            var proto = WebAudio.prototype;
            // MZ's WebAudio has no _onXhrLoad: it fetches (handled above).
            if (!proto._load || !proto._onXhrLoad || proto.__nexSE) return;
            proto.__nexSE = true;
            var load = proto._load;
            proto._load = function (url) {
                var ctx = WebAudio._context;
                if (!ctx || !cacheable(url)) return load.apply(this, arguments);
                wrapContext(ctx);
                var self = this;
                var real = url;
                try { if (typeof Decrypter !== 'undefined' && Decrypter.hasEncryptedAudio) real = Decrypter.extToEncryptExt(url); } catch (e) {}
                var hit = decoded[real];
                if (hit) {
                    setTimeout(function () {
                        decodeKey = { key: real, raw: null };
                        try { self._onXhrLoad({ status: 200, response: hit.raw.slice(0) }); } catch (e) {}
                        decodeKey = null;
                    }, 0);
                    return;
                }
                var xhr = new XMLHttpRequest();
                xhr.open('GET', real);
                xhr.responseType = 'arraybuffer';
                xhr.onload = function () {
                    if (xhr.status < 400) {
                        var raw = null;
                        try { raw = xhr.response.slice(0); } catch (e) {}
                        decodeKey = raw ? { key: real, raw: raw } : null;
                        try { self._onXhrLoad(xhr); } finally { decodeKey = null; }
                    }
                };
                xhr.onerror = this._loader || function () { self._hasError = true; };
                xhr.send();
            };
        })();

        // MARK: cheaper menu background blur
        (function hookBlur(tries) {
            if (typeof Bitmap === 'undefined') { if ((tries || 0) < 400) setTimeout(function () { hookBlur((tries || 0) + 1); }, 50); return; }
            if (Bitmap.prototype.__nexBlur || !Bitmap.prototype.blur) return;
            Bitmap.prototype.__nexBlur = true;
            var tmp = null;
            var slowBlur = Bitmap.prototype.blur;
            Bitmap.prototype.blur = function () {
                try {
                    var w = this.width, h = this.height;
                    var canvas = this.canvas || this._canvas, ctx = this.context || this._context;
                    if (!w || !h || !canvas || !ctx) return slowBlur.apply(this, arguments);
                    var sw = Math.max(1, Math.round(w / 3)), sh = Math.max(1, Math.round(h / 3));
                    if (!tmp) tmp = document.createElement('canvas');
                    if (tmp.width !== sw) tmp.width = sw;
                    if (tmp.height !== sh) tmp.height = sh;
                    var t = tmp.getContext('2d');
                    t.imageSmoothingEnabled = true;
                    t.clearRect(0, 0, sw, sh);
                    t.drawImage(canvas, 0, 0, w, h, 0, 0, sw, sh);
                    ctx.save();
                    ctx.imageSmoothingEnabled = true;
                    ctx.globalCompositeOperation = 'copy';
                    ctx.drawImage(tmp, 0, 0, sw, sh, 0, 0, w, h);
                    ctx.restore();
                    if (this._setDirty) this._setDirty();
                } catch (e) {
                    return slowBlur.apply(this, arguments);
                }
            };
        })();

        // MARK: 8.18.3 media play() promises
        // Pausing a game (Game Panel, cheat engine, going to the background) pauses its <audio>/<video>; a play()
        // the game started then rejects with AbortError, and MZ stops the game on an unhandled rejection. The
        // promise is returned unchanged; only an empty catch is added so the rejection counts as handled.
        try {
            var nativePlay = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function () {
                var p = nativePlay.apply(this, arguments);
                if (p && p.catch) p.catch(function () {});
                return p;
            };
        } catch (e) {}

        // MARK: 8.18.3 Script commands with a line break inside a string
        // Event Script commands (355 + 655 lines) are joined with "\n"; a quoted text written over two lines then
        // is not valid JavaScript ("SCRIPT CALL ERROR", the command does nothing, also on PC). When the joined
        // script does not compile, but does with the line breaks inside quotes written as \n, the fixed script
        // is used. The command count stays the same (655 lines become empty), so saved event positions still match.
        function quoteBreaks(code) {
            var out = '', quote = null;
            for (var i = 0; i < code.length; i++) {
                var c = code.charAt(i);
                if (quote) {
                    if (c === '\\') { out += c + code.charAt(i + 1); i++; continue; }
                    if (c === quote) quote = null;
                    else if (c === '\n' && quote !== '`') { out += '\\n'; continue; }
                    else if (c === '\r') continue;
                } else if (c === '"' || c === "'" || c === '`') {
                    quote = c;
                }
                out += c;
            }
            return out;
        }
        function compiles(code) { try { new Function(code); return true; } catch (e) { return false; } }
        var scriptFixes = 0;
        function fixList(list) {
            if (!list || !list.length) return;
            for (var i = 0; i < list.length; i++) {
                var cmd = list[i];
                if (!cmd || cmd.code !== 355) continue;
                var j = i + 1, lines = [String(cmd.parameters[0])];
                while (list[j] && list[j].code === 655) { lines.push(String(list[j].parameters[0])); j++; }
                if (lines.length < 2) continue;
                var code = lines.join('\n');
                if (compiles(code)) continue;
                var fixed = quoteBreaks(code);
                if (fixed === code || !compiles(fixed)) continue;
                cmd.parameters[0] = fixed;
                for (var k = i + 1; k < j; k++) list[k].parameters[0] = '';
                if (++scriptFixes <= 10) note('fixed a Script command with a line break inside quotes: ' + fixed.slice(0, 80));
            }
        }
        function fixPages(pages) { (pages || []).forEach(function (page) { if (page) fixList(page.list); }); }
        (function hookData(tries) {
            if (typeof DataManager === 'undefined' || !DataManager.onLoad) { if ((tries || 0) < 400) setTimeout(function () { hookData((tries || 0) + 1); }, 50); return; }
            if (DataManager.__nexScripts) return;
            DataManager.__nexScripts = true;
            var onLoad = DataManager.onLoad;
            DataManager.onLoad = function (object) {
                try {
                    if (object === window.$dataMap && object && object.events) {
                        object.events.forEach(function (ev) { if (ev) fixPages(ev.pages); });
                    } else if (object === window.$dataCommonEvents) {
                        object.forEach(function (ce) { if (ce) fixList(ce.list); });
                    } else if (object === window.$dataTroops) {
                        object.forEach(function (troop) { if (troop) fixPages(troop.pages); });
                    }
                } catch (e) {}
                return onLoad.apply(this, arguments);
            };
        })();

        // MARK: videos
        var exists = {};
        function fileExists(url) {
            if (url in exists) return exists[url];
            var found = false;
            try {
                var xhr = new XMLHttpRequest();
                xhr.open('HEAD', url, false);
                xhr.send(null);
                found = xhr.status >= 200 && xhr.status < 300;
            } catch (e) {}
            exists[url] = found;
            return found;
        }
        function other(src) {
            if (/\.webm(\?|#|$)/i.test(src)) return src.replace(/\.webm(?=(\?|#|$))/i, '.mp4');
            if (/\.mp4(\?|#|$)/i.test(src)) return src.replace(/\.mp4(?=(\?|#|$))/i, '.webm');
            return null;
        }
        function preferMp4(src) {
            if (!/\.webm(\?|#|$)/i.test(src)) return src;
            var mp4 = other(src);
            return mp4 && fileExists(mp4) ? mp4 : src;
        }
        function guard(element, src, retry, giveUp) {
            var alt = other(src), tried = false;
            var original = element.onerror;
            element.onerror = function () {
                if (!tried && alt && fileExists(alt)) {
                    tried = true;
                    note('video ' + src.split('/').pop() + ' could not play, trying ' + alt.split('/').pop());
                    retry(alt);
                    return;
                }
                note('video ' + src.split('/').pop() + ' could not play; skipped');
                giveUp(original);
            };
        }
        (function hookVideo(tries) {
            if (typeof Graphics === 'undefined') { if ((tries || 0) < 400) setTimeout(function () { hookVideo((tries || 0) + 1); }, 50); return; }
            if (Graphics._playVideo && !Graphics.__nexVideo) {
                // MV
                Graphics.__nexVideo = true;
                var playMV = Graphics._playVideo;
                Graphics._playVideo = function (src) {
                    var first = preferMp4(String(src));
                    playMV.call(this, first);
                    var self = this;
                    if (this._video) guard(this._video, first, function (alt) {
                        playMV.call(self, alt);
                        if (self._video) self._video.onerror = function () { note('video skipped'); try { self._onVideoError(); } catch (e) {} };
                    }, function () { try { self._onVideoError(); } catch (e) {} });
                };
            }
            if (typeof Video !== 'undefined' && Video.play && !Video.__nexVideo) {
                // MZ
                Video.__nexVideo = true;
                var playMZ = Video.play;
                Video.play = function (src) {
                    var first = preferMp4(String(src));
                    playMZ.call(this, first);
                    var self = this;
                    if (this._element) guard(this._element, first, function (alt) {
                        playMZ.call(self, alt);
                        if (self._element) self._element.onerror = function () { note('video skipped'); try { self._loading = false; self._onEnd(); } catch (e) {} };
                    }, function () { try { self._loading = false; self._onEnd(); } catch (e) {} });
                };
            }
        })();
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

        // 8.18.0 Screen size. One place decides how big the picture is, for every mode, and it can change while
        // the game runs (window.__nexScale). The old way (RPG Maker's own letterbox, plus a UIKit transform on top)
        // depended on _stretchEnabled (off with the desktop user agent in browser mode = the game at 1:1, zoomed in
        // and cut off), on a 980 px layout viewport, and on the canvas size measured at the wrong moment.
        //   fit     whole picture, as big as possible (letterbox)
        //   fill    covers the screen, edges cut
        //   stretch fills the screen, shape not kept
        //   pixel   like fit, but a whole number of screen pixels per game pixel (sharp pixel art)
        //   game    the game's own code (Graphics._centerElement as shipped)
        var scaleMode = cfg.scaling || 'fit';
        var nativeCenter = null, nativeToX = null, nativeToY = null;
        function viewSize() {
            var de = document.documentElement;
            var vw = window.innerWidth || (de && de.clientWidth) || 0;
            var vh = window.innerHeight || (de && de.clientHeight) || 0;
            return [vw, vh];
        }
        function scaleFor(w, h) {
            var v = viewSize(), vw = v[0], vh = v[1];
            if (!w || !h || !vw || !vh) return null;
            var sx = vw / w, sy = vh / h, fit = Math.min(sx, sy);
            switch (scaleMode) {
            case 'fill': sx = sy = Math.max(sx, sy); break;
            case 'stretch': break;
            case 'pixel':
                var dpr = window.devicePixelRatio || 1;
                var whole = Math.floor(fit * dpr + 0.001) / dpr;
                sx = sy = whole >= 1 / dpr ? whole : fit;
                break;
            default: sx = sy = fit;
            }
            return [sx, sy, vw, vh];
        }
        function relayout() {
            try { if (typeof Graphics !== 'undefined' && Graphics._updateAllElements && Graphics._canvas) Graphics._updateAllElements(); } catch (e) {}
        }
        var relayoutTimer = 0;
        function relayoutSoon() {
            clearTimeout(relayoutTimer);
            relayoutTimer = setTimeout(relayout, 60);
        }
        window.__nexRelayout = function () { relayout(); relayoutSoon(); return scaleMode; };
        window.__nexScale = function (mode) {
            scaleMode = ['fit', 'fill', 'stretch', 'pixel', 'game'].indexOf(mode) >= 0 ? mode : 'fit';
            relayout();
            return scaleMode;
        };
        window.addEventListener('resize', relayoutSoon);
        window.addEventListener('orientationchange', relayoutSoon);
        (function patchScaling() {
            if (typeof Graphics === 'undefined' || !Graphics._centerElement) { setTimeout(patchScaling, 30); return; }
            if (Graphics.__nexScaled) return;
            Graphics.__nexScaled = true;
            nativeCenter = Graphics._centerElement;
            nativeToX = Graphics.pageToCanvasX;
            nativeToY = Graphics.pageToCanvasY;
            Graphics._centerElement = function (element) {
                if (!element) return;
                if (scaleMode === 'game') return nativeCenter.apply(this, arguments);
                // The game's size decides the scale; each element (canvas, video, error box) keeps its own size.
                var gw = this._width || element.width, gh = this._height || element.height;
                var s = scaleFor(gw, gh);
                if (!s) return nativeCenter.apply(this, arguments);
                var w = element.width || gw, h = element.height || gh;
                var cw = w * s[0], ch = h * s[1];
                var style = element.style;
                style.position = 'absolute';
                style.margin = '0';
                style.right = 'auto';
                style.bottom = 'auto';
                function px(v) { return (Math.round(v * 100) / 100) + 'px'; }
                style.left = px((s[2] - cw) / 2);
                style.top = px((s[3] - ch) / 2);
                style.width = px(cw);
                style.height = px(ch);
                if (element === this._canvas) this._realScale = s[0];
            };
            Graphics.pageToCanvasX = function (x) {
                if (scaleMode === 'game' && nativeToX) return nativeToX.apply(this, arguments);
                var c = this._canvas;
                if (!c) return 0;
                var r = c.getBoundingClientRect();
                return Math.round((x - r.left) * c.width / (r.width || 1));
            };
            Graphics.pageToCanvasY = function (y) {
                if (scaleMode === 'game' && nativeToY) return nativeToY.apply(this, arguments);
                var c = this._canvas;
                if (!c) return 0;
                var r = c.getBoundingClientRect();
                return Math.round((y - r.top) * c.height / (r.height || 1));
            };
            relayout();
            // The web view often gets its final size a moment after the game sized itself.
            [250, 1000, 3000].forEach(function (ms) { setTimeout(relayout, ms); });
        })();

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
        // 8.18.1: the whole NW.js API answers. Plugins that build a PC menu bar (MenuBarAddition: new nw.MenuItem,
        // menu.append, win.menu = ...), register hot keys, read the clipboard or the screens stopped the game at
        // start with "undefined is not a constructor". Anything NexPlay doesn't know is a quiet stand-in that can be
        // called, constructed and read without throwing.
        // 8.18.2: every first use of a stand-in is written to the game log ("nw: ..."), so a later problem points
        // at the part to build properly.
        var told = {}, toldCount = 0;
        function tell(text) {
            if (told[text] || toldCount >= 40) return;
            told[text] = true;
            toldCount++;
            try { window.webkit.messageHandlers.nexLog.postMessage('nw: ' + text + ' (no iPhone version, did nothing)'); } catch (e) {}
        }
        function quiet(path) {
            var target = function () {};
            return new Proxy(target, {
                get: function (t, key) {
                    if (typeof key === 'symbol' || key === 'then') return undefined;
                    if (key in t) return t[key];
                    t[key] = quiet(path + '.' + String(key));
                    return t[key];
                },
                set: function (t, key, value) { t[key] = value; return true; },
                apply: function () { tell('game called ' + path + '()'); return quiet(path + '()'); },
                construct: function () { tell('game made new ' + path); return quiet('new ' + path); }
            });
        }
        function withQuiet(base, path, onSet) {
            return new Proxy(base, {
                get: function (t, key) {
                    if (key in t || typeof key === 'symbol' || key === 'then') return t[key];
                    t[key] = quiet(path + '.' + String(key));
                    return t[key];
                },
                set: function (t, key, value) {
                    t[key] = value;
                    if (onSet) onSet(key, value);
                    return true;
                }
            });
        }
        // 8.18.2: the game's own menu bar (win.menu = new nw.Menu({type: 'menubar'})) is kept so the Game Panel
        // can show its items (window.__nexMenuJSON) and run them (window.__nexMenuClick).
        var menuItems = {}, nextItem = 1, menuBar = null;
        function NwMenuItem(options) {
            options = options || {};
            for (var k in options) this[k] = options[k];
            this.type = options.type || 'normal';
            this.label = options.label || '';
            this.enabled = options.enabled !== false;
            this.checked = !!options.checked;
            this.__id = nextItem++;
            menuItems[this.__id] = this;
        }
        NwMenuItem.prototype.on = function (name, fn) { if (name === 'click' && typeof fn === 'function') this.click = fn; return this; };
        NwMenuItem.prototype.removeAllListeners = noop;
        function NwMenu(options) { this.type = (options && options.type) || 'contextmenu'; this.items = []; }
        NwMenu.prototype.append = function (item) { this.items.push(item); };
        NwMenu.prototype.insert = function (item, i) { this.items.splice(i, 0, item); };
        NwMenu.prototype.remove = function (item) { var i = this.items.indexOf(item); if (i >= 0) this.items.splice(i, 1); };
        NwMenu.prototype.removeAt = function (i) { this.items.splice(i, 1); };
        NwMenu.prototype.popup = noop;
        NwMenu.prototype.createMacBuiltin = noop;
        function describe(menu, depth) {
            if (!menu || !menu.items || depth > 4) return [];
            return menu.items.map(function (item) {
                return { id: item.__id || 0, label: String(item.label || ''), type: String(item.type || 'normal'),
                    enabled: item.enabled !== false, checked: !!item.checked, key: String(item.key || ''),
                    children: item.submenu ? describe(item.submenu, depth + 1) : [] };
            });
        }
        window.__nexMenuJSON = function () { return JSON.stringify(menuBar ? describe(menuBar, 0) : []); };
        window.__nexMenuClick = function (id) {
            var item = menuItems[id];
            if (!item) return 'That menu item is gone.';
            if (item.enabled === false) return 'That menu item is turned off.';
            if (item.type === 'checkbox') item.checked = !item.checked;
            try { if (typeof item.click === 'function') item.click.call(item); } catch (e) { return String((e && e.message) || e); }
            return 'ok';
        };
        var nwWindow = withQuiet({
            x: 0, y: 0, width: window.innerWidth, height: window.innerHeight, title: document.title, menu: null,
            isFullscreen: true, isKioskMode: false, zoomLevel: 0, window: window,
            on: function () { return nwWindow; }, once: function () { return nwWindow; },
            removeListener: noop, removeAllListeners: noop, show: noop, hide: noop, focus: noop, blur: noop,
            maximize: noop, minimize: noop, restore: noop, resizeTo: noop, moveTo: noop, setPosition: noop,
            enterFullscreen: noop, leaveFullscreen: noop, toggleFullscreen: noop, enterKioskMode: noop,
            leaveKioskMode: noop, toggleKioskMode: noop, setAlwaysOnTop: noop, setResizable: noop,
            setMinimumSize: noop, setMaximumSize: noop, requestAttention: noop, setProgressBar: noop,
            showDevTools: noop, closeDevTools: noop, isDevToolsOpen: function () { return false; },
            reload: function () { location.reload(); }, reloadIgnoringCache: function () { location.reload(); },
            close: function (force) { exit(); }
        }, 'nw.Window', function (key, value) {
            if (key === 'menu') {
                menuBar = value && value.items ? value : null;
                if (menuBar) {
                    try { window.webkit.messageHandlers.nexLog.postMessage('nw: the game made a menu bar (' + menuBar.items.length + ' menus); it is in the Game Panel > Tools > Game Menu Bar'); } catch (e) {}
                }
            }
        });
        var nwApp = withQuiet({ argv: [], fullArgv: [], manifest: {}, dataPath: '/', quit: exit, closeAllWindows: exit,
            clearCache: noop, registerGlobalHotKey: noop, unregisterGlobalHotKey: noop, on: noop }, 'nw.App');
        var clipboardText = '';
        var nwClipboard = { get: function () { return clipboardText; }, set: function (t) { clipboardText = String(t || ''); }, clear: function () { clipboardText = ''; } };
        var nwGui = withQuiet({
            App: nwApp,
            Window: withQuiet({ get: function () { return nwWindow; }, open: function () { return nwWindow; } }, 'nw.Window'),
            Menu: NwMenu,
            MenuItem: NwMenuItem,
            Shell: { openExternal: noop, openItem: noop, showItemInFolder: noop },
            Clipboard: { get: function () { return nwClipboard; } },
            Screen: withQuiet({ Init: noop, screens: [{ id: 1, bounds: { x: 0, y: 0, width: screen.width, height: screen.height },
                work_area: { x: 0, y: 0, width: screen.width, height: screen.height }, scaleFactor: window.devicePixelRatio || 1 }],
                on: noop, chooseDesktopMedia: noop }, 'nw.Screen'),
            Shortcut: function (options) { this.key = options && options.key; this.active = noop; this.failed = noop; },
            Tray: function () { this.remove = noop; this.on = noop; }
        }, 'nw');
        var os = {
            platform: function () { return 'linux'; },
            type: function () { return 'Linux'; },
            homedir: function () { return '/'; },
            tmpdir: function () { return '/'; },
            EOL: '\n'
        };

        // 8.17.3: Greenworks (Steamworks for NW.js). Games that check it at startup (Orange Greenworks and games
        // built on it) show "please restart Steam" and stop when it is missing. This stub says Steam is running,
        // takes achievement calls and answers every other function with a no-op. Nothing is sent to Steam.
        function gwDone(a) {
            var cb = a[a.length - 1];
            if (typeof cb === 'function') setTimeout(function () { cb(false); }, 0);
        }
        var greenworksBase = {
            init: function () { return true; },
            initAPI: function () { return true; },
            isSteamRunning: function () { return true; },
            isSteamInitialized: function () { return true; },
            getAppId: function () { return 480; },
            getCurrentGameLanguage: function () { return 'english'; },
            getCurrentUILanguage: function () { return 'english'; },
            getSteamId: function () {
                return { flags: {}, type: 1, accountId: 1, steamId: '76561197960265729', staticAccountId: '1', isValid: 1, level: 1, screenName: 'NexPlay' };
            },
            isDLCInstalled: function () { return false; },
            isGameOverlayEnabled: function () { return false; },
            getAchievementNames: function () { return []; },
            getNumberOfAchievements: function () { return 0; },
            activateAchievement: function (name, ok) { if (typeof ok === 'function') setTimeout(ok, 0); },
            clearAchievement: function (name, ok) { if (typeof ok === 'function') setTimeout(ok, 0); },
            getAchievement: function (name, ok) { if (typeof ok === 'function') setTimeout(function () { ok(false); }, 0); },
            getNumberOfPlayers: function (ok) { if (typeof ok === 'function') setTimeout(function () { ok(1); }, 0); },
            on: noop,
            removeListener: noop
        };
        var greenworks = new Proxy(greenworksBase, {
            get: function (target, key) {
                if (key in target) return target[key];
                if (typeof key === 'symbol' || key === 'then') return undefined;
                return function () { gwDone(arguments); };
            }
        });

        var modules = { fs: fs, path: path, os: os, 'nw.gui': nwGui };

        window.nw = nwGui;
        window.require = function (name) {
            var id = String(name).replace(/^node:/, '');
            var found = modules[id];
            if (found) return found;
            if (/(^|\/)greenworks(\.js|\.node)?$/i.test(id)) return greenworks;
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
    /// 8.3.2: the longest frame of the last second, in ms.
    var onWorstFrame: ((Double) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let number = message.body as? NSNumber {
            onFPS?(number.intValue)
        } else if let list = message.body as? [NSNumber], let first = list.first {
            onFPS?(first.intValue)
            if list.count > 1 { onWorstFrame?(list[1].doubleValue) }
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
