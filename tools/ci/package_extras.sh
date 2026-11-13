#!/bin/bash
# NexPlay 7.1.1: everything added to the unsigned NexPlay.app after the Xcode build, before signing and zipping.
# build.yml calls only this script, so new parts don't need a new workflow file.
#   - 8.0.0: the Windows engine's app resources (vendor/bcd-engine from tools/windows/fetch_engine.sh; merge_engine.sh)
#   - EasyRPG Player's libretro core (tools/easyrpg/fetch_easyrpg.sh)
# Usage: package_extras.sh <path to NexPlay.app>   (GH_TOKEN for downloads; NEXPLAY_WINDOWS=1 when the engine is in)
set -euo pipefail
APP="$1"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
bash "$DIR/tools/windows/merge_engine.sh" "$APP"
bash "$DIR/tools/easyrpg/fetch_easyrpg.sh" "$APP"
