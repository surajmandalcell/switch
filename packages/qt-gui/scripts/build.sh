#!/usr/bin/env bash
# Build host: configure and build packages/qt-gui into $BUILD under the shared Qt lock, then run
# the helper client test. usage: build.sh <source dir> <build dir>
set -euo pipefail
SRC=${1:?source dir}
BUILD=${2:?build dir}
LOCK=${SWITCH_BUILD_LOCK:-/mnt/nvme1/data/switch/port/qt.lock}   # Qt builds and captures; the Windows VM keeps build.lock
JOBS=${JOBS:-2}

configure() {
  timeout 1500 flock "$LOCK" cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DSWITCH_CACHEGEN="$1" \
    >"$BUILD.config.log" 2>&1 || { tail -40 "$BUILD.config.log"; exit 1; }
}
compile() { timeout 1500 flock "$LOCK" nice -n 10 ninja -C "$BUILD" -j "$JOBS" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]' | tail -60; }

# Build as shipped (qmlcachegen). If that fails, as with a QML syntax error in one worker's file, build
# again without qmlcachegen so the app still runs and only that page fails to load (a FAILED line in shots).
# shortcut: Qt 6.12 reads Easing.* as undefined without qmlcachegen, so that fallback build loses easing curves;
# drop the fallback when Qt fixes interpreted Easing enums.
configure "${SWITCH_CACHEGEN:-ON}"
if ! compile; then
  echo "BUILD FAILED with qmlcachegen; building again without it, so only the broken QML file fails at run time"
  configure OFF
  compile
fi
test -x "$BUILD/switch"
timeout 120 "$BUILD/tst_helperclient" -o -,txt 2>&1 | tail -15
