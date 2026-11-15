#!/bin/sh
# Clean-host check of the app folder: run inside a plain distro container (no Qt, no Swift).
# usage: check-package.sh <app folder> [out dir for a capture; needs a harness build as bin/switch]
set -u
APP=$1
OUT=${2:-}
T=$(mktemp -d)
rc=0

echo "== libraries the host does not have"
find "$APP" -type f \( -name '*.so*' -o -path "$APP/bin/*" \) ! -name qt.conf | while read -r f; do
  ldd "$f" 2>/dev/null | awk '/not found/ {print $1}'
done | sort -u | tr '\n' ' ' | awk '{print} END {if (NR == 0) print "none"}'

echo "== switch-core doctor"
# A container has no terminal app; TERMINAL stands in for the one a desktop has (sign-ins open it).
TERMINAL=/bin/true "$APP/bin/switch-core" doctor --root "$T/doctor" || rc=1

echo "== switch-core serve: initialize"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' |
  timeout 30 "$APP/bin/switch-core" serve --root "$T/serve" > "$T/serve.out" 2> "$T/serve.err"
grep -o '"result":{"[^,]*,"[^,]*' "$T/serve.out" | head -1 || { cat "$T/serve.err"; rc=1; }

# The software scene graph: a container has no GPU. QSG_RHI_BACKEND keeps main.cpp from forcing OpenGL.
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QSG_RHI_BACKEND=opengl QT_FORCE_STDERR_LOGGING=1 LANG=C.UTF-8
if [ -n "$OUT" ]; then
  echo "== app --demo, capture of the Settings page"
  mkdir -p "$OUT"
  timeout 120 "$APP/bin/switch" --demo --no-motion --script shots --out "$OUT" --pages settings --content-only > "$T/app.log" 2>&1
  s=$?
  tail -20 "$T/app.log"
  echo "exit $s"
  ls "$OUT"
  [ "$s" = 0 ] || rc=1
else
  echo "== app --demo, 10 s"
  timeout 10 "$APP/bin/switch" --demo > "$T/app.log" 2>&1
  s=$?
  tail -20 "$T/app.log"
  echo "exit $s (124 = still running after 10 s, the expected result)"
  [ "$s" = 124 ] || rc=1
fi

# Every page in demo mode: a missing QML module or plugin fails that page's Loader, and the app logs it.
BAD='failed to load|is not installed|Cannot load library|plugin cannot be loaded'
for page in Overview Accounts Settings Maintenance History; do
  timeout 8 "$APP/bin/switch" --demo --page "$page" > "$T/page.log" 2>&1
  s=$?
  n=$(grep -cE "$BAD" "$T/page.log")
  echo "page $page: exit $s (124 = running), load errors $n"
  [ "$s" = 124 ] && [ "$n" = 0 ] || { grep -E "$BAD" "$T/page.log" | head -5; rc=1; }
done

# The folder dialog's non-native form (offscreen has no native one) loads Quick Controls, which the package
# trims to Basic. QML_TOOL is Qt's qml binary; in bin/ it uses the package's qt.conf, libraries, and modules.
if [ -n "${QML_TOOL:-}" ]; then
  cp "$QML_TOOL" "$APP/bin/qml"
  printf '%s\n' 'import QtQuick' 'import QtQuick.Dialogs' 'Window {' '  width: 800; height: 600; visible: true' \
    '  FolderDialog { id: dialog; title: "probe" }' '  Timer { interval: 300; running: true; onTriggered: dialog.open() }' \
    '  Timer { interval: 3000; running: true; onTriggered: { console.log("DIALOG visible=" + dialog.visible); Qt.quit() } }' \
    '}' > "$T/dialog.qml"
  QT_QUICK_CONTROLS_STYLE=Basic timeout 20 "$APP/bin/qml" "$T/dialog.qml" > "$T/dialog.log" 2>&1
  rm "$APP/bin/qml"
  if grep -q 'DIALOG visible=true' "$T/dialog.log" && ! grep -qE "$BAD" "$T/dialog.log"; then
    echo "folder dialog (Basic): shown"
  else
    echo "folder dialog (Basic): FAILED"; tail -8 "$T/dialog.log"; rc=1
  fi
fi
exit $rc
