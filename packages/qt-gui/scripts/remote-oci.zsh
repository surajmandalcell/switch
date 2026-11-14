#!/bin/zsh
# Mac entry point for the second build host (oci2, arm64): sync packages/qt-gui to the worker's own folder,
# build and capture inside the switch-qt:tw container (scripts/oci/Dockerfile), pull the PNGs back, and
# compare Settings with the Mac captures. Each worker has its own folders and lock, so workers never wait
# on each other. usage: remote-oci.zsh <worker> [build|shots|all|clean]      (default all)
set -euo pipefail
WORKER=${1:?worker name, for example history}
STEP=${2:-all}
[[ $WORKER =~ '^[a-z0-9][a-z0-9-]*$' && $WORKER != helper ]] || { echo "worker: lowercase letters, digits and dashes, not 'helper'" >&2; exit 2; }
HOST=${SWITCH_OCI_HOST:-oci2}
IMAGE=${SWITCH_OCI_IMAGE:-switch-qt:tw}
REMOTE=/mnt/sdb/data/switch/qt/$WORKER
LOCAL_OUT=${SWITCH_SHOTS_DIR:-/Volumes/External1TB/data/_custom/orca/workspaces/switch/qt-gui/shots/$WORKER}
MAC_CAPTURES=${SWITCH_MAC_CAPTURES:-/Volumes/External1TB/data/_custom/orca/workspaces/switch/update-check}
SRC=${0:A:h:h}

if [[ $STEP == clean ]]; then
  ssh "$HOST" "rm -rf $REMOTE"   # the worker's src, build and shots; the next run starts with a full build
  exit 0
fi

# One container per step; the worker folder is /w inside, so CMake's absolute paths stay valid.
# The lock file is per worker: it only stops one worker's build and shots from overlapping.
# Three full builds at once take 327 s each (128 s alone), so the host needs no shared lock.
# SWITCH_CORE makes the client test also run against the real arm64 helper (/opt/helper, read-only).
# kwin_wayland quits without a render node, and then no window gets frame callbacks (a resized popover
# keeps its old size), so the host's render node goes in. Its own output still fails to draw; the
# captures do not use it (Harness grabs each window).
in_box() {
  ssh "$HOST" "docker run --rm --init --user \$(id -u):\$(id -g) --memory 6g --log-driver local --log-opt max-size=5m \
    --device /dev/dri/renderD128 --group-add \$(getent group render | cut -d: -f3) \
    -v /mnt/sdb/data/switch/qt/helper:/opt/helper:ro -e SWITCH_CORE=/opt/helper/switch-core \
    -e HOME=/tmp -e JOBS=3 -e SWITCH_BUILD_LOCK=/w/qt.lock -v $REMOTE:/w -w /w $IMAGE \
    sh -c 'mkdir -m 700 -p \$XDG_RUNTIME_DIR && $1'"
}

ssh "$HOST" "mkdir -p $REMOTE/src"
rsync -a --delete --exclude build --exclude '.DS_Store' "$SRC/" "$HOST:$REMOTE/src/"
if [[ $STEP == build || $STEP == all ]]; then
  in_box "bash /w/src/scripts/build.sh /w/src /w/build"
fi
if [[ $STEP == shots || $STEP == all ]]; then
  in_box "bash /w/src/scripts/shots.sh /w/build/switch /w/shots"
  mkdir -p "$LOCAL_OUT"
  rsync -a --delete "$HOST:$REMOTE/shots/" "$LOCAL_OUT/qt/"
  bash "$SRC/scripts/compare.sh" "$LOCAL_OUT/qt" "$MAC_CAPTURES" "$LOCAL_OUT/compare"
fi
