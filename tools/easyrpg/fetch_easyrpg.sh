#!/bin/bash
# NexPlay 7.1.1: puts EasyRPG Player's libretro core for iOS arm64 into the unsigned app as EasyRPGCore.framework.
# The core is the libretro buildbot's nightly build (https://buildbot.libretro.com/nightly/apple/ios-arm64/latest/).
# EasyRPG Player: https://easyrpg.org, GPL-3.0; liblcf: MIT. Without a download the app is built without it (warning).
# Usage: fetch_easyrpg.sh <path to NexPlay.app>
set -euo pipefail
APP="$1"
URL="${EASYRPG_CORE_URL:-https://buildbot.libretro.com/nightly/apple/ios-arm64/latest/easyrpg_libretro.dylib.zip}"
W=$(mktemp -d)
if ! curl -fsSL --retry 3 --retry-delay 5 -o "$W/core.zip" "$URL"; then
  echo "::warning::The EasyRPG core couldn't be downloaded ($URL), so this build has no native RPG Maker 2000/2003."
  exit 0
fi
unzip -q "$W/core.zip" -d "$W/x"
DYLIB=$(find "$W/x" -name '*.dylib' | head -1)
[ -n "$DYLIB" ] || { echo "::warning::No .dylib in the EasyRPG download."; exit 0; }
lipo -info "$DYLIB" || true
if ! lipo -archs "$DYLIB" 2>/dev/null | grep -qw arm64; then
  echo "::warning::The EasyRPG core isn't arm64; skipped."; exit 0
fi
FW="$APP/Frameworks/EasyRPGCore.framework"
mkdir -p "$FW"
cp "$DYLIB" "$FW/EasyRPGCore"
install_name_tool -id @rpath/EasyRPGCore.framework/EasyRPGCore "$FW/EasyRPGCore"
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>EasyRPGCore</string>
	<key>CFBundleIdentifier</key><string>com.nexplay.app.EasyRPGCore</string>
	<key>CFBundleName</key><string>EasyRPGCore</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>16.0</string>
</dict>
</plist>
PLIST
DATE=$(curl -fsSI "$URL" | awk -F': ' 'tolower($1)=="last-modified" {print $2}' | tr -d '\r' || true)
echo "${DATE:-$(date -u +%Y-%m-%d)}" > "$FW/core.version"
ldid -S "$FW/EasyRPGCore"
echo "::notice::EasyRPG core added ($(du -sh "$FW" | cut -f1), ${DATE:-today})"
rm -rf "$W"
