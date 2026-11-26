#!/usr/bin/env python3
# NexPlay 8.20.3: small fixes to BCD's build scripts before run_bcd_ci.py replays BCD's workflow. Each fix looks for an exact
# piece of text; when BCD changes that text (a newer tag), the fix says so and does nothing, so a BCD update never breaks here.
# BCD: https://github.com/thebcd69/bcd-games. Includes work from BCD by thebcd69.
# Usage: fix_bcd.py <bcd root>
import sys
from pathlib import Path

root = Path(sys.argv[1])

FIXES = [
    # BCD 0.1.721: the "Check and patch opengl32's NULL sync" step changes wine/dlls/opengl32/unix_private.h, and the
    # opengl32-optin.dll block then refuses to build because dlls/opengl32 "differs from the pin". That patch is part of
    # BCD's own tree for the opt-in DLL (only gl-backend sessions reach it), so leave that one file out of the check.
    ("tools/build-wine-extra-dlls.sh",
     'git -C "$R/wine" diff --quiet -- dlls/opengl32 && grep -q "ios_wow_host_ptr"',
     'git -C "$R/wine" diff --quiet -- dlls/opengl32 \':(exclude)dlls/opengl32/unix_private.h\' && grep -q "ios_wow_host_ptr"',
     "opengl32-optin.dll: the NULL-sync patch no longer blocks it"),
    # BCD 0.1.721: DXC regenerates DxilConstants.h and other in-tree headers, formats them with whatever clang-format the
    # runner has (Homebrew's is newer than DXC's) and fails when the result differs from the committed file. Use the
    # committed sources instead of regenerating them.
    ("tools/build-dxcompiler.sh",
     '-DLLVM_BUILD_TESTS=OFF -DLLVM_APPEND_VC_REV=OFF',
     '-DLLVM_BUILD_TESTS=OFF -DHLSL_DISABLE_SOURCE_GENERATION=ON -DLLVM_APPEND_VC_REV=OFF',
     "dxcompiler: committed sources, no clang-format check"),
]

for rel, old, new, what in FIXES:
    path = root / rel
    if not path.exists():
        print("::notice::fix_bcd: %s is not in this BCD; skipped (%s)" % (rel, what))
        continue
    text = path.read_text()
    if new in text:
        print("fix_bcd: already applied: %s" % what)
    elif text.count(old) == 1:
        path.write_text(text.replace(old, new))
        print("fix_bcd: %s" % what)
    else:
        print("::notice::fix_bcd: %s changed in this BCD (found %d times); skipped (%s)" % (rel, text.count(old), what))
