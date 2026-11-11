#!/usr/bin/env python3
"""Downloads the Godot web runtimes NexPlay bundles (tools/godot/runtimes.txt) into a folder.

The official export templates (godotengine/godot-builds releases, MIT license) are ~1 GB .tpz ZIPs; only the
web template inside each is needed, so the ZIP is read over HTTP range requests (central directory, then that one
entry) and nothing else is downloaded. Output: <out>/godot-<version>.zip (the web template ZIP as Godot ships it).

Usage: fetch_godot_runtimes.py <out-dir> [cache-dir]
Failures are reported as Xcode warnings and never stop the build; the app then says the runtime is missing.
"""
import io
import os
import shutil
import sys
import subprocess
import time
import zipfile

URL = "https://github.com/godotengine/godot-builds/releases/download/{v}-stable/Godot_v{v}-stable_export_templates.tpz"


class RangeFile(io.RawIOBase):
    """A read-only, seekable view of a remote file. Uses curl (system certificates, follows redirects)."""

    def __init__(self, url):
        self.url = url
        head = subprocess.run(["curl", "-sSIL", "--retry", "3", url], capture_output=True, text=True, check=True).stdout
        sizes = [line.split(":", 1)[1].strip() for line in head.splitlines() if line.lower().startswith("content-length:")]
        if not sizes:
            raise IOError("no size for " + url)
        self.size = int(sizes[-1])
        self.pos = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        if whence == 0:
            self.pos = offset
        elif whence == 1:
            self.pos += offset
        else:
            self.pos = self.size + offset
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b""
        end = min(self.pos + n, self.size) - 1
        for attempt in range(4):
            done = subprocess.run(["curl", "-sSL", "--retry", "3", "-r", "%d-%d" % (self.pos, end), self.url],
                                  capture_output=True)
            data = done.stdout
            if done.returncode == 0 and len(data) == end - self.pos + 1:
                break
            if attempt == 3:
                raise IOError("range download failed (%d bytes, curl %d)" % (len(data), done.returncode))
            time.sleep(2 + attempt * 3)
        self.pos += len(data)
        return data

    def readinto(self, buffer):
        data = self.read(len(buffer))
        buffer[: len(data)] = data
        return len(data)


def fetch(version, entry, target):
    source = RangeFile(URL.format(v=version))
    with zipfile.ZipFile(io.BufferedReader(source, buffer_size=4 << 20)) as tpz:
        data = tpz.read(entry)
    zipfile.ZipFile(io.BytesIO(data)).testzip()
    temp = target + ".part"
    with open(temp, "wb") as handle:
        handle.write(data)
    os.replace(temp, target)


def main():
    if len(sys.argv) < 2:
        print("usage: fetch_godot_runtimes.py <out-dir> [cache-dir]")
        return 0
    out = sys.argv[1]
    cache = sys.argv[2] if len(sys.argv) > 2 else None
    os.makedirs(out, exist_ok=True)
    if cache:
        os.makedirs(cache, exist_ok=True)
    listing = os.path.join(os.path.dirname(os.path.abspath(__file__)), "godot", "runtimes.txt")
    for line in open(listing, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        version, entry = line.split()[:2]
        name = "godot-%s.zip" % version
        target = os.path.join(out, name)
        cached = os.path.join(cache, name) if cache else None
        try:
            if cached and os.path.exists(cached):
                shutil.copyfile(cached, target)
            else:
                fetch(version, entry, target)
                if cached:
                    shutil.copyfile(target, cached)
            print("Godot %s: %d KB" % (version, os.path.getsize(target) // 1024))
        except Exception as error:  # never break the build over one runtime
            print("warning: Godot %s runtime could not be downloaded (%s)" % (version, error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
