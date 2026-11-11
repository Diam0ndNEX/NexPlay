#!/usr/bin/env bash
# Builds MkxpCore.framework for NexPlay in CI (only when NEXPLAY_MKXP=1).
#
# The core pattern, the engine release and the scripts come from Empo:
#   Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app (GPL-3.0-only with additional terms)
#   mkxp-z-apple-mobile, https://github.com/mateo-m/mkxp-z-apple-mobile (GPL), built on mkxp-z (GPLv2+).
# Nothing from Empo is committed here: this script downloads the files at the commit tools/mkxp/core.version pins,
# into vendor/empo (same layout as Empo, so its scripts run unchanged), then runs Empo's framework build with
# NexPlay's deployment target. The release itself is checked against its sha256 by Empo's fetch.sh.
#
# Output: vendor/empo/ios/Dependencies/build-iphoneos-arm64/MkxpCore.framework
# The workflow copies it (and the ANGLE frameworks next to it) into NexPlay.app/Frameworks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/tools/mkxp/core.version"
VENDOR="$ROOT/vendor/empo"
RAW="https://raw.githubusercontent.com/mateo-m/empo-app/$EMPO_COMMIT"

FILES=(
  cores/GameCore.h
  cores/gamecore.exports
  cores/framework-common.sh
  cores/PrivacyInfo.xcprivacy
  cores/mkxp/fetch.sh
  cores/mkxp/build-framework-ios.sh
  cores/mkxp/check-framework.sh
  cores/mkxp/mkxp_app_bridge.c
  tools/fetch-angle.sh
  ios/Dependencies/ANGLE/.version
)

rm -rf "$VENDOR"
for file in "${FILES[@]}"; do
  mkdir -p "$VENDOR/$(dirname "$file")"
  echo "==> $file"
  curl -fsSL --retry 3 -o "$VENDOR/$file" "$RAW/$file"
done
chmod +x "$VENDOR"/cores/mkxp/*.sh "$VENDOR"/tools/*.sh

# Use NexPlay's pin (same format as Empo's cores/mkxp/.version).
grep -E '^MKXP_CORE_(VERSION|SHA256|ASSET)=' "$ROOT/tools/mkxp/core.version" > "$VENDOR/cores/mkxp/.version"

export IPHONEOS_DEPLOYMENT_TARGET="${MKXP_MIN_OS:-16.0}"
"$VENDOR/cores/mkxp/build-framework-ios.sh" --sdk iphoneos

FW="$VENDOR/ios/Dependencies/build-iphoneos-arm64/MkxpCore.framework"
test -f "$FW/MkxpCore"
echo "==> built $FW"
