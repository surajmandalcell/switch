#!/bin/zsh
# Mac entry point: sync packages/qt-gui to the build host, build it there, capture every page and the
# popover headless, pull the PNGs back, and compare Settings with the Mac captures.
# usage: remote.zsh [build|shots|all]      (default all)
set -euo pipefail
HOST=${SWITCH_BUILD_HOST:-lin1}
REMOTE=${SWITCH_REMOTE_DIR:-/mnt/nvme1/data/switch/port/qt-gui}
LOCAL_OUT=${SWITCH_SHOTS_DIR:-/Volumes/External1TB/data/_custom/orca/workspaces/switch/qt-gui/shots}
MAC_CAPTURES=${SWITCH_MAC_CAPTURES:-/Volumes/External1TB/data/_custom/orca/workspaces/switch/update-check}
SRC=${0:A:h:h}
STEP=${1:-all}

rsync -a --delete --exclude build --exclude '.DS_Store' "$SRC/" "$HOST:$REMOTE/src/"
if [[ $STEP == build || $STEP == all ]]; then
  ssh "$HOST" "bash $REMOTE/src/scripts/build.sh $REMOTE/src $REMOTE/build"
fi
if [[ $STEP == shots || $STEP == all ]]; then
  ssh "$HOST" "bash $REMOTE/src/scripts/shots.sh $REMOTE/build/switch $REMOTE/shots"
  mkdir -p "$LOCAL_OUT"
  rsync -a --delete "$HOST:$REMOTE/shots/" "$LOCAL_OUT/qt/"
  bash "$SRC/scripts/compare.sh" "$LOCAL_OUT/qt" "$MAC_CAPTURES" "$LOCAL_OUT/compare"
fi
