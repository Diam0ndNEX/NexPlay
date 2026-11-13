#!/bin/bash
# NexPlay 8.0.0: packs BCD's built engine into BCDEngine.zip for NexPlay's app build (fetch_engine.sh, merge_engine.sh):
#   BCDEngine/lib/*.a          the static libraries BCD's app target links (Wine's unix side, wineserver, FEX, DXMT +
#                              LLVM, GnuTLS, FFmpeg, the pairing library), from app/Madeira and FEX/build-ios
#   BCDEngine/fex/             FEX's headers (same tree as BCD's FEX checkout) for NexPlay/Windows/BCD/FEXBridge.mm
#   BCDEngine/resources/       what BCD's Xcode Resources phase and "Bundle Wine Mono" put into the app: the Windows DLL
#                              folders, nls, the prefix template, compat, OpenGL/Vulkan, Direct3D 12, licences, ...
#   BCDEngine/ENGINE.txt       BCD tag and commit
# Usage: package_engine.sh <bcd checkout> <out dir>
# BCD: https://github.com/thebcd69/bcd-games. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
set -euo pipefail
BCD="$1"
OUT_DIR="$2"
M="$BCD/app/Madeira"
E="$OUT_DIR/BCDEngine"
rm -rf "$OUT_DIR"
mkdir -p "$E/lib" "$E/fex" "$E/resources"
missing=""

echo "::group::Libraries"
for a in libgmp.a libgnutls.a libhogweed.a libnettle.a libntdll_unix.a libwin32u_unix.a libwineserver.a \
         libdxmt_combined.a libmadeira_rppairing.a libavformat.a libavcodec.a libswresample.a libavutil.a; do
  if [ -f "$M/$a" ]; then cp "$M/$a" "$E/lib/"; else missing="$missing $a"; fi
done
for a in FEXCore/Source/libFEXCore.a FEXCore/Source/libFEXCore_Base.a FEXCore/Source/libJemallocLibs.a \
         External/cephes/libcephes_128bit.a External/fmt/libfmt.a External/SoftFloat-3e/libsoftfloat_3e.a \
         External/xxhash/cmake_unofficial/libxxhash.a; do
  if [ -f "$BCD/FEX/build-ios/$a" ]; then cp "$BCD/FEX/build-ios/$a" "$E/lib/"; else missing="$missing FEX/build-ios/$a"; fi
done
ls -la "$E/lib"
echo "::endgroup::"
if [ -n "$missing" ]; then
  echo "::error::the engine is missing libraries:$missing"
  exit 1
fi

echo "::group::FEX headers"
rsync -a --prune-empty-dirs --exclude='.git/' --include='*/' \
  --include='*.h' --include='*.hpp' --include='*.hh' --include='*.inc' --include='*.inl' --include='*.def' \
  --include='*.ipp' --include='*.tcc' --exclude='*' "$BCD/FEX/" "$E/fex/"
echo "FEX headers: $(find "$E/fex" -type f | wc -l | tr -d ' ') files, $(du -sh "$E/fex" | cut -f1)"
echo "::endgroup::"

echo "::group::App resources"
for item in nls aarch64-windows arm64ec-windows i386-windows x86_64-vcruntime compat gl vulkan d3d12 legal licenses \
            soundfont prefix-template.tar.gz cacert.pem; do
  if [ -e "$M/$item" ]; then
    cp -R "$M/$item" "$E/resources/"
    echo "  $item: $(du -sh "$M/$item" | cut -f1)"
  else
    echo "::warning::BCD's app folder has no $item (the app is built without it)"
  fi
done
# BCD's "Bundle Wine Mono" phase (build/wine-mono/bundle.sh): .NET games.
if [ -f "$BCD/build/wine-mono/bundle.sh" ]; then
  bash "$BCD/build/wine-mono/bundle.sh" "$E/resources/wine-mono" || echo "::warning::Wine Mono was not bundled"
fi
echo "::endgroup::"

COMMIT=$(git -C "$BCD" rev-parse HEAD 2>/dev/null || echo unknown)
printf 'tag=%s\ncommit=%s\nbuilt=%s\n' "${BCD_TAG:-unknown}" "$COMMIT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$E/ENGINE.txt"

echo "BCDEngine: $(du -sh "$E" | cut -f1)"
cd "$OUT_DIR"
zip -qry -1 BCDEngine.zip BCDEngine
SIZE=$(wc -c < BCDEngine.zip | tr -d ' ')
echo "BCDEngine.zip: $SIZE bytes"
if [ "$SIZE" -gt 1900000000 ]; then
  split -b 1900m BCDEngine.zip BCDEngine.zip.part-
  rm BCDEngine.zip
  ls -la BCDEngine.zip.part-*
fi
rm -rf "$E"
