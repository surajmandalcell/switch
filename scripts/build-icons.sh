#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icons="$repo_root/packages/gui/Resources/Icons"
iconset="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}/icons/AppIcon.iconset"
command -v rsvg-convert >/dev/null
command -v iconutil >/dev/null
rm -rf "$iconset"
mkdir -p "$iconset"

rsvg-convert --width 1024 --height 1024 "$icons/SwitchMarkBalanced.svg" \
  --output "$icons/SwitchMarkBalanced.png"
rsvg-convert --width 1024 --height 1024 "$icons/SwitchMarkMenubar.svg" \
  --output "$icons/SwitchMarkMenubar.png"
rsvg-convert --width 1024 --height 1024 "$icons/AppIconLight.svg" --output "$icons/AppIconLight.png"
rsvg-convert --width 1024 --height 1024 "$icons/AppIconDark.svg" --output "$icons/AppIconDark.png"
cp "$icons/AppIconLight.png" "$icons/AppIcon.png"
rsvg-convert --width 256 --height 256 "$icons/ManagerMark.svg" --output "$icons/ManagerMark.png"
rsvg-convert --width 18 --height 18 --page-width 22 --page-height 22 --left 2 --top 2 \
  "$icons/SwitchMarkMenubar.svg" --output "$icons/TrayTemplate.png"
rsvg-convert --width 36 --height 36 --page-width 44 --page-height 44 --left 4 --top 4 \
  "$icons/SwitchMarkMenubar.svg" --output "$icons/TrayTemplate@2x.png"

for size in 16 32 128 256 512; do
  rsvg-convert --width "$size" --height "$size" "$icons/AppIconLight.svg" \
    --output "$iconset/icon_${size}x${size}.png"
  rsvg-convert --width "$((size * 2))" --height "$((size * 2))" "$icons/AppIconLight.svg" \
    --output "$iconset/icon_${size}x${size}@2x.png"
done
iconutil --convert icns "$iconset" --output "$icons/AppIcon.icns"
printf 'Built Dock, tray, and rail icons.\n'
