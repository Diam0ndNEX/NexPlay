#!/bin/bash
# NexPlay 6.4.0: packs the archived BCD app (built as a library) into BCDRuntime.zip:
#   BCDRuntime/Frameworks/BCDCore.framework   BCD's code (the app binary, a dylib now) + BCD's other frameworks
#   BCDRuntime/AppResources/                  everything else in BCD's app folder (Windows DLL folders, nls, prefix
#                                             template, OpenGL dylibs, licences ...): merged into NexPlay.app's folder,
#                                             where BCD's code finds them through Bundle.main
#   BCDRuntime/PlugIns/                       BCD's JIT helper and memory host, renamed to NexPlay's bundle id
#   BCDRuntime/BCD-Info.plist                 the Info.plist keys NexPlay takes over (merge_runtime.sh)
# Usage: package_runtime.sh <bcd checkout> <out dir>
set -euo pipefail
BCD="$1"
OUT_DIR="$2"
APP="$BCD/build-out/Madeira.xcarchive/Products/Applications/Madeira.app"
R="$OUT_DIR/BCDRuntime"
[ -f "$APP/Madeira" ] || { echo "::error::no archived app at $APP"; exit 1; }
if ! otool -hv "$APP/Madeira" | grep -q DYLIB; then
  echo "::error::Madeira was not linked as a dynamic library"; otool -hv "$APP/Madeira"; exit 1
fi
rm -rf "$OUT_DIR"; mkdir -p "$R/AppResources" "$R/Frameworks/BCDCore.framework" "$R/PlugIns"

FW="$R/Frameworks/BCDCore.framework"
cp "$APP/Madeira" "$FW/BCDCore"
install_name_tool -id @rpath/BCDCore.framework/BCDCore "$FW/BCDCore"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist" 2>/dev/null || echo 0.1)
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BCDCore</string>
	<key>CFBundleIdentifier</key><string>com.nexplay.app.BCDCore</string>
	<key>CFBundleName</key><string>BCDCore</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>18.0</string>
</dict>
</plist>
PLIST
ldid -S "$FW/BCDCore"

for item in "$APP"/* "$APP"/.[!.]*; do
  [ -e "$item" ] || continue
  name=$(basename "$item")
  case "$name" in
    Madeira|Info.plist|PkgInfo|_CodeSignature|embedded.mobileprovision|Frameworks|PlugIns|Assets.car|AppIcon*|*.storyboardc|LaunchScreen*|SC_Info) continue ;;
  esac
  cp -R "$item" "$R/AppResources/"
done

if [ -d "$APP/Frameworks" ]; then
  for f in "$APP/Frameworks"/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in StikJIT.framework) continue ;; esac   # NexPlay ships its own StikJIT
    cp -R "$f" "$R/Frameworks/"
  done
fi

if [ -d "$APP/PlugIns" ]; then
  for p in "$APP/PlugIns"/*.appex; do
    [ -e "$p" ] || continue
    name=$(basename "$p" .appex)
    cp -R "$p" "$R/PlugIns/"
    plist="$R/PlugIns/$name.appex/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.nexplay.app.BCD$name" "$plist"
    exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist")
    ent=""
    case "$name" in
      MadeiraJITHelper) ent="$BCD/app/MadeiraJITHelper/JITHelper.entitlements" ;;
      MadeiraMemoryHost) ent="$BCD/app/MadeiraMemoryHost/MemoryHost.entitlements" ;;
    esac
    if [ -n "$ent" ] && [ -f "$ent" ]; then ldid -S"$ent" "$R/PlugIns/$name.appex/$exe"; else ldid -S "$R/PlugIns/$name.appex/$exe"; fi
    echo "plug-in $name -> com.nexplay.app.BCD$name"
  done
fi

python3 - "$APP/Info.plist" "$R/BCD-Info.plist" <<'PY'
import plistlib, sys
src = plistlib.load(open(sys.argv[1], "rb"))
keep = {"CADisableMinimumFrameDurationOnPhone", "GCSupportsControllerUserInteraction", "GCSupportedGameControllers",
        "GCSupportsGameMode", "UIApplicationSupportsIndirectInputEvents", "UIRequiresFullScreen", "LSSupportsGameMode"}
out = {k: v for k, v in src.items()
       if k in keep or k.startswith("Madeira") or k.startswith("BCD") or (k.startswith("NS") and k.endswith("UsageDescription"))}
plistlib.dump(out, open(sys.argv[2], "wb"))
print("Info.plist keys for NexPlay:", ", ".join(sorted(out)))
PY

echo "BCDRuntime: $(du -sh "$R" | cut -f1)"
cd "$OUT_DIR"
zip -qry -1 BCDRuntime.zip BCDRuntime
SIZE=$(wc -c < BCDRuntime.zip | tr -d ' ')
echo "BCDRuntime.zip: $SIZE bytes"
if [ "$SIZE" -gt 1900000000 ]; then
  split -b 1900m BCDRuntime.zip BCDRuntime.zip.part-
  rm BCDRuntime.zip
  ls -la BCDRuntime.zip.part-*
fi
rm -rf "$R"
