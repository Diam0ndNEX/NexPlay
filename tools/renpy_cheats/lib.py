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
