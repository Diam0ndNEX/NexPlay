#!/usr/bin/env python3
# NexPlay 6.4.0: runs the steps of BCD's own build workflow (.github/workflows/build-ipa.yml in BCD's source) on this
# runner, in order and the way GitHub Actions would, so NexPlay builds BCD's Windows runtime with BCD's exact recipe and
# keeps up with it when the pinned BCD version moves. BCD: https://github.com/thebcd69/bcd-games (GPL-3.0 with BCD's
# additional terms). Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
#
# What it does with each step:
#   run:        run with BCD's shell rules; lines that only run BCD's host checks (python3 tests/host/...) are left out
#               (they test BCD's app, not the build); ${{ ... }} expressions are evaluated.
#   if:         evaluated (steps.*.outputs/outcome, env.*, hashFiles, always/success/failure, ==, !=, &&, ||, !).
#   uses:       actions/cache/restore -> a hit when this runner saved that key before (.nexplay-cache/keys.json, kept by
#               the outer workflow's cache) and a path of it exists; actions/cache/save -> records the key; anything
#               else (checkout, upload-artifact) is skipped.
#   GITHUB_ENV, GITHUB_PATH, GITHUB_OUTPUT: honoured; kept between calls in .nexplay-ci-state.json.
# Usage: run_bcd_ci.py --root <bcd> [--until "<step name>"] [--only "<step name>"]
import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

CHECK_LINE = re.compile(r'^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*python3\s+tests/host/\S+')
EXPR = re.compile(r'\$\{\{(.*?)\}\}', re.S)
TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')"
    r"|(?P<num>\d+(?:\.\d+)?)"
    r"|(?P<op>==|!=|<=|>=|&&|\|\||[!<>(),\[\]])"
    r"|(?P<id>[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z0-9_\-\*]+)*))")
STATUS_FUNCS = re.compile(r'\b(always|success|failure|cancelled)\s*\(', re.I)


def load_workflow(path):
    ruby = ("require 'yaml'; require 'json'; "
            "d = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(ARGV[0]) : YAML.load_file(ARGV[0]); "
            "puts JSON.dump(d)")
    out = subprocess.run(["ruby", "-e", ruby, path], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("could not read %s: %s" % (path, out.stderr))
    return json.loads(out.stdout)


def strip_checks(script):
    """Drops the lines that only run a host check, with their continuation lines."""
    kept, skipping = [], False
    for line in script.split("\n"):
        if skipping:
            skipping = line.rstrip().endswith("\\")
            continue
        if CHECK_LINE.match(line):
            skipping = line.rstrip().endswith("\\")
            continue
        kept.append(line)
    return "\n".join(kept)


def has_commands(script):
    for line in script.split("\n"):
        s = line.strip()
        if s and not s.startswith("#"):
            return True
    return False


def to_str(value):
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def truthy(value):
    return value not in (None, "", False, 0, 0.0)


class Runner:
    def __init__(self, root, workflow_path):
        self.root = os.path.abspath(root)
        self.workflow = load_workflow(os.path.join(self.root, workflow_path))
        jobs = self.workflow.get("jobs") or {}
        self.job = jobs[next(iter(jobs))]
        self.state_path = os.path.join(self.root, ".nexplay-ci-state.json")
        self.cache_dir = os.path.join(self.root, ".nexplay-cache")
        self.keys_path = os.path.join(self.cache_dir, "keys.json")
        os.makedirs(self.cache_dir, exist_ok=True)
        self.state = {"env": {}, "path": [], "outputs": {}, "outcomes": {}, "failed": False}
        if os.path.exists(self.state_path):
            with open(self.state_path) as f:
                self.state.update(json.load(f))
        self.keys = {}
        if os.path.exists(self.keys_path):
            with open(self.keys_path) as f:
                self.keys = json.load(f)

    # ---------- state ----------
    def save_state(self):
        with open(self.state_path, "w") as f:
            json.dump(self.state, f, indent=1)

    def save_keys(self):
        with open(self.keys_path, "w") as f:
            json.dump(self.keys, f, indent=1)

    def env(self, step_env=None):
        env = dict(os.environ)
        env.update(self.state["env"])
        if self.state["path"]:
            env["PATH"] = os.pathsep.join(list(reversed(self.state["path"])) + [env.get("PATH", "")])
        env["GITHUB_WORKSPACE"] = self.root
        env["CI"] = "true"
        for scope in (self.workflow.get("env"), self.job.get("env")):
            for k, v in (scope or {}).items():
                env[k] = self.render(to_str(v), env)
        for k, v in (step_env or {}).items():
            env[k] = self.render(to_str(v), env)
        return env

    # ---------- expressions ----------
    def lookup(self, path, env):
        parts = path.split(".")
        head = parts[0].lower()
        if head == "github":
            key = ".".join(parts[1:])
            table = {
                "workspace": self.root,
                "run_number": os.environ.get("GITHUB_RUN_NUMBER", "1"),
                "run_id": os.environ.get("GITHUB_RUN_ID", "1"),
                "repository": os.environ.get("GITHUB_REPOSITORY", ""),
                "sha": os.environ.get("GITHUB_SHA", ""),
                "ref": os.environ.get("GITHUB_REF", ""),
                "event_name": "workflow_dispatch",
                "token": os.environ.get("GH_TOKEN", ""),
            }
            return table.get(key, "")
        if head == "env":
            return env.get(".".join(parts[1:]), "")
        if head == "steps" and len(parts) >= 3:
            sid = parts[1]
            if parts[2] == "outputs" and len(parts) >= 4:
                return self.state["outputs"].get(sid, {}).get(".".join(parts[3:]), "")
            if parts[2] in ("outcome", "conclusion"):
                return self.state["outcomes"].get(sid, "skipped")
            return ""
        if head == "runner":
            return {"os": "macOS", "arch": "ARM64", "temp": tempfile.gettempdir()}.get(".".join(parts[1:]), "")
        if head in ("true", "false"):
            return head == "true"
        if head == "null":
            return None
        return ""  # secrets, inputs, matrix, vars: nothing here

    def hash_files(self, patterns):
        files = []
        for pattern in patterns:
            files.extend(p for p in glob.glob(os.path.join(self.root, pattern), recursive=True) if os.path.isfile(p))
        if not files:
            return ""
        outer = hashlib.sha256()
        for path in sorted(set(files)):
            with open(path, "rb") as f:
                outer.update(hashlib.sha256(f.read()).digest())
        return outer.hexdigest()

    def call(self, name, args):
        name = name.lower()
        if name == "always":
            return True
        if name == "success":
            return not self.state["failed"]
        if name == "failure":
            return self.state["failed"]
        if name == "cancelled":
            return False
        if name == "hashfiles":
            return self.hash_files([to_str(a) for a in args])
        if name == "contains":
            return to_str(args[1]).lower() in to_str(args[0]).lower()
        if name == "startswith":
            return to_str(args[0]).lower().startswith(to_str(args[1]).lower())
        if name == "endswith":
            return to_str(args[0]).lower().endswith(to_str(args[1]).lower())
        if name == "format":
            text = to_str(args[0])
            for i, a in enumerate(args[1:]):
                text = text.replace("{%d}" % i, to_str(a))
            return text
        return ""

    def evaluate(self, text, env):
        tokens, pos = [], 0
        text = text.strip()
        while pos < len(text):
            m = TOKEN.match(text, pos)
            if not m or m.end() == pos:
                raise ValueError("cannot read expression: %r" % text)
            pos = m.end()
            kind = m.lastgroup
            tokens.append((kind, m.group(kind)))
        tokens.append(("end", ""))
        index = [0]

        def peek():
            return tokens[index[0]]

        def take():
            tok = tokens[index[0]]
            index[0] += 1
            return tok

        def compare(a, b, op):
            if op in ("==", "!="):
                same = to_str(a).lower() == to_str(b).lower()
                return same if op == "==" else not same
            try:
                fa, fb = float(to_str(a) or 0), float(to_str(b) or 0)
            except ValueError:
                fa, fb = to_str(a), to_str(b)
            return {"<": fa < fb, ">": fa > fb, "<=": fa <= fb, ">=": fa >= fb}[op]

        def primary():
            kind, value = take()
            if kind == "str":
                return value[1:-1].replace("''", "'")
            if kind == "num":
                return float(value)
            if kind == "op" and value == "(":
                v = or_()
                take()
                return v
            if kind == "op" and value == "!":
                return not truthy(primary())
            if kind == "id":
                if peek() == ("op", "("):
                    take()
                    args = []
                    while peek() != ("op", ")"):
                        args.append(or_())
                        if peek() == ("op", ","):
                            take()
                    take()
                    return self.call(value, args)
                return self.lookup(value, env)
            raise ValueError("unexpected %r in %r" % (value, text))

        def cmp_():
            left = primary()
            while peek()[0] == "op" and peek()[1] in ("==", "!=", "<", ">", "<=", ">="):
                op = take()[1]
                left = compare(left, primary(), op)
            return left

        def and_():
            left = cmp_()
            while peek() == ("op", "&&"):
                take()
                right = cmp_()
                left = right if truthy(left) else left
            return left

        def or_():
            left = and_()
            while peek() == ("op", "||"):
                take()
                right = and_()
                left = left if truthy(left) else right
            return left

        return or_()

    def render(self, text, env):
        return EXPR.sub(lambda m: to_str(self.evaluate(m.group(1), env)), text)

    def condition(self, step, env):
        cond = step.get("if")
        if cond is None:
            return not self.state["failed"]
        text = to_str(cond).strip()
        m = EXPR.fullmatch(text)
        if m:
            text = m.group(1)
        result = truthy(self.evaluate(text, env))
        if not STATUS_FUNCS.search(text):
            result = result and not self.state["failed"]
        return result

    # ---------- steps ----------
    def cache_paths(self, spec, env):
        return [p.strip() for p in self.render(to_str(spec), env).split("\n") if p.strip()]

    def path_exists(self, rel):
        full = os.path.join(self.root, rel)
        if any(c in rel for c in "*?["):
            return bool(glob.glob(full, recursive=True))
        return os.path.exists(full)

    def uses(self, step, sid, env):
        action = step["uses"]
        inputs = step.get("with") or {}
        if action.startswith("actions/cache/restore"):
            key = self.render(to_str(inputs.get("key", "")), env)
            paths = self.cache_paths(inputs.get("path", ""), env)
            hit = key in self.keys and any(self.path_exists(p) for p in paths)
            print("cache %s: %s" % ("hit" if hit else "miss", key))
            self.state["outputs"][sid] = {"cache-hit": "true" if hit else "false", "cache-primary-key": key,
                                          "cache-matched-key": key if hit else ""}
        elif action.startswith("actions/cache/save"):
            key = self.render(to_str(inputs.get("key", "")), env)
            self.keys[key] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            self.save_keys()
            print("cache recorded: %s" % key)
        else:
            print("skipped (%s)" % action)
        return 0

    def run(self, step, sid, env):
        script = strip_checks(to_str(step.get("run", "")))
        if not has_commands(script):
            print("nothing to run here (host checks only)")
            return None
        script = self.render(script, env)
        shell = step.get("shell")
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write(script)
            script_path = f.name
        if shell == "bash":
            cmd = ["bash", "--noprofile", "--norc", "-eo", "pipefail", script_path]
        elif shell == "sh":
            cmd = ["sh", "-e", script_path]
        elif shell in ("python", "python3"):
            cmd = ["python3", script_path]
        else:
            cmd = ["bash", "-e", script_path]
        files = {}
        for name in ("GITHUB_ENV", "GITHUB_PATH", "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"):
            fd, p = tempfile.mkstemp(prefix=name.lower() + "-")
            os.close(fd)
            files[name] = p
            env[name] = p
        cwd = os.path.join(self.root, step.get("working-directory", "")) if step.get("working-directory") else self.root
        rc = subprocess.run(cmd, cwd=cwd, env=env).returncode
        self.read_env_file(files["GITHUB_ENV"])
        with open(files["GITHUB_PATH"]) as f:
            for line in f:
                if line.strip():
                    self.state["path"].append(line.strip())
        outputs = self.parse_kv(files["GITHUB_OUTPUT"])
        if sid and outputs:
            self.state["outputs"].setdefault(sid, {}).update(outputs)
        for p in list(files.values()) + [script_path]:
            try:
                os.remove(p)
            except OSError:
                pass
        return rc

    def parse_kv(self, path):
        result = {}
        with open(path) as f:
            lines = f.read().split("\n")
        i = 0
        while i < len(lines):
            line = lines[i]
            if "<<" in line and ("=" not in line or line.index("<<") < line.index("=")):
                name, delim = line.split("<<", 1)
                body = []
                i += 1
                while i < len(lines) and lines[i] != delim:
                    body.append(lines[i])
                    i += 1
                result[name] = "\n".join(body)
            elif "=" in line:
                name, value = line.split("=", 1)
                result[name] = value
            i += 1
        return result

    def read_env_file(self, path):
        self.state["env"].update(self.parse_kv(path))

    def execute(self, until=None, only=None):
        steps = self.job.get("steps") or []
        for number, step in enumerate(steps):
            name = step.get("name") or step.get("uses") or ("step %d" % number)
            if until and name == until:
                print("== stopping before: %s" % name)
                break
            if only and name not in only:
                continue
            sid = step.get("id") or ("_step%d" % number)
            env = self.env(step.get("env"))
            print("::group::%s" % name)
            started = time.time()
            try:
                if not self.condition(step, env):
                    print("skipped (condition)")
                    self.state["outcomes"][sid] = "skipped"
                    continue
                if "uses" in step:
                    rc = self.uses(step, sid, env)
                else:
                    rc = self.run(step, sid, env)
                if rc is None:
                    self.state["outcomes"][sid] = "success"
                    continue
                if rc == 0:
                    self.state["outcomes"][sid] = "success"
                else:
                    self.state["outcomes"][sid] = "failure"
                    allowed = truthy(self.evaluate(to_str(step.get("continue-on-error", False)), env)) \
                        if isinstance(step.get("continue-on-error"), str) else bool(step.get("continue-on-error"))
                    if allowed:
                        print("::warning::%s failed (exit %d); BCD lets the build go on" % (name, rc))
                    else:
                        print("::error::%s failed (exit %d)" % (name, rc))
                        self.state["failed"] = True
            finally:
                print("(%.0f s)" % (time.time() - started))
                print("::endgroup::")
                self.save_state()
        return 1 if self.state["failed"] else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--workflow", default=".github/workflows/build-ipa.yml")
    parser.add_argument("--until")
    parser.add_argument("--only", action="append")
    args = parser.parse_args()
    runner = Runner(args.root, args.workflow)
    sys.exit(runner.execute(until=args.until, only=args.only))


if __name__ == "__main__":
    main()
