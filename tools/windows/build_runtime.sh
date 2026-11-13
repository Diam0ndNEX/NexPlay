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
# of building). BCD's own fetch-converter.sh makes it from Apple's installer, which Apple's agreement keeps out of
# public places: put "Metal Shader Converter 4.0 beta 2.pkg" as an asset of a DRAFT release with the tag
# "msc-installer" in this repo (the token below can see drafts). Never commit or publish it.
MSC_DYLIB="$BCD/app/Madeira/d3d12/libmetalirconverter.dylib"
if [ ! -f "$MSC_DYLIB" ]; then
  echo "::group::Metal Shader Converter (from the draft release msc-installer)"
  PKG_DIR="$BCD/research/GPTK"
  PKG="$PKG_DIR/Metal Shader Converter 4.0 beta 3.pkg"
  mkdir -p "$PKG_DIR"
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::error::GH_TOKEN is not set for this step: paste the newest docs/workflow-windows-runtime.yml as build-windows-runtime.yml"
    exit 1
  fi
  ASSET_ID=$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
    --jq '[.[] | select(.tag_name == "msc-installer" or .name == "msc-installer") | .assets[] | select(.name | test("\\.pkg$"))][0].id // empty')
  if [ -z "$ASSET_ID" ]; then
    echo "::error::No .pkg asset found on a release tagged msc-installer. Create a DRAFT release with that tag and attach Apple's 'Metal Shader Converter 4.0 beta 2.pkg' (see docs/WINDOWS-PORT.md)."
    exit 1
  fi
  gh api -H "Accept: application/octet-stream" "repos/$GITHUB_REPOSITORY/releases/assets/$ASSET_ID" > "$PKG"
  ls -l "$PKG"
    # BCD pins beta 2 (pkg 1acc33c8..., iOS dylib 073f903b...). The installer Apple offers now is beta 3: when that is what
  # we got, point BCD's two scripts at it (same version line 4.0; its headers replace the vendored ones in fetch-converter.sh).
  B2_PKG=1acc33c87ea663933df89721a998d066106685473020bcbe007cee7a16155734
  B2_LIB=073f903be98e973ff38f4d79f2c48d61ef938754a77b1caedda79c9f05a068c2
  B3_PKG=449833211e4ef0d46bfaa94848e801acff49e226d3c348bba0673f13716be622
  B3_LIB=3040a91ea3559dbcf966f3dfbb21614275e217b4f63fcf8c67de23b17d3f5518
  GOT=$(shasum -a 256 "$PKG" | cut -d' ' -f1)
  if [ "$GOT" = "$B3_PKG" ]; then
    python3 - "$BCD" "$B2_PKG" "$B3_PKG" "$B2_LIB" "$B3_LIB" <<'PY'
import sys
bcd, o_pkg, n_pkg, o_lib, n_lib = sys.argv[1:6]
for rel in ("build/madeira-d3d12/fetch-converter.sh", "build/madeira-d3d12/deps.sh"):
    p = bcd + "/" + rel
    s = open(p).read()
    t = s.replace(o_pkg, n_pkg).replace(o_lib, n_lib).replace("4.0 beta 2.pkg", "4.0 beta 3.pkg")
    print(rel, "patched" if t != s else "NOT CHANGED")
    open(p, "w").write(t)
PY
  elif [ "$GOT" = "$B2_PKG" ]; then
    mv "$PKG" "$PKG_DIR/Metal Shader Converter 4.0 beta 2.pkg"
  else
    echo "::error::The installer is neither beta 2 nor beta 3 (sha256 $GOT): BCD's pinned hashes would reject it"
    exit 1
  fi
  bash build/madeira-d3d12/fetch-converter.sh
  echo "::endgroup::"
fi

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
