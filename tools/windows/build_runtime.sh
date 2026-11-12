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
