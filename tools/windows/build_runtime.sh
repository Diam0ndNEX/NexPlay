#!/bin/bash
# NexPlay 6.4.0: builds BCD's Windows runtime as BCDCore.framework (called by the "Build Windows runtime" workflow,
# docs/workflow-windows-runtime.yml). Layout: $GITHUB_WORKSPACE/nexplay (this repo), $GITHUB_WORKSPACE/bcd (BCD at the
# pinned tag, with submodules). Output: $GITHUB_WORKSPACE/out/BCDRuntime.zip (or .zip.part-*).
#   1. BCD's own workflow steps, up to its app archive (run_bcd_ci.py).
#   2. The app target relinked as a library with NexPlay's two entry points (patch_bcd_for_nexplay.py), archived as
#      BCD's step does it (Debug: "Release builds have crashed the guest", BCD's docs/BUILDING.md).
#   3. BCD's check that DXMT's macdrv symbols are exported, then the package (package_runtime.sh).
# BCD: https://github.com/thebcd69/bcd-games. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
set -euo pipefail
WS="${GITHUB_WORKSPACE:?}"
BCD="$WS/bcd"
NX="$WS/nexplay/tools/windows"
cd "$BCD"

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

echo "::group::BCD's build steps"
python3 "$NX/run_bcd_ci.py" --root "$BCD" --until "Archive (unsigned)"
echo "::endgroup::"

python3 "$NX/patch_bcd_for_nexplay.py" "$BCD"

echo "::group::Archive BCD as a library"
set +e
xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -sdk iphoneos -configuration Debug \
  CODE_SIGNING_ALLOWED=NO archive -archivePath build-out/Madeira.xcarchive > "$BCD/archive.log" 2>&1
rc=$?
set -e
echo "::endgroup::"
if [ "$rc" -ne 0 ]; then
  echo "===== compiler errors ====="
  grep -E "^[^ ].*: (error|fatal error):" "$BCD/archive.log" | head -30 || true
  echo "===== linker diagnostics ====="
  grep -E "Undefined symbol|^ld: |symbol\(s\) not found|referenced from|duplicate symbol" "$BCD/archive.log" | head -40 || true
  echo "::error::BCD's archive as a library failed (archive.log in the runtime-logs artifact)"
  exit "$rc"
fi

python3 "$NX/run_bcd_ci.py" --root "$BCD" --only "Verify the macdrv symbols DXMT resolves at runtime"
bash "$NX/package_runtime.sh" "$BCD" "$WS/out"
