import UIKit
import SwiftUI
import WebKit

// Ren'Py cheat engine (8.13.0). Ren'Py games run in RenPyWeb; `renpy_exec` runs Python inside the game (the same
// hook the Game Panel's Ren'Py card uses). This file holds:
// - `RenPyCheatLibrary`: the Python helper that is sent with every request. It reads and changes the game's store
//   variables and persistent data (walks into lists, dicts and objects), locks values, unlocks galleries / music /
//   seen text / achievements, jumps to labels, and runs Python typed by the owner. It works on Ren'Py 7 (Python 2)
//   and Ren'Py 8 (Python 3), so it avoids f-strings and type hints.
// - `RenPyCheatsFeature`: the player feature (game menu entry, sends requests, one answer per request).
// - `RenPyCheatModel` and `RenPyCheatView`: the sheet (Variables, Saved, Console, Unlock, Jump, Tools).
// Requests are JSON, sent to Python as hex, so nothing typed can break the Python code around it.

// MARK: - Python helper

enum RenPyCheatLibrary {
    /// Runs the code through renpy_exec; `sync` writes Ren'Py's save folder to IndexedDB afterwards.
    static let runScript = """
    if (typeof renpy_exec !== 'function') { return "ERR:Ren'Py is not running yet. Wait for the main menu."; }
    const out = await renpy_exec(code);
    if (sync && typeof FS !== 'undefined' && FS.syncfs) {
        await new Promise(function (resolve) { FS.syncfs(false, function () { resolve(); }); });
    }
    return String(out);
    """

    /// The helper plus the call. `result` holds the answer (JSON text) or `ERR:` and the error.
    static func code(hex: String) -> String {
        source + "\ntry:\n    result = _nx_run(__import__('json').loads(__import__('binascii').unhexlify('\(hex)').decode('utf-8')))\nexcept Exception as _e:\n    result = 'ERR:' + repr(_e)\ntry:\n    del _nx_run\nexcept Exception:\n    pass\n"
    }

    // The Python source is tested against a mock Ren'Py (tools/renpy_cheats/test.py).
    static let source = #"""
def _nx_run(q, renpy=renpy, json=__import__('json')):
    UNI = type(u'')
    STR = (str, UNI)
    INT = (int, type(1 << 70))
    NUM = INT + (float,)
    SEP = '\x01'
    st = getattr(renpy, '_nx_state', None)
    if st is None:
        st = {'locks': {}, 'hooked': False}
        setattr(renpy, '_nx_state', st)
    BAD = ('module', 'function', 'builtin_function_or_method', 'type', 'classobj', 'instancemethod',
           'method', 'staticmethod', 'classmethod', 'property', 'generator', 'code')

    def sd():
        return renpy.store.__dict__

    def P():
        return renpy.game.persistent

    def uni(s):
        if isinstance(s, UNI):
            return s
        try:
            return s.decode('utf-8', 'replace')
        except Exception:
            return UNI(repr(s))

    def tname(v):
        if v is None:
            return 'none'
        if isinstance(v, bool):
            return 'bool'
        if isinstance(v, INT):
            return 'int'
        if isinstance(v, float):
            return 'float'
        if isinstance(v, STR):
            return 'str'
        if isinstance(v, list):
            return 'list'
        if isinstance(v, tuple):
            return 'tuple'
        if isinstance(v, dict):
            return 'dict'
        if isinstance(v, (set, frozenset)):
            return 'set'
        return 'obj'

    def txt(v, limit=90):
        try:
            t = tname(v)
            if t in ('list', 'tuple', 'dict', 'set') and len(v) > 25:
                s = u'%s with %d items' % (t, len(v))
            elif isinstance(v, STR):
                s = uni(v)
            else:
                s = uni(repr(v))
        except Exception:
            s = u'?'
        s = s.replace(u'\n', u' ')
        if len(s) > limit:
            s = s[:limit] + u'...'
        return s

    def junk(v):
        if type(v).__name__ in BAD:
            return True
        if tname(v) == 'obj' and callable(v):
            return True
        return False

    def kids_of(v, t):
        try:
            if t in ('list', 'tuple', 'dict'):
                return len(v) > 0
            if t == 'obj':
                return bool(getattr(v, '__dict__', None))
        except Exception:
            pass
        return False

    def mkrow(path, name, v):
        t = tname(v)
        return {'p': list(path), 'n': txt(name, 60), 't': t, 'v': txt(v),
                'f': (txt(v, 1000) if t != 'obj' else u''),
                'e': t != 'obj', 'k': kids_of(v, t), 'l': SEP.join(path) in st['locks']}

    def lowkey(s):
        return s.lower()

    def scan_store(show_all):
        changed = None
        if not show_all:
            try:
                changed = set(renpy.python.store_dicts['store'].ever_been_changed)
                if len(changed) == 0:
                    changed = None
            except Exception:
                changed = None
        d = sd()
        names = [k for k in list(d.keys()) if isinstance(k, STR) and not k.startswith('_')]
        if changed is not None:
            names = [k for k in names if k in changed]
        names.sort(key=lowkey)
        out = []
        for k in names:
            try:
                v = d[k]
                if junk(v):
                    continue
                out.append(mkrow(['s', k], k, v))
            except Exception:
                pass
            if len(out) >= 3000:
                break
        return out

    def scan_pers():
        out = []
        try:
            d = P().__dict__
            names = [k for k in list(d.keys()) if isinstance(k, STR) and not k.startswith('_')]
            names.sort(key=lowkey)
            for k in names:
                try:
                    v = d[k]
                    if junk(v):
                        continue
                    out.append(mkrow(['p', k], k, v))
                except Exception:
                    pass
                if len(out) >= 3000:
                    break
        except Exception:
            pass
        return out

    def root(kind):
        return sd() if kind == 's' else P().__dict__

    def step(cur, s):
        tag, _, rest = s.partition(':')
        if tag == 'a':
            return getattr(cur, rest)
        if tag == 'i':
            return cur[int(rest)]
        return cur[rest]

    def get(path):
        cur = root(path[0])[path[1]]
        for s in path[2:]:
            cur = step(cur, s)
        return cur

    def put(path, value):
        if len(path) == 2:
            if path[0] == 's':
                sd()[path[1]] = value
            else:
                setattr(P(), path[1], value)
            return
        parent = get(path[:-1])
        tag, _, rest = path[-1].partition(':')
        if tag == 'a':
            setattr(parent, rest, value)
        elif tag == 'i':
            parent[int(rest)] = value
        else:
            parent[rest] = value

    def kids(path):
        v = get(path)
        t = tname(v)
        out = []
        if t in ('list', 'tuple'):
            for i, x in enumerate(list(v)[:400]):
                if not junk(x):
                    out.append(mkrow(path + ['i:%d' % i], '[%d]' % i, x))
        elif t == 'dict':
            for k in list(v.keys())[:400]:
                if isinstance(k, bool):
                    continue
                if isinstance(k, INT):
                    s = 'i:%d' % k
                elif isinstance(k, STR):
                    s = u'k:' + uni(k)
                else:
                    continue
                x = v[k]
                if not junk(x):
                    out.append(mkrow(path + [s], txt(k, 40), x))
        elif t == 'obj':
            d = getattr(v, '__dict__', {})
            names = [k for k in list(d.keys()) if isinstance(k, STR) and not k.startswith('__')]
            names.sort(key=lowkey)
            for k in names:
                x = d[k]
                if not junk(x):
                    out.append(mkrow(path + ['a:' + k], k, x))
        return out

    def coerce(cur, val):
        if isinstance(cur, INT) and not isinstance(cur, bool) and isinstance(val, float) and val == int(val):
            return int(val)
        return val

    def parse(text, how, cur):
        if how == 'str':
            return text
        t = text.strip()
        try:
            import ast
            return coerce(cur, ast.literal_eval(t))
        except Exception:
            pass
        low = t.lower()
        if low == 'true':
            return True
        if low == 'false':
            return False
        if low == 'none':
            return None
        try:
            return int(t)
        except Exception:
            pass
        try:
            return coerce(cur, float(t))
        except Exception:
            pass
        raise ValueError(u'Cannot read the value: ' + t)

    def where():
        try:
            f, l = renpy.get_filename_line()
            return u'%s:%s' % (uni(f), l)
        except Exception:
            return u''

    def refresh(save=False):
        if save:
            try:
                renpy.save_persistent()
            except Exception:
                pass
        try:
            renpy.restart_interaction()
        except Exception:
            pass

    def install_hook():
        if st['hooked']:
            return

        def tick():
            try:
                for key in list(st['locks'].keys()):
                    lk = st['locks'].get(key)
                    if lk is None:
                        continue
                    try:
                        if get(lk['path']) != lk['value']:
                            put(lk['path'], lk['value'])
                    except Exception:
                        pass
            except Exception:
                pass
        renpy.config.periodic_callbacks.append(tick)
        st['hooked'] = True

    def later(fn):
        def go():
            try:
                renpy.config.periodic_callbacks.remove(go)
            except Exception:
                pass
            fn()
        renpy.config.periodic_callbacks.append(go)

    def run_code(code):
        import sys
        g = sd()
        buf = []

        class W(object):
            def write(self, s):
                try:
                    buf.append(uni(s))
                except Exception:
                    pass

            def flush(self):
                pass
        old = sys.stdout
        sys.stdout = W()
        res = None
        err = u''
        try:
            code = code.strip()
            try:
                c = compile(code, '<nexplay>', 'eval')
            except SyntaxError:
                c = None
            if c is not None:
                res = eval(c, g)
            else:
                eval(compile(code + '\n', '<nexplay>', 'exec'), g)
        except BaseException as e:
            err = u'%s: %s' % (type(e).__name__, uni(str(e)))
        finally:
            sys.stdout = old
        text = u''.join(buf)
        if res is not None:
            text += txt(res, 3000)
        if err:
            text += (u'\n' if text else u'') + err
        return text

    def op_seen_all():
        seen = getattr(P(), '_seen_ever', None)
        if seen is None:
            raise ValueError(u'This game keeps no seen-text list.')
        n = 0
        for k in list(renpy.game.script.namemap.keys()):
            try:
                seen[k] = True
                n += 1
            except Exception:
                pass
        return u'Marked %d lines as seen. Skip now goes through everything.' % n

    def op_seen_images():
        seen = getattr(P(), '_seen_images', None)
        if seen is None:
            raise ValueError(u'This game keeps no seen-images list.')
        n = 0
        for k in list(renpy.display.image.images.keys()):
            try:
                seen[k] = True
                n += 1
            except Exception:
                pass
        return u'Unlocked %d images (gallery pictures that use seen images).' % n

    def op_seen_audio():
        seen = getattr(P(), '_seen_audio', None)
        if seen is None:
            raise ValueError(u'This game keeps no seen-audio list.')
        n = 0
        for f in list(renpy.list_files()):
            low = f.lower()
            if low.endswith(('.mp3', '.ogg', '.opus', '.wav', '.flac', '.mp2')):
                try:
                    seen[f] = True
                    n += 1
                except Exception:
                    pass
        return u'Unlocked %d sound files (music room).' % n

    def op_achievements():
        ach = renpy.store.achievement
        names = list(getattr(ach, 'achievements', []))
        n = 0
        for name in names:
            try:
                ach.grant(name)
                n += 1
            except Exception:
                pass
        if not names:
            raise ValueError(u'This game registers no achievements.')
        return u'Granted %d achievements.' % n

    op = q.get('op')
    out = {'ok': True}
    if op == 'scan':
        out['vars'] = scan_store(bool(q.get('all')))
        out['pers'] = scan_pers()
        out['at'] = where()
    elif op == 'kids':
        out['rows'] = kids(q['path'])
    elif op == 'set':
        cur = get(q['path'])
        val = parse(q.get('text', u''), q.get('how', 'auto'), cur)
        put(q['path'], val)
        out['msg'] = u'Set to ' + txt(val, 40)
        refresh(q['path'][0] == 'p')
    elif op == 'toggle':
        cur = get(q['path'])
        put(q['path'], not cur)
        refresh(q['path'][0] == 'p')
    elif op == 'add':
        cur = get(q['path'])
        if isinstance(cur, bool) or not isinstance(cur, NUM):
            raise ValueError(u'That is not a number.')
        put(q['path'], coerce(cur, cur + q['delta']))
        refresh(q['path'][0] == 'p')
    elif op == 'lock':
        key = SEP.join(q['path'])
        if q.get('on'):
            cur = get(q['path'])
            if not isinstance(cur, (bool, str, UNI) + NUM):
                raise ValueError(u'Only numbers, flags and text can be locked.')
            st['locks'][key] = {'path': list(q['path']), 'value': cur}
            install_hook()
            out['msg'] = u'Locked at ' + txt(cur, 40)
        else:
            st['locks'].pop(key, None)
            out['msg'] = u'Unlocked'
    elif op == 'locks':
        rows = []
        for key in list(st['locks'].keys()):
            lk = st['locks'][key]
            rows.append(mkrow(lk['path'], lk['path'][-1], lk['value']))
        out['rows'] = rows
    elif op == 'unlock_locks':
        st['locks'].clear()
        out['msg'] = u'All locks removed.'
    elif op == 'bulk_set':
        n = 0
        for p in q['paths']:
            try:
                put(p, coerce(get(p), q['value']))
                n += 1
            except Exception:
                pass
        out['msg'] = u'Changed %d values.' % n
        refresh(True)
    elif op == 'bulk_bool':
        n = 0
        match = q.get('match', u'').lower()
        d = P().__dict__
        for k in list(d.keys()):
            if isinstance(k, STR) and not k.startswith('_') and isinstance(d[k], bool) and match in k.lower():
                d[k] = bool(q['value'])
                n += 1
        out['msg'] = u'Set %d saved flags to %s.' % (n, u'on' if q['value'] else u'off')
        refresh(True)
    elif op == 'seen_all':
        out['msg'] = op_seen_all()
        refresh(True)
    elif op == 'seen_images':
        out['msg'] = op_seen_images()
        refresh(True)
    elif op == 'seen_audio':
        out['msg'] = op_seen_audio()
        refresh(True)
    elif op == 'achievements':
        out['msg'] = op_achievements()
        refresh(True)
    elif op == 'unlock_all':
        parts = []
        for fn in (op_seen_all, op_seen_images, op_seen_audio, op_achievements):
            try:
                parts.append(fn())
            except Exception as e:
                parts.append(uni(str(e)))
        out['msg'] = u'\n'.join(parts)
        refresh(True)
    elif op == 'rollback':
        for name, val in (('rollback_enabled', True), ('rollback_length', 4000), ('hard_rollback_limit', 4000)):
            try:
                setattr(renpy.config, name, val)
            except Exception:
                pass
        out['msg'] = u'Rollback is on and keeps 4000 steps.'
    elif op == 'skip':
        pref = renpy.game.preferences
        pref.skip_unseen = True
        try:
            pref.skip_after_choices = True
        except Exception:
            pass
        out['msg'] = u'Skip now passes unseen text and choices.'
    elif op == 'labels':
        names = []
        for k in list(renpy.game.script.namemap.keys()):
            if isinstance(k, STR) and not k.startswith('_') and len(k) < 80:
                names.append(uni(k))
        names.sort(key=lowkey)
        out['labels'] = names[:4000]
    elif op == 'jump':
        label = q['label']
        if not renpy.has_label(label):
            raise ValueError(u'No label named ' + uni(label))
        later(lambda: renpy.jump(label))
        out['msg'] = u'Jumping to ' + uni(label)
    elif op == 'call':
        label = q['label']
        if not renpy.has_label(label):
            raise ValueError(u'No label named ' + uni(label))
        later(lambda: renpy.call_in_new_context(label))
        out['msg'] = u'Calling ' + uni(label)
    elif op == 'exec':
        out['text'] = run_code(q['code'])
        refresh(False)
    elif op == 'info':
        import sys
        rows = []

        def add(label, fn):
            try:
                rows.append([label, uni(fn())])
            except Exception:
                pass
        add(u'Ren\'Py', lambda: renpy.version())
        add(u'Game', lambda: renpy.config.name)
        add(u'Game version', lambda: renpy.config.version)
        add(u'Python', lambda: sys.version.split()[0])
        add(u'Now at', where)
        add(u'Rollback steps', lambda: renpy.config.rollback_length)
        add(u'Labels', lambda: len([k for k in renpy.game.script.namemap.keys() if isinstance(k, STR)]))
        add(u'Locked values', lambda: len(st['locks']))
        out['info'] = rows
    else:
        raise ValueError(u'Unknown request.')
    return json.dumps(out)
"""#
}

// MARK: - Answers

struct RenPyRow: Decodable, Identifiable, Hashable {
    let p: [String]
    let n: String
    let t: String
    let v: String
    let f: String?
    let e: Bool
    let k: Bool
    let l: Bool
    var id: String { p.joined(separator: "\u{1}") }

    var isNumber: Bool { t == "int" || t == "float" }
    var isScalar: Bool { t == "int" || t == "float" || t == "bool" || t == "str" }
}

struct RenPyReplyData: Decodable {
    let msg: String?
    let vars: [RenPyRow]?
    let pers: [RenPyRow]?
    let rows: [RenPyRow]?
    let labels: [String]?
    let text: String?
    let info: [[String]]?
    let at: String?
}

struct RenPyConsoleEntry: Identifiable {
    let id = UUID()
    let code: String
    let output: String
}

// MARK: - Feature

final class RenPyCheatsFeature: PlayerFeature {
    private final class Gate {
        var open = true
    }

    override func menuItems(for game: Game) -> [UIMenuElement] {
        guard game.engine == .renpy else { return [] }
        return [UIAction(title: "Cheat Engine…", image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
            self?.openEngine()
        }]
    }

    /// Opens the cheat engine sheet. The game keeps running behind it (Ren'Py has to run for the Python to answer).
    func openEngine() {
        guard context.game().engine == .renpy else { return }
        let model = RenPyCheatModel(feature: self)
        let host = UIHostingController(rootView: RenPyCheatView(model: model))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        context.present(host)
    }

    /// Sends one request. Returns the answer, or an error text. Gives up after 20 seconds.
    func send(_ request: [String: Any], sync: Bool) async -> (RenPyReplyData?, String?) {
        guard let webView = context.webView else { return (nil, "The game isn't running.") }
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request) else {
            return (nil, "That request can't be sent.")
        }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let python = RenPyCheatLibrary.code(hex: hex)
        let raw: String = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let gate = Gate()
            let finish: (String) -> Void = { text in
                if gate.open {
                    gate.open = false
                    continuation.resume(returning: text)
                }
            }
            Task { @MainActor in
                do {
                    let value = try await webView.callAsyncJavaScript(RenPyCheatLibrary.runScript,
                                                                      arguments: ["code": python, "sync": sync],
                                                                      in: nil, contentWorld: .page)
                    finish(value as? String ?? "ERR:Ren'Py gave no answer.")
                } catch {
                    finish("ERR:" + error.localizedDescription)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                finish("ERR:Ren'Py didn't answer. Go to a dialogue line or a menu and try again.")
            }
        }
        if raw.hasPrefix("ERR:") {
            let text = String(raw.dropFirst(4))
            context.gameLog.add("ren'py cheats: \(text)")
            return (nil, text)
        }
        guard let bytes = raw.data(using: .utf8),
              let reply = try? JSONDecoder().decode(RenPyReplyData.self, from: bytes) else {
            context.gameLog.add("ren'py cheats: couldn't read the answer (\(raw.prefix(120)))")
            return (nil, "Couldn't read Ren'Py's answer.")
        }
        return (reply, nil)
    }
}

// MARK: - Model

@MainActor
final class RenPyCheatModel: ObservableObject {
    @Published var vars: [RenPyRow] = []
    @Published var pers: [RenPyRow] = []
    @Published var labels: [String] = []
    @Published var info: [[String]] = []
    @Published var locks: [RenPyRow] = []
    @Published var at = ""
    @Published var loading = true
    @Published var busy = false
    @Published var showAll = false
    @Published var status: String?
    @Published var statusIsError = false
    @Published var history: [RenPyConsoleEntry] = []
    private weak var feature: RenPyCheatsFeature?

    init(feature: RenPyCheatsFeature) {
        self.feature = feature
    }

    func say(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
        let shown = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if self?.status == shown { self?.status = nil }
        }
    }

    /// "ValueError('That is not a number.')" -> "That is not a number."
    static func clean(_ error: String) -> String {
        guard let open = error.firstIndex(of: "("), error.hasSuffix(")"), open != error.startIndex else { return error }
        var inner = String(error[error.index(after: open)..<error.index(before: error.endIndex)])
        if inner.count >= 2, let first = inner.first, (first == "'" || first == "\""), inner.last == first {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner.isEmpty ? error : inner
    }

    func request(_ request: [String: Any], write: Bool = false) async -> RenPyReplyData? {
        guard let feature else {
            say("The game isn't running.", error: true)
            return nil
        }
        busy = true
        let result = await feature.send(request, sync: write)
        busy = false
        if let error = result.1 {
            say(RenPyCheatModel.clean(error), error: true)
            return nil
        }
        return result.0
    }

    // MARK: Variables

    func reload() async {
        if let reply = await request(["op": "scan", "all": showAll]) {
            vars = reply.vars ?? []
            pers = reply.pers ?? []
            at = reply.at ?? ""
        }
        loading = false
    }

    func kids(_ row: RenPyRow) async -> [RenPyRow] {
        let reply = await request(["op": "kids", "path": row.p])
        return reply?.rows ?? []
    }

    func setValue(_ row: RenPyRow, text: String) async {
        let how = row.t == "str" ? "str" : "auto"
        if let reply = await request(["op": "set", "path": row.p, "text": text, "how": how], write: true) {
            say(reply.msg ?? "Done")
        }
    }

    func toggle(_ row: RenPyRow) async {
        _ = await request(["op": "toggle", "path": row.p], write: true)
    }

    func add(_ row: RenPyRow, _ delta: Double) async {
X, "path": row.p, "delta": number], write: true)
    }

    func setLock(_ row: RenPyRow, on: Bool) async {
        if let reply = await request(["op": "lock", "path": row.p, "on": on]) {
            say(reply.msg ?? (on ? "Locked" : "Unlocked"))
        }
    }

    func setMany(_ rows: [RenPyRow], value: Double) async {
        let paths = rows.prefix(300).map { $0.p }
        let number: Any
        if value == value.rounded() { number = Int(value) } else { number = value }
        if let reply = await request(["op": "bulk_set", "paths": paths, "value": number], write: true) {
            say(reply.msg ?? "Done")
        }
    }

    // MARK: Tools

    func loadLocks() async {
        if let reply = await request(["op": "locks"]) { locks = reply.rows ?? [] }
    }

    func removeLocks() async {
        if let reply = await request(["op": "unlock_locks"]) {
            say(reply.msg ?? "Unlocked")
            locks = []
        }
    }

    func loadInfo() async {
        if let reply = await request(["op": "info"]) { info = reply.info ?? [] }
    }

    func action(_ op: String, _ extra: [String: Any] = [:]) async {
        var body = extra
        body["op"] = op
        if let reply = await request(body, write: true) {
            say(reply.msg ?? "Done")
        }
    }

    func loadLabels() async {
        if let reply = await request(["op": "labels"]) { labels = reply.labels ?? [] }
    }

    func go(_ op: String, label: String) async {
        if let reply = await request(["op": op, "label": label]) {
            say(reply.msg ?? "Done")
        }
    }

    // MARK: Console

    func run(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let reply = await request(["op": "exec", "code": trimmed], write: true) {
            let output = reply.text ?? ""
            history.append(RenPyConsoleEntry(code: trimmed, output: output.isEmpty ? "(no output)" : output))
            if history.count > 60 { history.removeFirst(history.count - 60) }
            await reload()
        }
    }
}

// MARK: - Views

struct RenPyCheatView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case variables = "Variables", saved = "Saved", console = "Console", unlock = "Unlock", jump = "Jump", tools = "Tools"
        var id: String { rawValue }
    }

    @ObservedObject var model: RenPyCheatModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .variables

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabStrip
                content
            }
            .overlay(alignment: .bottom) { statusBar }
            .navigationTitle("Ren'Py Cheats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .environment(\.colorScheme, .dark)
        .task { await model.reload() }
    }

    private var tabStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Tab.allCases) { item in
                        Button { tab = item } label: {
                            Text(item.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(tab == item ? NexStyle.accent : Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(tab == item ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            if model.busy {
                ProgressView().padding(.trailing, 16)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if model.loading {
            Spacer()
            ProgressView()
            Spacer()
        } else {
            switch tab {
            case .variables:
                RenPyRowsView(model: model, rows: model.vars, emptyText: "No game variables found yet. Play a little, or turn on Show Engine Variables in Tools.",
                              refresh: { Task { await model.reload() } })
            case .saved:
                RenPyRowsView(model: model, rows: model.pers, emptyText: "This game keeps no saved data yet (persistent).",
                              refresh: { Task { await model.reload() } })
            case .console:
                RenPyConsoleTab(model: model)
            case .unlock:
                RenPyUnlockTab(model: model)
            case .jump:
                RenPyJumpTab(model: model)
            case .tools:
                RenPyToolsTab(model: model)
            }
        }
    }

    @ViewBuilder private var statusBar: some View {
        if let text = model.status {
            Text(text)
                .font(.footnote.weight(.semibold))
                .lineLimit(6)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(model.statusIsError ? Color.red.opacity(0.9) : Color.black.opacity(0.88),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
    }
}

/// A list of variables with search, kind chips, +/- buttons, lock and drill-down.
struct RenPyRowsView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", stats = "Stats", numbers = "Numbers", flags = "Flags", text = "Text", other = "Other"
        var id: String { rawValue }
    }

    @ObservedObject var model: RenPyCheatModel
    let rows: [RenPyRow]
    var emptyText = "Nothing here."
    let refresh: () -> Void
    @State private var search = ""
    @State private var kind: Kind = .all
    @State private var bulkEditing = false

    private static let statWords = ["money", "gold", "cash", "coin", "yen", "dollar", "gem", "point", "score", "xp", "exp",
                                    "energy", "stamina", "affection", "love", "trust", "relationship", "rep", "corrupt",
                                    "lust", "hp", "mp", "level", "lvl", "strength", "intel", "charisma", "skill", "day",
                                    "time", "friend", "like", "bond", "sanity", "stress", "hunger", "mood", "health"]

    private var shown: [RenPyRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return rows.filter { row in
            switch kind {
            case .all: break
            case .stats:
                let low = row.n.lowercased()
                if !(row.isNumber && RenPyRowsView.statWords.contains(where: { low.contains($0) })) { return false }
            case .numbers: if !row.isNumber { return false }
            case .flags: if row.t != "bool" { return false }
            case .text: if row.t != "str" { return false }
            case .other: if row.isScalar { return false }
            }
            if query.isEmpty { return true }
            return row.n.localizedCaseInsensitiveContains(query) || row.v.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingNumbers: [RenPyRow] {
        search.trimmingCharacters(in: .whitespaces).isEmpty ? [] : shown.filter { $0.isNumber }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or value", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Kind.allCases) { item in
                        Button { kind = item } label: {
                            Text(item.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(kind == item ? NexStyle.accent.opacity(0.85) : Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 6)
            if !matchingNumbers.isEmpty {
                Button { bulkEditing = true } label: {
                    Label("Set \(min(matchingNumbers.count, 300)) matching numbers…", systemImage: "number.circle")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 4)
            }
            if shown.isEmpty {
                Spacer()
                Text(rows.isEmpty ? emptyText : "Nothing matches.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                List(shown) { row in
                    RenPyRowView(model: model, row: row, refresh: refresh)
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $bulkEditing) {
            RenPyValueSheet(title: "Set \(min(matchingNumbers.count, 300)) numbers to", note: "Every number shown by the search gets this value.",
                            initial: "999999") { text in
                if let value = Double(text.trimmingCharacters(in: .whitespaces)) {
                    let targets = matchingNumbers
                    Task {
                        await model.setMany(targets, value: value)
                        refresh()
                    }
                } else {
                    model.say("That is not a number.", error: true)
                }
            }
            .presentationDetents([.height(280)])
        }
    }
}

struct RenPyRowView: View {
    @ObservedObject var model: RenPyCheatModel
    let row: RenPyRow
    let refresh: () -> Void
    @State private var editing = false

    var body: some View {
        Group {
            if row.k {
                NavigationLink {
                    RenPyChildrenView(model: model, row: row)
                } label: {
                    HStack(spacing: 10) {
                        title
                        Spacer(minLength: 8)
                        Text(row.v).font(.caption).lineLimit(1).foregroundStyle(NexStyle.accent)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    title
                    Spacer(minLength: 8)
                    control
                }
            }
        }
        .contextMenu { menuItems }
        .sheet(isPresented: $editing) {
            RenPyValueSheet(title: row.n,
                            note: row.t == "str" ? "Text. It is saved exactly as typed."
                                : "A Python value: 5, 2.5, True, None, 'text', [1, 2] or {'a': 1}.",
                            initial: row.f ?? row.v) { text in
                Task {
                    await model.setValue(row, text: text)
                    refresh()
                }
            }
            .presentationDetents([.height(290)])
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.n).font(.body).lineLimit(1)
                if row.l { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange) }
            }
            Text(row.t).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var control: some View {
        if row.t == "bool" {
            Toggle("", isOn: Binding(get: { row.v == "True" }, set: { _ in
                Task {
                    await model.toggle(row)
                    refresh()
                }
            }))
            .labelsHidden()
        } else if row.isNumber {
            HStack(spacing: 6) {
                Button { change(-1) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                Button { editing = true } label: {
                    Text(row.v).font(.body.monospacedDigit()).frame(minWidth: 44).lineLimit(1)
                }
                .buttonStyle(.borderless)
                Button { change(1) } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless)
                Menu {
                    Button("+10") { change(10) }
                    Button("+100") { change(100) }
                    Button("+1000") { change(1000) }
                    Button("+100000") { change(100000) }
                    Button("-10") { change(-10) }
                    Button("-100") { change(-100) }
                    Button(row.l ? "Unlock value" : "Lock value (freeze)") { toggleLock() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        } else {
            Button { editing = true } label: {
                Text(row.v).font(.callout).lineLimit(1).foregroundStyle(NexStyle.accent)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if row.e {
            Button { editing = true } label: { Label("Edit Value", systemImage: "pencil") }
        }
        if row.isScalar {
            Button { toggleLock() } label: {
                Label(row.l ? "Unlock Value" : "Lock Value (freeze)", systemImage: row.l ? "lock.open" : "lock")
            }
        }
        Button { UIPasteboard.general.string = row.n } label: { Label("Copy Name", systemImage: "doc.on.doc") }
    }

    private func change(_ delta: Double) {
        Task {
            await model.add(row, delta)
            refresh()
        }
    }

    private func toggleLock() {
        Task {
            await model.setLock(row, on: !row.l)
            refresh()
        }
    }
}

/// The inside of a list, dict or object.
struct RenPyChildrenView: View {
    @ObservedObject var model: RenPyCheatModel
    let row: RenPyRow
    @State private var rows: [RenPyRow] = []

    var body: some View {
        RenPyRowsView(model: model, rows: rows, emptyText: "Nothing inside.", refresh: { Task { rows = await model.kids(row) } })
            .navigationTitle(row.n)
            .navigationBarTitleDisplayMode(.inline)
            .task { rows = await model.kids(row) }
    }
}

/// Asks for one value.
struct RenPyValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let note: String
    let initial: String
    let onDone: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
            TextField("Value", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .focused($focused)
            Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Set") {
                    onDone(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .environment(\.colorScheme, .dark)
        .onAppear {
            text = initial
            focused = true
        }
    }
}

struct RenPyConsoleTab: View {
    @ObservedObject var model: RenPyCheatModel
    @State private var code = ""

    private static let examples: [(String, String)] = [
        ("Change a variable", "money = 99999"),
        ("List variable names", "sorted(k for k in globals() if not k.startswith('_'))[:80]"),
        ("Saved data names", "sorted(k for k in persistent.__dict__ if not k.startswith('_'))"),
        ("Unlock a saved flag", "persistent.cg_unlocked = True"),
        ("Where am I", "renpy.get_filename_line()"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.history.isEmpty {
                        Text("Type Python and run it inside the game. Variables are the game's own names, for example money += 500. Persistent data is persistent.name.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                    ForEach(model.history.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Button { code = entry.code } label: {
                                Text("> " + entry.code).font(.callout.monospaced()).foregroundStyle(NexStyle.accent)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            Text(entry.output).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    ForEach(RenPyConsoleTab.examples, id: \.0) { example in
                        Button(example.0) { code = example.1 }
                    }
                } label: {
                    Image(systemName: "text.badge.plus").font(.title3)
                }
                TextField("Python", text: $code, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    let text = code
                    code = ""
                    Task { await model.run(text) }
                } label: {
                    Image(systemName: "play.circle.fill").font(.title)
                }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }
}

struct RenPyUnlockTab: View {
    @ObservedObject var model: RenPyCheatModel
    @State private var match = ""

    var body: some View {
        List {
            Section {
                row("Unlock Everything", "Seen text, gallery images, music and achievements in one go.", "sparkles", "unlock_all")
            }
            Section("Story and extras") {
                row("Mark All Text as Seen", "Skip then runs through the whole game, and replay lists open.", "text.badge.checkmark", "seen_all")
                row("Unlock Gallery Images", "Marks every image as seen (works for galleries that use seen images).", "photo.on.rectangle", "seen_images")
                row("Unlock Music Room", "Marks every sound file as heard.", "music.note.list", "seen_audio")
                row("Grant All Achievements", "For games that register achievements.", "trophy", "achievements")
                row("Skip Unseen Text and Choices", "Skip no longer stops at new text or after a choice.", "forward.end", "skip")
                row("Unlimited Rollback", "Rollback on, 4000 steps back.", "arrow.uturn.backward.circle", "rollback")
            }
            Section {
                TextField("Only names containing (optional)", text: $match)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button { Task { await model.action("bulk_bool", ["value": true, "match": match.lowercased()]) } } label: {
                    Label("Turn Saved Flags On", systemImage: "checkmark.circle")
                }
                Button { Task { await model.action("bulk_bool", ["value": false, "match": match.lowercased()]) } } label: {
                    Label("Turn Saved Flags Off", systemImage: "xmark.circle")
                }
            } header: {
                Text("Saved flags")
            } footer: {
                Text("Many games unlock scenes and CGs with true/false saved data. Try \"cg\", \"scene\" or \"gallery\" in the name box, then check the Saved tab.")
            }
        }
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ op: String) -> some View {
        Button { Task { await model.action(op) } } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 26).foregroundStyle(NexStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RenPyJumpTab: View {
    @ObservedObject var model: RenPyCheatModel
    @State private var search = ""

    private var shown: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.labels : model.labels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search labels", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            Text("Jump leaves the current scene, so Quick Save first. Call plays the label and comes back when it ends. Both work at a dialogue line or a menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            if shown.isEmpty {
                Spacer()
                Text(model.labels.isEmpty ? "Loading labels…" : "No label matches.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(shown, id: \.self) { label in
                    HStack {
                        Text(label).font(.callout.monospaced()).lineLimit(1)
                        Spacer()
                        Button("Call") { Task { await model.go("call", label: label) } }
                            .buttonStyle(.bordered)
                        Button("Jump") { Task { await model.go("jump", label: label) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { if model.labels.isEmpty { await model.loadLabels() } }
    }
}

struct RenPyToolsTab: View {
    @ObservedObject var model: RenPyCheatModel

    var body: some View {
        List {
            Section("Game") {
                if model.info.isEmpty {
                    Text("Loading…").foregroundStyle(.secondary)
                }
                ForEach(model.info.indices, id: \.self) { index in
                    if model.info[index].count >= 2 {
                        LabeledContent(model.info[index][0]) { Text(model.info[index][1]).multilineTextAlignment(.trailing) }
                    }
                }
            }
            Section {
                Toggle("Show Engine Variables", isOn: Binding(get: { model.showAll }, set: { value in
                    model.showAll = value
                    Task { await model.reload() }
                }))
            } footer: {
                Text("Off shows only the variables the game itself defines or changes. On shows every public variable in the game's namespace.")
            }
            Section {
                if model.locks.isEmpty {
                    Text("Nothing is locked. Lock a number, flag or text from its menu (the ... button or touch and hold).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.locks) { row in
                    LabeledContent(row.n) { Text(row.v).foregroundStyle(.orange) }
                }
                if !model.locks.isEmpty {
                    Button("Unlock All", role: .destructive) { Task { await model.removeLocks() } }
                }
            } header: {
                Text("Locked values")
            } footer: {
                Text("A locked value is put back a few times a second while the game runs. Locks end when the game closes.")
            }
        }
        .task {
            await model.loadInfo()
            await model.loadLocks()
        }
    }
}
