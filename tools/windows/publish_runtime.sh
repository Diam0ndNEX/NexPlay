#!/bin/bash
# NexPlay 6.4.0: publishes out/BCDRuntime.zip* as release windows-runtime-<BCD tag>-<run> in this repository.
# NexPlay's app build (merge_runtime.sh) takes the newest such release.
set -euo pipefail
WS="${GITHUB_WORKSPACE:?}"
TAG="windows-runtime-${BCD_TAG:?}-${GITHUB_RUN_NUMBER:-0}"
shopt -s nullglob
FILES=("$WS"/out/BCDRuntime.zip*)
[ "${#FILES[@]}" -gt 0 ] || { echo "::error::no BCDRuntime.zip to publish"; exit 1; }
gh release create "$TAG" "${FILES[@]}" --repo "$GITHUB_REPOSITORY" \
  --title "Windows runtime (BCD ${BCD_TAG})" \
  --notes "BCD ${BCD_TAG} built as a library for NexPlay (tools/windows). NexPlay builds take the newest windows-runtime release. Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games), GPL-3.0."
echo "::notice::published $TAG"
