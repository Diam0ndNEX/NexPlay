#!/bin/bash
# NexPlay 8.0.0: run by build.yml before "xcodegen generate". Downloads the newest windows-engine-* release (made by the
# "Build Windows runtime" workflow) into vendor/bcd-engine and turns the Windows engine on (NexPlayWindows.yml).
# Without a release the app is built without Windows games, with a warning.
# Usage: fetch_engine.sh   (from the repo root; needs GH_TOKEN and GITHUB_REPOSITORY)
set -euo pipefail
REPO="${GITHUB_REPOSITORY:?}"
DEST=vendor/bcd-engine
TAG=$(gh release list --repo "$REPO" --limit 100 --json tagName,isDraft \
  --jq '[.[] | select(.isDraft | not) | .tagName | select(startswith("windows-engine-"))][0] // ""' || true)
if [ -z "$TAG" ]; then
  echo "::warning::No windows-engine release yet, so this build has no Windows games. Run the \"Build Windows runtime\" workflow once."
  exit 0
fi
if [ -f "$DEST/ENGINE.tag" ] && [ "$(cat "$DEST/ENGINE.tag")" = "$TAG" ] && [ -d "$DEST/lib" ]; then
  echo "Windows engine $TAG already here"
else
  rm -rf "$DEST"
  W=$(mktemp -d)
  gh release download "$TAG" --repo "$REPO" --pattern 'BCDEngine.zip*' --dir "$W"
  shopt -s nullglob
  PARTS=("$W"/BCDEngine.zip.part-*)
  if [ "${#PARTS[@]}" -gt 0 ]; then cat "${PARTS[@]}" > "$W/BCDEngine.zip"; rm -f "${PARTS[@]}"; fi
  unzip -q "$W/BCDEngine.zip" -d "$W/x"
  mkdir -p vendor
  mv "$W/x/BCDEngine" "$DEST"
  rm -rf "$W"
  echo "$TAG" > "$DEST/ENGINE.tag"
fi
[ -f "$DEST/lib/libntdll_unix.a" ] || { echo "::error::$TAG has no libntdll_unix.a"; exit 1; }
cp tools/windows/NexPlayWindows-on.yml NexPlayWindows.yml
echo "NEXPLAY_WINDOWS=1" >> "${GITHUB_ENV:-/dev/null}"
echo "::notice::Windows engine $TAG: BCD's code is compiled into this build ($(du -sh "$DEST" | cut -f1) engine)"
