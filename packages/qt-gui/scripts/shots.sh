#!/usr/bin/env bash
# Build host: run the app headless inside a private virtual kwin_wayland (own socket, own D-Bus
# session; the desktop session is untouched) and write PNGs for every page and the popover in Light
# and Dark at 1x and 2x. A second pass renders Settings as a content-view capture (no window buttons,
# no outline, square corners) with and without an update, for the Mac comparison.
# usage: shots.sh <switch binary> <out dir>
set -uo pipefail
BIN=${1:?switch binary}
OUT=${2:?out dir}
LOCK=${SWITCH_BUILD_LOCK:-/mnt/nvme1/data/switch/port/build.lock}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
mkdir -p "$OUT/compare"
INNER=$(mktemp --suffix=.sh)
trap 'rm -f "$INNER"' EXIT

# One app run per call: run <scale> <out> <app args...>
cat > "$INNER" <<'EOF'
#!/usr/bin/env bash
SCALE=$1; DIR=$2; shift 2
SOCK=switch-shots-$$
kwin_wayland --virtual --socket "$SOCK" --width 3000 --height 2300 --no-lockscreen --no-global-shortcuts >/dev/null 2>&1 &
K=$!
for i in $(seq 1 50); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.2; done
WAYLAND_DISPLAY=$SOCK QT_QPA_PLATFORM=wayland QT_SCALE_FACTOR=$SCALE \
  timeout 120 "$BIN" --demo --no-motion --script shots --out "$DIR" --scale "$SCALE" "$@"
rc=$?
kill $K 2>/dev/null; wait $K 2>/dev/null
exit $rc
EOF
export BIN

run() { timeout 300 flock "$LOCK" dbus-run-session -- bash "$INNER" "$@" 2>&1 | grep -E '^SHOT|qml|QML|rror' | head -40; }

for scale in 1 2; do
  for theme in light dark; do
    run "$scale" "$OUT" --theme "$theme" --gallery
  done
done
for theme in light dark; do
  run 1 "$OUT/compare" --theme "$theme" --content-only --pages settings
  run 1 "$OUT/compare/update" --theme "$theme" --content-only --pages settings --update
done
