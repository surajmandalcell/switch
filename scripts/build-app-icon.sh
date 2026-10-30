#!/usr/bin/env bash
# usage: build-app-icon.sh <output folder>
# The Dock icon: the emergency-stop button (AppIcon.icon/Assets/Button.png, full bleed on the 1024
# canvas) on a cream tile, warm stone in the Dark icon style. Writes AppIcon.car, the Icon Composer
# source compiled for macOS 26 and later, which draw it at the full Dock size; from an .icns alone
# they shrink the icon into a gray tile. Also writes AppIconLight.png, AppIconDark.png, and
# AppIcon.png on the Apple grid (an 824 px squircle at 100 px): the Dock image the app sets while
# its own appearance setting differs from the system. Needs rsvg-convert and Xcode 26 or later.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resources="$repo_root/packages/mac-gui/Resources"
out="$1"
command -v rsvg-convert >/dev/null
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$resources/AppIcon.icon/Assets/Button.png" "$work/Button.png"
tile_path="$(cat "$resources/AppIconTile.path")"

# The colors match the fill and its dark specialization in AppIcon.icon/icon.json.
tile_png() {
  cat > "$work/tile.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="fill" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="$1"/>
      <stop offset="1" stop-color="$2"/>
    </linearGradient>
    <clipPath id="tile"><path d="$tile_path"/></clipPath>
    <filter id="tile-shadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="10" stdDeviation="5" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
    <filter id="art-shadow" x="-10%" y="-10%" width="120%" height="130%">
      <feDropShadow dx="0" dy="12" stdDeviation="12" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
  </defs>
  <path d="$tile_path" fill="url(#fill)" filter="url(#tile-shadow)"/>
  <g clip-path="url(#tile)">
    <image x="100" y="100" width="824" height="824" xlink:href="Button.png" filter="url(#art-shadow)"/>
  </g>
  <path d="$tile_path" fill="none" stroke="#000000" stroke-opacity="0.07" stroke-width="2"/>
</svg>
SVG
  rsvg-convert --width 1024 --height 1024 "$work/tile.svg" --output "$3"
}
tile_png '#F7F4EE' '#DFDBD2' "$out/AppIconLight.png"
tile_png '#6B655C' '#48443E' "$out/AppIconDark.png"
cp "$out/AppIconLight.png" "$out/AppIcon.png"

# actool names the icon in the catalog after the .icon folder, which is the CFBundleIconName.
cp -R "$resources/AppIcon.icon" "$work/AppIcon.icon"
mkdir "$work/car"
xcrun actool "$work/AppIcon.icon" --compile "$work/car" \
  --output-format human-readable-text --errors --warnings \
  --output-partial-info-plist "$work/partial.plist" --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en --target-device mac \
  --minimum-deployment-target 14.0 --platform macosx >/dev/null
cp "$work/car/Assets.car" "$out/AppIcon.car"
