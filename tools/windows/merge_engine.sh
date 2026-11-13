#!/bin/bash
# NexPlay 8.0.0: puts the Windows engine's app resources (vendor/bcd-engine/resources, from fetch_engine.sh) into the
# unsigned NexPlay.app, signs its loose dylibs ad hoc (as BCD's "Sign bundled dylibs" phase) and checks that NexPlay's
# binary exports the macdrv_* symbols DXMT looks up with dlsym (BCD's "Verify the macdrv symbols" step).
# Does nothing in a build without the engine.
# Usage: merge_engine.sh <path to NexPlay.app>
set -euo pipefail
APP="$1"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
E="$DIR/vendor/bcd-engine"
if [ "${NEXPLAY_WINDOWS:-0}" != "1" ] || [ ! -d "$E/resources" ]; then
  echo "No Windows engine in this build"
  exit 0
fi
# NexPlay's own files win a name clash.
for item in "$E/resources"/*; do
  name=$(basename "$item")
  if [ -e "$APP/$name" ]; then echo "keeping NexPlay's $name"; continue; fi
  cp -R "$item" "$APP/"
done
for dylib in "$APP"/d3d12/*.dylib "$APP"/gl/*.dylib; do
  [ -f "$dylib" ] || continue
  ldid -S "$dylib" && echo "signed $(basename "$dylib")"
done
cat "$E/ENGINE.tag" > "$APP/WindowsEngine.version"

BIN="$APP/NexPlay"
xcrun dyld_info -exports "$BIN" > /tmp/nexplay-exports.txt 2>&1 || nm -gU "$BIN" > /tmp/nexplay-exports.txt 2>&1 || true
MISSING=""
for sym in macdrv_functions get_win_data release_win_data macdrv_view_create_metal_view macdrv_view_get_metal_layer \
           macdrv_view_release_metal_view; do
  grep -qE "_$sym\$|_$sym " /tmp/nexplay-exports.txt || MISSING="$MISSING $sym"
done
if [ -n "$MISSING" ]; then
  echo "::error::NexPlay's binary does not export$MISSING: DXMT's dlsym would fail and Direct3D 11 games would stay black"
  exit 1
fi
echo "::notice::Windows engine $(cat "$E/ENGINE.tag") added ($(du -sh "$APP" | cut -f1) app); the six macdrv symbols are exported"
