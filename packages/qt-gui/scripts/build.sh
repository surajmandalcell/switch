#!/usr/bin/env bash
# Build host: configure and build packages/qt-gui into $BUILD under the shared build lock, then run
# the helper client test. usage: build.sh <source dir> <build dir>
set -euo pipefail
SRC=${1:?source dir}
BUILD=${2:?build dir}
LOCK=${SWITCH_BUILD_LOCK:-/mnt/nvme1/data/switch/port/build.lock}
JOBS=${JOBS:-2}

timeout 1500 flock "$LOCK" cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release > "$BUILD.config.log" 2>&1 \
  || { tail -40 "$BUILD.config.log"; exit 1; }
timeout 1500 flock "$LOCK" nice -n 10 ninja -C "$BUILD" -j "$JOBS" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]' | tail -60
test -x "$BUILD/switch"
timeout 120 "$BUILD/tst_helperclient" -o -,txt 2>&1 | tail -15
