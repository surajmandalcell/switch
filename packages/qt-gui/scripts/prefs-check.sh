#!/usr/bin/env bash
# Build host: prove a Settings write survives a restart. Two headless runs share one temporary --root
# (and a temporary XDG config home, so Open at Login can never touch the real profile): the first clicks
# the row's switch, the second only reads it back. usage: prefs-check.sh <switch binary> <switch-core> [key]
set -uo pipefail
BIN=${1:?switch binary}
CORE=${2:?switch-core}
KEY=${3:-minimizeToTray}
LOCK=${SWITCH_BUILD_LOCK:-/mnt/nvme1/data/switch/port/qt.lock}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME=$TMP/config BIN CORE KEY TMP

cat > "$TMP/inner.sh" <<'EOF'
#!/usr/bin/env bash
SOCK=switch-prefs-$$
kwin_wayland --virtual --socket "$SOCK" --width 1600 --height 1200 --no-lockscreen --no-global-shortcuts >/dev/null 2>&1 &
K=$!
for i in $(seq 1 50); do [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && break; sleep 0.2; done
WAYLAND_DISPLAY=$SOCK QT_QPA_PLATFORM=wayland timeout 90 "$BIN" --helper "$CORE" --root "$TMP/root" --no-motion --script prefs --out "$TMP" "$@"
rc=$?
kill $K 2>/dev/null; wait $K 2>/dev/null
exit $rc
EOF

run() { timeout 200 flock "$LOCK" dbus-run-session -- bash "$TMP/inner.sh" "$@" 2>&1 | grep -E 'PREF|MISSING|qml|QML|rror' | head -20; }
echo "run 1 (toggle):"; run --toggle "$KEY"
echo "run 2 (read):";   run
echo "settings file:"; grep -o "\"$KEY\"[^,}]*" "$TMP/root/switch/settings.json" "$TMP/root/settings.json" 2>/dev/null
