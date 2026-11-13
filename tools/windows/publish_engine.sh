#!/bin/bash
# NexPlay 8.0.0: publishes out/BCDEngine.zip* as release windows-engine-<BCD tag>-<run> in this repository.
# NexPlay's app build (fetch_engine.sh) takes the newest such release.
set -euo pipefail
WS="${GITHUB_WORKSPACE:?}"
TAG="windows-engine-${BCD_TAG:?}-${GITHUB_RUN_NUMBER:-0}"
shopt -s nullglob
FILES=("$WS"/out/BCDEngine.zip*)
[ "${#FILES[@]}" -gt 0 ] || { echo "::error::no BCDEngine.zip to publish"; exit 1; }
gh release create "$TAG" "${FILES[@]}" --repo "$GITHUB_REPOSITORY" \
  --title "Windows engine (BCD ${BCD_TAG})" \
  --notes "BCD ${BCD_TAG}'s engine (Wine, FEX, DXMT, libraries and app resources) for NexPlay, which compiles BCD's app code itself (NexPlay/Windows/BCD). NexPlay builds take the newest windows-engine release. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games), GPL-3.0."
echo "::notice::published $TAG"
