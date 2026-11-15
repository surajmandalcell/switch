#!/usr/bin/env bash
# Build the self-contained Linux app folder, then a tar.gz and an AppImage from it. Runs in the switch-pkg
# image (Dockerfile here), on arm64 or x86_64.
# usage: build-package.sh <qt-gui source> <out dir> <switch-core folder (switch-core + lib/)> <app icon, 512 px or more>
set -euo pipefail
SRC=$(realpath "$1"); OUT=$(realpath -m "$2"); HELPER=$(realpath "$3"); ICON=$(realpath "$4")
QT=$(realpath "${QT_PREFIX:?Qt prefix, for example /opt/qt/current}")
HERE=$(dirname "$(realpath "$0")")
ARCH=$(uname -m)
VERSION=$(sed -n 's/.*setApplicationVersion("\([^"]*\)").*/\1/p' "$SRC/src/main.cpp")
QT_VERSION=$("$QT/bin/qtpaths" --qt-version)
APP=$OUT/Switch
BUILD=$OUT/build
mkdir -p "$OUT"

# 1. Release build with the official Qt. Shipping builds have no harness and no tests (README Licensing).
cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT" \
  -DSWITCH_HARNESS="${SWITCH_HARNESS:-OFF}" -DSWITCH_TESTS=OFF > "$BUILD.config.log"
ninja -C "$BUILD" -j "${JOBS:-3}" switch > "$BUILD.log" 2>&1 || { grep -m 20 -E 'error|FAILED' "$BUILD.log"; exit 1; }

# 2. The app folder. The app starts the helper from its own folder (main.cpp), so both live in bin/.
rm -rf "$APP"
mkdir -p "$APP/bin" "$APP/lib" "$APP/plugins" "$APP/qml" "$APP/share/applications" "$APP/share/licenses/switch"
cp "$BUILD/switch" "$HELPER/switch-core" "$APP/bin/"
strip --strip-debug "$APP/bin/switch" "$APP/bin/switch-core"   # debug info only (27 MB); symbols stay for backtraces
cp "$HELPER"/lib/*.so* "$APP/lib/"
printf '[Paths]\nPrefix = ..\nLibraries = lib\nPlugins = plugins\nQmlImports = qml\n' > "$APP/bin/qt.conf"

# Plugins: Wayland and X11 windows (offscreen for headless runs), input methods, the portal theme (file
# dialogs, dark mode), SVG images and icons. No TLS backend: the app makes no network calls.
PLUGINS=(platforms/libqxcb.so platforms/libqwayland.so platforms/libqoffscreen.so
  xcbglintegrations/*.so wayland-shell-integration/libxdg-shell.so wayland-decoration-client/*.so
  wayland-graphics-integration-client/libqt-plugin-wayland-egl.so platforminputcontexts/*.so platformthemes/libqxdgdesktopportal.so
  imageformats/libqsvg.so iconengines/libqsvgicon.so)
for p in "${PLUGINS[@]}"; do
  mkdir -p "$APP/plugins/${p%/*}"
  cp "$QT"/plugins/$p "$APP/plugins/${p%/*}/"   # an unmatched name fails the build
done

# QML modules the app imports, resolved through their qmldir dependencies by the import scanner.
"$QT/libexec/qmlimportscanner" -rootPath "$SRC/qml" -importPath "$QT/qml" > "$OUT/qml-imports.json"
MODS=$(python3 -c 'import json,sys; print("\n".join(sorted({m["path"] for m in json.load(sys.stdin) if m.get("type") == "module" and m.get("path")})))' < "$OUT/qml-imports.json")
for d in $MODS; do mkdir -p "$APP/qml/${d#$QT/qml/}"; cp -a "$d/." "$APP/qml/${d#$QT/qml/}/"; done
# A module folder holds its child modules too; drop the children nothing imports (deepest first).
find "$APP/qml" -name qmldir -printf '%h\n' | sort -r | while read -r d; do
  rel=${d#$APP/qml/}
  grep -qxF "$QT/qml/$rel" <<<"$MODS" || grep -qF "$QT/qml/$rel/" <<<"$MODS" || rm -rf "$d"
done
find "$APP/qml" -type d -name designer -prune -exec rm -rf {} +

# 3. Library closure: copy every library an ELF file here loads from the Qt prefix, until nothing is new.
# Everything else must come from the host; that list is written to host-libs.txt.
elves() { find "$APP" -type f -exec sh -c 'file -b "$1" | grep -q "^ELF"' _ {} \; -print; }
deps() { elves | while read -r f; do LD_LIBRARY_PATH="$QT/lib:$APP/lib" ldd "$f"; done | awk '$2 == "=>" {print $1, $3}' | sort -u; }
while :; do
  new=0
  while read -r name target; do
    [ "$target" = not ] && { echo "missing library: $name" >&2; exit 1; }
    case $target in "$QT"/lib/*) [ -e "$APP/lib/$name" ] || { cp -L "$target" "$APP/lib/$name"; new=1; } ;; esac
  done < <(deps)
  [ $new = 0 ] && break
done
# Direct needs only (DT_NEEDED); the host's own libraries bring their own dependencies.
elves | xargs readelf -d | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u | while read -r n; do
  [ -e "$APP/lib/$n" ] || echo "$n"
done > "$OUT/host-libs.txt"

# RUNPATH: every ELF file finds lib/ relative to itself; no LD_LIBRARY_PATH wrapper.
elves | while read -r f; do
  rel=$(realpath --relative-to="$(dirname "$f")" "$APP/lib")
  if [ "$rel" = . ]; then patchelf --set-rpath '$ORIGIN' "$f"; else patchelf --set-rpath "\$ORIGIN/$rel" "$f"; fi
done

# GPL-only or excluded Qt modules must never ship (README Licensing).
if find "$APP" -iregex '.*\(Charts\|Graphs\|Quick3D\|ShaderTools\|QuickTimeline\|DataVisualization\|VirtualKeyboard\|WaylandCompositor\).*' | grep -q .; then
  echo "a GPL-only or excluded Qt module is in the package" >&2; exit 1
fi

# 4. Desktop entry, hicolor icons, licenses. The entry is named by the app id: the shortcut portal
# matches kAppId (src/globalshortcut.cpp) to an installed entry. install.sh adds it to the user's menu.
ID=com.mandalsuraj.Switch
cp "$HERE/$ID.desktop" "$APP/share/applications/$ID.desktop"
install -m 755 "$HERE/install.sh" "$APP/install.sh"
for s in 16 24 32 48 64 128 256 512; do
  mkdir -p "$APP/share/icons/hicolor/${s}x$s/apps"
  convert "$ICON" -resize "${s}x$s" "$APP/share/icons/hicolor/${s}x$s/apps/$ID.png"
done
L=$APP/share/licenses/switch
cp /usr/share/common-licenses/LGPL-3 "$L/Qt-LGPL-3.0.txt"
cp /usr/share/common-licenses/GPL-3 "$L/GPL-3.0.txt"   # LGPL v3 adds terms to the GPL v3 text
cp "$HERE/licenses/Swift-LICENSE.txt" "$HERE/licenses/ICU-LICENSE.txt" "$L/"
cp "$SRC/fonts/LICENSE.txt" "$L/Inter-OFL-1.1.txt"
cp "$SRC/fonts/LICENSE-JetBrainsMono.txt" "$L/JetBrainsMono-OFL-1.1.txt"
cp "$SRC/assets/providers/brand/BRAND-SOURCES.md" "$L/provider-marks.md"
python3 "$HERE/notices.py" "$APP" "$QT_VERSION" /opt/qt-src > "$L/Qt-NOTICES.txt"

# 5. AppImage files at the top of the folder, then both archives.
ln -s bin/switch "$APP/AppRun"
cp "$HERE/$ID.desktop" "$APP/$ID.desktop"
cp "$APP/share/icons/hicolor/256x256/apps/$ID.png" "$APP/$ID.png"
NAME=Switch-$VERSION-linux-$ARCH
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" Switch
ARCH=$ARCH appimagetool --no-appstream "$APP" "$OUT/$NAME.AppImage" > "$OUT/appimagetool.log" 2>&1 \
  || { tail -20 "$OUT/appimagetool.log"; exit 1; }

# 6. Sizes (MB): total folder and its parts.
mb() { du -cm "$@" 2>/dev/null | tail -1 | cut -f1; }
echo "folder $(mb "$APP") MB: Qt $(mb "$APP"/lib/libQt6* "$APP/plugins" "$APP/qml") MB," \
  "Qt ICU $(mb "$APP"/lib/libicu*) MB, Swift $(mb "$APP"/lib/libswift* "$APP"/lib/libFoundation* "$APP"/lib/libdispatch.so "$APP"/lib/libBlocksRuntime.so "$APP/bin/switch-core") MB," \
  "Swift ICU $(mb "$APP"/lib/lib_FoundationICU.so) MB"
ls -l --block-size=M "$OUT/$NAME.tar.gz" "$OUT/$NAME.AppImage" | awk '{print $5, $9}'
