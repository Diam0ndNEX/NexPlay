#!/bin/bash
# NexPlay 7.1.1: everything added to the unsigned NexPlay.app after the Xcode build, before signing and zipping.
# build.yml calls only this script, so new parts don't need a new workflow file.
#   - the Windows runtime (newest windows-runtime release, tools/windows/merge_runtime.sh)
#   - EasyRPG Player's libretro core (tools/easyrpg/fetch_easyrpg.sh)
# Usage: package_extras.sh <path to NexPlay.app>   (needs GH_TOKEN and GITHUB_REPOSITORY for the runtime)
set -euo pipefail
APP="$1"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
bash "$DIR/tools/windows/merge_runtime.sh" "$APP"
bash "$DIR/tools/easyrpg/fetch_easyrpg.sh" "$APP"
