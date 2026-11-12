#!/usr/bin/env python3
# NexPlay 6.4.0: makes BCD's app target (Madeira) build as a dynamic library that NexPlay loads (BCDCore.framework),
# in the BCD checkout of the "Build Windows runtime" workflow. Nothing here is committed to BCD.
#   1. app/Madeira.xcodeproj: the Madeira target links as MH_DYLIB (install name @rpath/BCDCore.framework/BCDCore).
#   2. app/Madeira/MadeiraApp.swift: two C entry points are appended. Their code is made from MadeiraApp's own init and
#      WindowGroup content, read from the file, so they follow BCD when the pinned version moves:
#        nexplay_bcd_make_root() -> a retained UIViewController showing BCD's interface (ContentView and its modifiers)
#        nexplay_bcd_open_url(const char *) -> the app's onOpenURL handling (madeira://play?exe=... starts a game)
#   3. app/Madeira/madeira-exports.txt: both symbols join the export list (the link exports only listed symbols).
# BCD: https://github.com/thebcd69/bcd-games (GPL-3.0 with BCD's additional terms).
# Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
import os
import re
import sys

MARK = "// MARK: - NexPlay entry points"


def block(text, open_index):
    """(start, end) of the text inside the brace at open_index."""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return open_index + 1, i
    raise SystemExit("unbalanced braces after offset %d" % open_index)


def inner(text, anchor):
    at = text.find(anchor)
    if at < 0:
        raise SystemExit("MadeiraApp.swift: %r not found (BCD changed it; update tools/windows/patch_bcd_for_nexplay.py)" % anchor)
    start, end = block(text, text.index("{", at))
    return text[start:end]


def dedent(code, spaces):
    lines = [l for l in code.split("\n")]
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    indents = [len(l) - len(l.lstrip(" ")) for l in lines if l.strip()]
    cut = min(indents) if indents else 0
    return "\n".join((" " * spaces + l[cut:]) if l.strip() else "" for l in lines)


def patch_app_swift(path):
    with open(path) as f:
        text = f.read()
    if MARK in text:
        print("MadeiraApp.swift: already patched")
        return
    init_body = inner(text, "init() {")
    content = inner(text, "WindowGroup {")
    open_url = inner(content, ".onOpenURL {")
    open_url = re.sub(r"^\s*url\s+in\b", "", open_url, count=1)
    code = """

%s (added by NexPlay's tools/windows/patch_bcd_for_nexplay.py; not part of BCD)
// NexPlay links this target as a dynamic library (BCDCore.framework) and calls these by dlsym. Their bodies are
// MadeiraApp's own init and WindowGroup content, copied when the runtime is built.
@MainActor private var nexplayBCDStarted = false

@MainActor private func nexplayBCDStartOnce() {
    if nexplayBCDStarted { return }
    nexplayBCDStarted = true
%s
}

struct NexPlayBCDRoot: View {
    var body: some View {
%s
    }
}

@_cdecl("nexplay_bcd_make_root")
public func nexplay_bcd_make_root() -> UnsafeMutableRawPointer? {
    let bits: UInt = MainActor.assumeIsolated {
        nexplayBCDStartOnce()
        let root = UIHostingController(rootView: NexPlayBCDRoot())
        return UInt(bitPattern: Unmanaged.passRetained(root).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: bits)
}

@_cdecl("nexplay_bcd_open_url")
public func nexplay_bcd_open_url(_ text: UnsafePointer<CChar>?) {
    guard let text, let url = URL(string: String(cString: text)) else { return }
    MainActor.assumeIsolated {
%s
    }
}
""" % (MARK, dedent(init_body, 4), dedent(content, 8), dedent(open_url, 8))
    with open(path, "a") as f:
        f.write(code)
    print("MadeiraApp.swift: entry points added")


def patch_exports(path):
    with open(path) as f:
        text = f.read()
    added = [s for s in ("_nexplay_bcd_make_root", "_nexplay_bcd_open_url") if s not in text.split()]
    if added:
        with open(path, "a") as f:
            if not text.endswith("\n"):
                f.write("\n")
            f.write("# NexPlay: BCD built as a library (tools/windows/patch_bcd_for_nexplay.py)\n")
            for s in added:
                f.write(s + "\n")
    print("madeira-exports.txt: %s" % (", ".join(added) or "already listed"))


def patch_project(path, target="Madeira"):
    with open(path) as f:
        text = f.read()
    m = re.search(r"(\w+) /\* %s \*/ = \{\s*isa = PBXNativeTarget;\s*buildConfigurationList = (\w+)" % re.escape(target), text)
    if not m:
        raise SystemExit("project.pbxproj: native target %s not found" % target)
    list_id = m.group(2)
    lm = re.search(r"\b%s /\* [^*]* \*/ = \{\s*isa = XCConfigurationList;\s*buildConfigurations = \(([^)]*)\)" % re.escape(list_id), text)
    if not lm:
        raise SystemExit("project.pbxproj: configuration list %s not found" % list_id)
    ids = re.findall(r"(\w+) /\*", lm.group(1))
    settings = ('MACH_O_TYPE = mh_dylib; LD_DYLIB_INSTALL_NAME = "@rpath/BCDCore.framework/BCDCore"; '
                'NEXPLAY_LIBRARY_BUILD = YES; ')
    count = 0
    for cid in ids:
        cm = re.search(r"\b%s /\* [^*]* \*/ = \{\s*isa = XCBuildConfiguration;\s*buildSettings = \{" % re.escape(cid), text)
        if not cm:
            raise SystemExit("project.pbxproj: build configuration %s not found" % cid)
        if "NEXPLAY_LIBRARY_BUILD" in text[cm.end():cm.end() + 400]:
            continue
        text = text[:cm.end()] + "\n\t\t\t\t" + settings + text[cm.end():]
        count += 1
    with open(path, "w") as f:
        f.write(text)
    print("project.pbxproj: %s linked as a dynamic library in %d configuration(s)" % (target, count))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    patch_project(os.path.join(root, "app/Madeira.xcodeproj/project.pbxproj"))
    patch_app_swift(os.path.join(root, "app/Madeira/MadeiraApp.swift"))
    patch_exports(os.path.join(root, "app/Madeira/madeira-exports.txt"))


if __name__ == "__main__":
    main()
