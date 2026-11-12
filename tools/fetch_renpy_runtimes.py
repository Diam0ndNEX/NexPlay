#!/usr/bin/env python3
"""Bundles the Ren'Py web runtimes NexPlay uses (tools/renpy/runtimes.txt) into a folder.

For each version two files are written:
  renpy-<v>-web.zip     the official RenPyWeb runtime (renpy.org/dl/<v>/renpy-<v>-web.zip, unchanged): index.html,
                        the WebAssembly build of Ren'Py's Python and C modules, the loader scripts.
  renpy-<v>-engine.zip  main.py + renpy/ taken from the official SDK of the same version, with the transform
                        Ren'Py's own "Build Web Application" applies (launcher/game/distribute.rpy,
                        web_transform_renpy): Python 3 .pyc files move out of __pycache__ and lose their version tag,
                        and the .py sources they come from are left out. Ren'Py 7 (Python 2) keeps .py and .pyo, as its
                        web builds did.

The app builds each game's game.zip from the engine ZIP plus the game's own game/ folder, exactly the layout RenPyWeb
unpacks (runtime/sitecustomize.py in renpy-build: everything in game.zip is extracted to /).
Ren'Py is MIT-licensed (https://www.renpy.org/doc/html/license.html).

Usage: fetch_renpy_runtimes.py <out-dir> [cache-dir]
Failures are reported as warnings and never stop the build; the app then says the runtime is missing.
"""
import os
import re
import shutil
import subprocess
import sys
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


def engine_entries(sdk, major):
    """(name in the engine ZIP, name in the SDK ZIP) for main.py and renpy/."""
    names = set(sdk.namelist())
    prefix = sdk_prefix(names)
    tag = python3_tag(names) if major >= 8 else None
    result = [("main.py", prefix + "renpy.py")]
    compiled = set()
    if tag:
        suffix = "." + tag + ".pyc"
        for name in names:
            if name.startswith(prefix + "renpy/") and "/__pycache__/" in name and name.endswith(suffix):
                rel = name[len(prefix):]
                target = rel.replace("__pycache__/", "")[: -len(suffix)] + ".pyc"
                compiled.add(target[: -len(".pyc")] + ".py")
                result.append((target, name))
    for name in sorted(names):
        if not name.startswith(prefix + "renpy/") or name.endswith("/"):
            continue
        rel = name[len(prefix):]
        if "/__pycache__/" in rel or rel.endswith(CYTHON_SOURCES):
            continue
        if rel.endswith(".pyc"):
            continue
        if major >= 8:
            if rel.endswith(".pyo"):
                continue
            # The web transform drops sources that have bytecode; keep a source only when nothing replaces it.
            if rel.endswith(".py") and rel in compiled:
                continue
        result.append((rel, name))
    return result, tag


def build_engine(sdk_path, version, target):
    major = int(version.split(".")[0])
    with zipfile.ZipFile(sdk_path) as sdk:
        entries, tag = engine_entries(sdk, major)
        temp = target + ".part"
        with zipfile.ZipFile(temp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as out:
            for rel, name in entries:
                info = sdk.getinfo(name)
                data = sdk.read(name)
                entry = zipfile.ZipInfo(rel, date_time=info.date_time)
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o644 << 16
                out.writestr(entry, data)
    os.replace(temp, target)
    return len(entries), tag


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
            engine_cache = os.path.join(cache, "renpy-%s-engine.zip" % version) if cache else None
            try:
                web = cached_download(BASE.format(v=version, kind="web"), "renpy-%s-web.zip" % version, cache, scratch)
                count = check_web(web)
                shutil.copyfile(web, web_target)
                if engine_cache and os.path.exists(engine_cache):
                    shutil.copyfile(engine_cache, engine_target)
                    print("Ren'Py %s: web %d files, engine from cache" % (version, count))
                    continue
                sdk = cached_download(BASE.format(v=version, kind="sdk"), "renpy-%s-sdk.zip" % version, cache, scratch)
                files, tag = build_engine(sdk, version, engine_target)
                if engine_cache:
                    shutil.copyfile(engine_target, engine_cache)
                if not cache:
                    os.remove(sdk)
                print("Ren'Py %s: web %d files, engine %d files (%s), %d KB" % (
                    version, count, files, tag or "py2", os.path.getsize(engine_target) // 1024))
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
