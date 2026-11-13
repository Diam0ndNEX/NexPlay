#!/bin/bash
# NexPlay 8.0.0: builds BCD's Windows engine (Wine, FEX, DXMT, the Windows DLLs and the static libraries BCD's app links)
# for NexPlay, which compiles BCD's app code itself (NexPlay/Windows/BCD). Called by the "Build Windows runtime"
# workflow (docs/workflow-windows-runtime.yml). Layout: $GITHUB_WORKSPACE/nexplay (this repo), $GITHUB_WORKSPACE/bcd
# (BCD at the pinned tag, with submodules). Output: $GITHUB_WORKSPACE/out/BCDEngine.zip (or .zip.part-*).
#   1. BCD's own workflow steps, up to (not including) its app archive (run_bcd_ci.py).
#   2. The engine package (package_engine.sh): libraries, FEX headers, the app resources.
# No BCD app target is built any more (6.4.0-7.13 built it as BCDCore.framework).
# BCD: https://github.com/thebcd69/bcd-games. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
set -euo pipefail
WS="${GITHUB_WORKSPACE:?}"
BCD="$WS/bcd"
NX="$WS/nexplay/tools/windows"
cd "$BCD"

# 7.13.4: Homebrew's ccache brings fmt (and hiredis, xxhash, blake3) into /opt/homebrew. FEX's ARM64EC/WOW64 CMake
# then found the macOS fmt for its Windows target ("IMPORTED_IMPLIB not set for imported target fmt::fmt"), xtajit64
# wasn't built and BCD refused the build. Unlink them: ccache keeps working through /opt/homebrew/opt/<name>.
if command -v brew >/dev/null 2>&1; then
  for dep in fmt hiredis xxhash blake3; do
    if brew list --formula "$dep" >/dev/null 2>&1; then brew unlink "$dep" >/dev/null 2>&1 && echo "unlinked $dep (ccache dependency)"; fi
  done
  ccache --version | head -1 || echo "::warning::ccache doesn't start after unlinking its dependencies"
fi

# BCD's public repo does not ship Apple's iOS libmetalirconverter.dylib (BCD's deps.sh stops without it, after an hour
# of building). NexPlay keeps the iOS dylib and headers of Metal Shader Converter 4.0 beta 3 in
# third_party/metal-shader-converter: copy them into BCD's tree and point BCD's pinned hash (beta 2) at beta 3.
MSC_SRC="$WS/nexplay/third_party/metal-shader-converter"
MSC_VEND="$BCD/madeira-d3d12/third_party/metal-shader-converter"
echo "::group::Metal Shader Converter 4.0 beta 3 (from NexPlay's third_party)"
cp "$MSC_SRC/lib_iOS/libmetalirconverter.dylib" "$BCD/app/Madeira/d3d12/libmetalirconverter.dylib"
rm -rf "$MSC_VEND/include"
mkdir -p "$MSC_VEND"
cp -R "$MSC_SRC/include" "$MSC_VEND/include"
(cd "$MSC_VEND" && find include -type f | LC_ALL=C sort | xargs shasum -a 256 > SHA256SUMS)
python3 - "$BCD" <<'PY'
import sys
bcd = sys.argv[1]
old_lib = "073f903be98e973ff38f4d79f2c48d61ef938754a77b1caedda79c9f05a068c2"
new_lib = "3040a91ea3559dbcf966f3dfbb21614275e217b4f63fcf8c67de23b17d3f5518"
for rel in ("build/madeira-d3d12/deps.sh", "build/madeira-d3d12/fetch-converter.sh"):
    p = bcd + "/" + rel
    s = open(p).read()
    t = s.replace(old_lib, new_lib)
    print(rel, "re-pinned to beta 3" if t != s else "no beta 2 pin found")
    open(p, "w").write(t)
PY
shasum -a 256 "$BCD/app/Madeira/d3d12/libmetalirconverter.dylib"
bash build/madeira-d3d12/deps.sh && echo "deps.sh: converter OK"
echo "::endgroup::"

# Compiler cache (set up by the workflow): count this run's hits from zero.
if command -v ccache >/dev/null 2>&1; then ccache -z >/dev/null 2>&1 || true; fi

echo "::group::BCD's build steps (up to its app archive)"
set -o pipefail
python3 "$NX/run_bcd_ci.py" --root "$BCD" --until "Archive (unsigned)" 2>&1 | tee "$BCD/engine.log"
echo "::endgroup::"

bash "$NX/package_engine.sh" "$BCD" "$WS/out"

if command -v ccache >/dev/null 2>&1; then
  echo "::group::Compiler cache"
  ccache -s || true
  echo "::endgroup::"
fi
