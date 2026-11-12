#!/usr/bin/env python3
"""Bundles Ruffle, the Flash Player emulator (https://ruffle.rs, MIT or Apache-2.0), into a folder.

The self-hosted web build comes from the npm package @ruffle-rs/ruffle (version in tools/ruffle/version.txt):
ruffle.js, its core scripts and the .wasm files. NexPlay serves them from its local game server and loads .swf games
with them.

Usage: fetch_ruffle.py <out-dir> [cache-dir]
Failures are reported as warnings and never stop the build; the app then says the Flash runtime is missing.
"""
import io
import os
import shutil
import subprocess
import sys
import tarfile

URL = "https://registry.npmjs.org/@ruffle-rs/ruffle/-/ruffle-{v}.tgz"
KEEP = (".js", ".wasm", ".map", ".md", ".json")


def main():
    if len(sys.argv) < 2:
        print("usage: fetch_ruffle.py <out-dir> [cache-dir]")
        return 0
    out = sys.argv[1]
    cache = sys.argv[2] if len(sys.argv) > 2 else None
    here = os.path.dirname(os.path.abspath(__file__))
    version = open(os.path.join(here, "ruffle", "version.txt"), encoding="utf-8").read().split("#")[0].strip()
    try:
        name = "ruffle-%s.tgz" % version
        cached = os.path.join(cache, name) if cache else None
        if cached and os.path.exists(cached):
            data = open(cached, "rb").read()
        else:
            done = subprocess.run(["curl", "-sSfL", "--retry", "3", URL.format(v=version)], capture_output=True)
            if done.returncode != 0 or not done.stdout:
                raise IOError("download failed (curl %d)" % done.returncode)
            data = done.stdout
            if cached:
                os.makedirs(cache, exist_ok=True)
                open(cached, "wb").write(data)
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out, exist_ok=True)
        count = 0
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            for member in tar.getmembers():
                if not member.isfile():
                    continue
                base = os.path.basename(member.name)
                if "/" in member.name[len("package/"):] or not member.name.startswith("package/"):
                    continue
                if not (base.endswith(KEEP) or base.upper().startswith("LICENSE")):
                    continue
                if base.endswith(".map"):
                    continue
                with open(os.path.join(out, base), "wb") as handle:
                    handle.write(tar.extractfile(member).read())
                count += 1
        if not os.path.exists(os.path.join(out, "ruffle.js")):
            raise IOError("ruffle.js missing from the package")
        open(os.path.join(out, "VERSION"), "w").write(version)
        print("Ruffle %s: %d files" % (version, count))
    except Exception as error:  # never break the build over Flash support
        shutil.rmtree(out, ignore_errors=True)
        print("warning: Ruffle could not be bundled (%s)" % error)
    return 0


if __name__ == "__main__":
    sys.exit(main())
