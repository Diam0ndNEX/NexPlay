#!/usr/bin/env python3
"""Bundles the Ren'Py web runtimes NexPlay uses (tools/renpy/runtimes.txt) into a folder.

For each version two files are written:
  renpy-<v>-web.zip     the official RenPyWeb runtime (renpy.org/dl/<v>/renpy-<v>-web.zip, unchanged): index.html,
                        the WebAssembly build of Ren'Py's Python and C modules, the loader scripts.
  renpy-<v>-engine.zip  main.py + renpy/ taken from the official SDK of the same version, laid out like Ren'Py's own
                        "Build Web Application" (launcher/game/distribute.rpy, web_transform_renpy): bytecode next to
                        each module, without the sources. The bytecode must match the web runtime's Python, which is
                        not always the SDK's (8.3.7: SDK 3.9, web 3.11), so it is compiled here with a matching
                        interpreter when needed (sources are shipped when none is found). renpy/common/*_ren.py are
                        Ren'Py scripts and always stay sources. Ren'Py 7 ships .pyo without the .py next to it.
Tested in a browser with the real web runtimes (a Ren'Py 7, 8.3 and 8.5 test game run, with progressive images).

The app builds each game's game.zip from the engine ZIP plus the game's own game/ folder, exactly the layout RenPyWeb
unpacks (runtime/sitecustomize.py in renpy-build: everything in game.zip is extracted to /).
Ren'Py is MIT-licensed (https://www.renpy.org/doc/html/license.html).

Usage: fetch_renpy_runtimes.py <out-dir> [cache-dir]
Failures are reported as warnings and never stop the build; the app then says the runtime is missing.
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

BASE = "https://www.renpy.org/dl/{v}/renpy-{v}-{kind}.zip"
CYTHON_SOURCES = (".pyx", ".pxd", ".pxi")


def download(url, target):
    temp = target + ".part"
    for attempt in range(3):
        done = subprocess.run(["curl", "-sSfL", "--retry", "3", "--connect-timeout", "30", "-o", temp, url])
        if done.returncode == 0 and os.path.getsize(temp) > 0:
            os.replace(temp, target)
            return
    raise IOError("download failed: " + url)


def cached_download(url, name, cache, scratch):
    if cache:
        path = os.path.join(cache, name)
        if not os.path.exists(path):
            download(url, path)
        return path
    path = os.path.join(scratch, name)
    download(url, path)
    return path


def sdk_prefix(names):
    """The folder inside the SDK ZIP that holds renpy.py and renpy/ ("renpy-8.3.7-sdk/")."""
    for name in names:
        if name.endswith("renpy/__init__.py") and name.count("/") <= 2:
            prefix = name[: -len("renpy/__init__.py")]
            if prefix + "renpy.py" in names:
                return prefix
    raise IOError("renpy.py and renpy/ not found in the SDK")


def python3_tag(names):
    """The cache tag of the SDK's own .pyc files (for example cpython-39), the most common one under renpy/."""
    counts = {}
    for name in names:
        match = re.search(r"/__pycache__/[^/]+\.(cpython-\d+)\.pyc$", name)
        if match and "/renpy/" in "/" + name:
            counts[match.group(1)] = counts.get(match.group(1), 0) + 1
    if not counts:
        return None
    return max(counts, key=counts.get)


def web_python(web_path):
    """The Python version inside a RenPyWeb 8 runtime ("3.11"), read from the paths packed in renpy.data."""
    with zipfile.ZipFile(web_path) as web:
        data_names = [name for name in web.namelist() if name.endswith("renpy.data")]
        if not data_names:
            return None
        data = web.read(data_names[0])
    counts = {}
    for match in re.finditer(rb"lib/python(3\.\d+)/", data):
        version = match.group(1).decode()
        counts[version] = counts.get(version, 0) + 1
    return max(counts, key=counts.get) if counts else None


def find_python(version):
    """An interpreter of exactly this version on the build machine, or None."""
    candidates = [shutil.which("python" + version)]
    for pattern in ("/Users/runner/hostedtoolcache/Python/%s.*/*/bin/python%s",
                    "/opt/hostedtoolcache/Python/%s.*/*/bin/python%s",
                    "/opt/homebrew/opt/python@%s/bin/python%s",
                    "/usr/local/opt/python@%s/bin/python%s",
                    "/Library/Frameworks/Python.framework/Versions/%s/bin/python%s"):
        candidates += sorted(glob.glob(pattern % (version, version)), reverse=True)
    candidates += ["/opt/homebrew/bin/python" + version, "/usr/local/bin/python" + version, "/usr/bin/python" + version]
    for path in candidates:
        if not path or not os.path.exists(path):
            continue
        done = subprocess.run([path, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"], capture_output=True, text=True)
        if done.returncode == 0 and done.stdout.strip() == version:
            return path
    return None


def is_script_source(rel):
    """Files Ren'Py itself reads as scripts (renpy/common/*_ren.py) must stay sources."""
    return rel.startswith("renpy/common/")


def compile_sources(sdk, prefix, python):
    """Compiles renpy/**.py from the SDK with `python` (legacy layout: x.pyc next to x.py). Returns {rel: bytes}."""
    temp = tempfile.mkdtemp(prefix="renpy-compile-")
    try:
        for name in sdk.namelist():
            rel = name[len(prefix):]
            if not name.startswith(prefix + "renpy/") or not rel.endswith(".py") or is_script_source(rel):
                continue
            target = os.path.join(temp, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(sdk.read(name))
        script = ("import compileall, py_compile, sys\n"
                  "compileall.compile_dir(sys.argv[1], ddir='renpy/', quiet=1, legacy=True,"
                  " invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)\n")
        subprocess.run([python, "-c", script, os.path.join(temp, "renpy")], check=False)
        result = {}
        for root, _, files in os.walk(temp):
            for file in files:
                if file.endswith(".pyc"):
                    full = os.path.join(root, file)
                    with open(full, "rb") as handle:
                        result[os.path.relpath(full, temp).replace(os.sep, "/")] = handle.read()
        return result
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def build_engine(sdk_path, version, web_path, target):
    """Writes main.py + renpy/ for RenPyWeb. Ren'Py 8: bytecode for the web runtime's Python (the SDK's own when
    the versions match, else compiled here with a matching interpreter, else plain sources); scripts in
    renpy/common stay sources. Ren'Py 7: .pyo, and .py only where there is no .pyo (the web runtime runs with -O,
    and a .py next to a .pyo makes it recompile at every start)."""
    major = int(version.split(".")[0])
    with zipfile.ZipFile(sdk_path) as sdk:
        names = set(sdk.namelist())
        prefix = sdk_prefix(names)
        files = {"main.py": sdk.read(prefix + "renpy.py")}
        mode = "py2"
        if major >= 8:
            wanted = web_python(web_path)
            tag = python3_tag(names)
            compiled = {}
            if wanted and tag == "cpython-" + wanted.replace(".", ""):
                mode = "sdk " + tag
                suffix = "." + tag + ".pyc"
                for name in names:
                    if name.startswith(prefix + "renpy/") and "/__pycache__/" in name and name.endswith(suffix):
                        rel = name[len(prefix):].replace("__pycache__/", "")[: -len(suffix)] + ".pyc"
                        if not is_script_source(rel[:-1]):
                            compiled[rel] = sdk.read(name)
            elif wanted and find_python(wanted):
                mode = "compiled with Python " + wanted
                compiled = compile_sources(sdk, prefix, find_python(wanted))
            else:
                mode = "sources (no Python %s here to compile with)" % wanted
            files.update(compiled)
            for name in sorted(names):
                rel = name[len(prefix):]
                if not name.startswith(prefix + "renpy/") or name.endswith("/") or "/__pycache__/" in rel:
                    continue
                if rel.endswith(CYTHON_SOURCES) or rel.endswith((".pyc", ".pyo")):
                    continue
                if rel.endswith(".py") and not is_script_source(rel) and (rel + "c") in compiled:
                    continue
                files[rel] = sdk.read(name)
        else:
            for name in sorted(names):
                rel = name[len(prefix):]
                if not name.startswith(prefix + "renpy/") or name.endswith("/") or "/__pycache__/" in rel:
                    continue
                if rel.endswith(CYTHON_SOURCES) or rel.endswith(".pyc"):
                    continue
                if rel.endswith(".py") and not is_script_source(rel) and (prefix + rel + "o") in names:
                    continue
                files[rel] = sdk.read(name)
        temp = target + ".part"
        with zipfile.ZipFile(temp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as out:
            for rel in sorted(files):
                entry = zipfile.ZipInfo(rel, date_time=(2020, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o644 << 16
                out.writestr(entry, files[rel])
    os.replace(temp, target)
    return len(files), mode


def check_web(path):
    with zipfile.ZipFile(path) as web:
        names = web.namelist()
    if not any(name.endswith("index.html") for name in names):
        raise IOError("no index.html in the web runtime")
    return len(names)


def main():
    if len(sys.argv) < 2:
        print("usage: fetch_renpy_runtimes.py <out-dir> [cache-dir]")
        return 0
    out = sys.argv[1]
    cache = sys.argv[2] if len(sys.argv) > 2 else None
    os.makedirs(out, exist_ok=True)
    if cache:
        os.makedirs(cache, exist_ok=True)
    scratch = os.path.join(out, ".scratch")
    os.makedirs(scratch, exist_ok=True)
    listing = os.path.join(os.path.dirname(os.path.abspath(__file__)), "renpy", "runtimes.txt")
    try:
        for line in open(listing, encoding="utf-8"):
            version = line.split("#")[0].strip()
            if not version:
                continue
            web_target = os.path.join(out, "renpy-%s-web.zip" % version)
            engine_target = os.path.join(out, "renpy-%s-engine.zip" % version)
            engine_cache = os.path.join(cache, "renpy-%s-engine-v2.zip" % version) if cache else None
            try:
                web = cached_download(BASE.format(v=version, kind="web"), "renpy-%s-web.zip" % version, cache, scratch)
                count = check_web(web)
                shutil.copyfile(web, web_target)
                if engine_cache and os.path.exists(engine_cache):
                    shutil.copyfile(engine_cache, engine_target)
                    print("Ren'Py %s: web %d files, engine from cache" % (version, count))
                    continue
                sdk = cached_download(BASE.format(v=version, kind="sdk"), "renpy-%s-sdk.zip" % version, cache, scratch)
                files, tag = build_engine(sdk, version, web, engine_target)
                if engine_cache:
                    shutil.copyfile(engine_target, engine_cache)
                if not cache:
                    os.remove(sdk)
                print("Ren'Py %s: web %d files, engine %d files (%s), %d KB" % (
                    version, count, files, tag, os.path.getsize(engine_target) // 1024))
            except Exception as error:  # never break the build over one runtime
                for path in (web_target, engine_target):
                    if os.path.exists(path):
                        os.remove(path)
                print("warning: Ren'Py %s runtime could not be bundled (%s)" % (version, error))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
