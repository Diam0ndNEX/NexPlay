#!/bin/bash
# 6.3.0: puts StikJIT.xcframework into vendor/StikJIT for NexPlay's JIT helper extension.
# StikJIT, https://github.com/StikDebug/StikJIT (MPL-2.0), bundles idevice by Jackson Coxson (MIT).
# The release in tools/jit/stikjit.version is used when this Xcode can read its Swift interface;
# otherwise the same tag is built from source with this Xcode. CI only: vendor/ is never committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \n\r' < "$ROOT/tools/jit/stikjit.version")"
DEST="$ROOT/vendor/StikJIT"
rm -rf "$DEST"
mkdir -p "$DEST"
echo "StikJIT $VERSION with $(xcodebuild -version | head -1)"

if curl -fsSL -o "$DEST/StikJIT.xcframework.zip" \
    "https://github.com/StikDebug/StikJIT/releases/download/$VERSION/StikJIT.xcframework.zip"; then
  (cd "$DEST" && unzip -q StikJIT.xcframework.zip && rm -f StikJIT.xcframework.zip)
else
  echo "::warning::Couldn't download the StikJIT $VERSION release."
fi

FW="$DEST/StikJIT.xcframework/ios-arm64/StikJIT.framework"
OK=0
if [ -d "$FW" ]; then
  OK=1
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  for interface in "$FW/Modules/StikJIT.swiftmodule/"*.swiftinterface; do
    if ! xcrun swift-frontend -typecheck-module-from-interface "$interface" -sdk "$SDK" \
        -module-cache-path "$DEST/interface-cache" -module-name StikJIT; then
      OK=0
    fi
  done
  rm -rf "$DEST/interface-cache"
fi

if [ "$OK" != "1" ]; then
  echo "::warning::The StikJIT release doesn't fit this Xcode; building StikJIT $VERSION from source."
  rm -rf "$DEST/StikJIT.xcframework" "$DEST/src"
  git clone --depth 1 --branch "$VERSION" https://github.com/StikDebug/StikJIT.git "$DEST/src"
  (cd "$DEST/src" && xcodegen generate && xcodebuild archive -project StikJIT.xcodeproj -scheme StikJIT \
    -destination 'generic/platform=iOS' -archivePath build/StikJIT-iOS \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO)
  xcodebuild -create-xcframework \
    -framework "$DEST/src/build/StikJIT-iOS.xcarchive/Products/Library/Frameworks/StikJIT.framework" \
    -output "$DEST/StikJIT.xcframework"
  rm -rf "$DEST/src"
fi

if [ ! -d "$DEST/StikJIT.xcframework" ]; then
  echo "::error::No StikJIT.xcframework: built-in JIT can't be built."
  exit 1
fi
echo "StikJIT ready:"
ls "$DEST/StikJIT.xcframework"
