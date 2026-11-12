#!/bin/bash
# NexPlay 6.4.0: puts the newest Windows runtime release (BCDRuntime.zip from the "Build Windows runtime" workflow) into
# the unsigned NexPlay.app. No release yet: the app is built without Windows games and a warning says so.
# Usage: merge_runtime.sh <path to NexPlay.app>   (needs GH_TOKEN and GITHUB_REPOSITORY)
set -euo pipefail
APP="$1"
REPO="${GITHUB_REPOSITORY:?}"
TAG=$(gh release list --repo "$REPO" --limit 100 --json tagName,isDraft \
  --jq '[.[] | select(.isDraft | not) | .tagName | select(startswith("windows-runtime-"))][0] // ""' || true)
if [ -z "$TAG" ]; then
  echo "::warning::No windows-runtime release yet, so this build has no Windows games. Run the \"Build Windows runtime\" workflow once."
  exit 0
fi
W=$(mktemp -d)
gh release download "$TAG" --repo "$REPO" --pattern 'BCDRuntime.zip*' --dir "$W"
shopt -s nullglob
PARTS=("$W"/BCDRuntime.zip.part-*)
if [ "${#PARTS[@]}" -gt 0 ]; then cat "${PARTS[@]}" > "$W/BCDRuntime.zip"; rm -f "${PARTS[@]}"; fi
unzip -q "$W/BCDRuntime.zip" -d "$W/x"
R="$W/x/BCDRuntime"
[ -f "$R/Frameworks/BCDCore.framework/BCDCore" ] || { echo "::error::$TAG has no BCDCore.framework"; exit 1; }

# BCD's resources beside NexPlay's (NexPlay's own files win a name clash).
rsync -a --ignore-existing "$R/AppResources/" "$APP/"
mkdir -p "$APP/Frameworks" "$APP/PlugIns"
for f in "$R/Frameworks"/*; do
  name=$(basename "$f")
  [ -e "$APP/Frameworks/$name" ] && { echo "keeping NexPlay's $name"; continue; }
  cp -R "$f" "$APP/Frameworks/"
done
cp -R "$R/PlugIns/"* "$APP/PlugIns/" 2>/dev/null || true

# The Info.plist keys BCD needs that NexPlay doesn't set (Merge adds only missing keys).
/usr/libexec/PlistBuddy -c "Merge $R/BCD-Info.plist" "$APP/Info.plist" || echo "::warning::some BCD Info.plist keys were not merged"
echo "$TAG" > "$APP/WindowsRuntime.version"
echo "::notice::Windows runtime $TAG added ($(du -sh "$APP" | cut -f1) app)"
rm -rf "$W"
