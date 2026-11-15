#!/bin/sh
# Adds Switch to this user's app menu from the unpacked tar.gz folder, so the desktop entry's Exec
# resolves (GLib skips entries it cannot run) and the shortcut portal finds com.mandalsuraj.Switch.
# usage: ./install.sh            add the menu entry, icons, and ~/.local/bin/switch-app
#        ./install.sh --remove   take them away again (the app folder stays)
set -eu
ID=com.mandalsuraj.Switch
HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
SIZES="16 24 32 48 64 128 256 512"
if [ "${1:-}" = --remove ]; then
  rm -f "$DATA/applications/$ID.desktop" "$HOME/.local/bin/switch-app"
  for s in $SIZES; do rm -f "$DATA/icons/hicolor/${s}x$s/apps/$ID.png"; done
else
  mkdir -p "$DATA/applications" "$HOME/.local/bin"
  ln -sf "$HERE/bin/switch" "$HOME/.local/bin/switch-app"
  # An absolute Exec works even when ~/.local/bin is not on the session PATH.
  sed "s|^Exec=.*|Exec=\"$HERE/bin/switch\"|" "$HERE/share/applications/$ID.desktop" > "$DATA/applications/$ID.desktop"
  for s in $SIZES; do
    mkdir -p "$DATA/icons/hicolor/${s}x$s/apps"
    cp "$HERE/share/icons/hicolor/${s}x$s/apps/$ID.png" "$DATA/icons/hicolor/${s}x$s/apps/"
  done
fi
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" || true
