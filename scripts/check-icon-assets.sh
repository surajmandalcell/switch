#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icons="$repo_root/packages/mac-gui/Resources/Icons"
build_root="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}/icon-contract"
expected="$build_root/expected"
actual="$build_root/actual"
iconset="$build_root/AppIcon.iconset"

command -v rsvg-convert >/dev/null
command -v iconutil >/dev/null
command -v xmllint >/dev/null
command -v rg >/dev/null

rm -rf "$build_root"
mkdir -p "$expected" "$actual" "$iconset"

for svg in \
  AppIcon.svg AppIconLight.svg AppIconDark.svg ManagerMark.svg \
  SwitchMarkMenubar.svg SwitchMarkPixelTrace.svg \
  ProviderClaudeCode.svg ProviderGeminiCLI.svg
do
  xmllint --noout "$icons/$svg"
done

for asset in \
  ProviderCodex.png ProviderClaudeCode.svg ProviderGeminiCLI.svg ProviderAntigravityCLI.png
do
  test -s "$icons/$asset"
done

[[ "$(shasum -a 256 "$icons/ProviderCodex.png" | awk '{print $1}')" == \
  "6025a4347a8eaed17e31eaebf7834e33ec4af26cc7f59be586ac59ba5157fa1c" ]]
[[ "$(shasum -a 256 "$icons/ProviderClaudeCode.svg" | awk '{print $1}')" == \
  "6d53db4be375e899c937c26cf16684a80d6e869b1928d72b37748bef2560e219" ]]
[[ "$(shasum -a 256 "$icons/ProviderGeminiCLI.svg" | awk '{print $1}')" == \
  "f56df33f86dc0c0257da337c63bf7ad68c0a1b27b796ec707e147984351bccb3" ]]
[[ "$(shasum -a 256 "$icons/ProviderAntigravityCLI.png" | awk '{print $1}')" == \
  "e0cd08ccd10cd8d08ccf0ba449823ee88495825c0841619618100d3ab089f51e" ]]

if rg -i -q '<script|onload=|xlink:href="https?://' \
  "$icons/ProviderClaudeCode.svg" "$icons/ProviderGeminiCLI.svg"
then
  printf '%s\n' 'Provider SVG contains executable or remotely loaded content.' >&2
  exit 1
fi

if rg -q 'SwitchMarkBalanced|balanced-mark|optical version' \
  "$icons" "$repo_root/scripts/build-icons.sh"
then
  printf '%s\n' 'Deprecated icon geometry is still referenced.' >&2
  exit 1
fi

for consumer in AppIconLight.svg AppIconDark.svg ManagerMark.svg SwitchMarkMenubar.svg
do
  rg -q 'SwitchMarkPixelTrace\.svg' "$icons/$consumer"
done

expected_trace_sha="bdeec18e308f1587716dbd4f5b0b9adf73ed4fe8bfeed3a8953e08cc8843f252"
actual_trace_sha="$(shasum -a 256 "$icons/SwitchMarkPixelTrace.svg" | awk '{print $1}')"
[[ "$actual_trace_sha" == "$expected_trace_sha" ]]

rsvg-convert --width 1024 --height 1024 "$icons/SwitchMarkPixelTrace.svg" \
  --output "$expected/SwitchMarkPixelTrace.png"
cmp "$expected/SwitchMarkPixelTrace.png" "$icons/SwitchMarkPixelTrace.png"

rsvg-convert --width 800 --height 800 --page-width 1024 --page-height 1024 \
  --left 112 --top 112 "$icons/SwitchMarkPixelTrace.svg" \
  --output "$expected/ManagerMark-1024.png"
rsvg-convert --width 1024 --height 1024 "$icons/ManagerMark.svg" \
  --output "$actual/ManagerMark-1024.png"
cmp "$expected/ManagerMark-1024.png" "$actual/ManagerMark-1024.png"
rsvg-convert --width 256 --height 256 "$icons/ManagerMark.svg" \
  --output "$actual/ManagerMark.png"
cmp "$actual/ManagerMark.png" "$icons/ManagerMark.png"

rsvg-convert --width 832 --height 832 --page-width 1024 --page-height 1024 \
  --left 96 --top 96 "$icons/SwitchMarkPixelTrace.svg" \
  --output "$expected/SwitchMarkMenubar.png"
rsvg-convert --width 1024 --height 1024 "$icons/SwitchMarkMenubar.svg" \
  --output "$actual/SwitchMarkMenubar.png"
cmp "$expected/SwitchMarkMenubar.png" "$actual/SwitchMarkMenubar.png"
cmp "$actual/SwitchMarkMenubar.png" "$icons/SwitchMarkMenubar.png"

for appearance in Light Dark
do
  rg -F -q '<image x="245" y="258" width="520" height="520" xlink:href="SwitchMarkPixelTrace.svg"/>' \
    "$icons/AppIcon${appearance}.svg"
  rg -F -q 'stroke-width="1"' "$icons/AppIcon${appearance}.svg"
  rsvg-convert --width 1024 --height 1024 "$icons/AppIcon${appearance}.svg" \
    --output "$actual/AppIcon${appearance}.png"
  cmp "$actual/AppIcon${appearance}.png" "$icons/AppIcon${appearance}.png"
done
rg -F -q 'stop-color="#f7f7f5"' "$icons/AppIconLight.svg"
rg -F -q 'stop-color="#ecece9"' "$icons/AppIconLight.svg"
rg -F -q 'stop-color="#ddddda"' "$icons/AppIconLight.svg"
rg -F -q 'fill="#222222" mask="url(#pixel-mark-light)"' "$icons/AppIconLight.svg"
rg -F -q 'stop-opacity="0.07"' "$icons/AppIconLight.svg"
rg -F -q 'id="top-sheen-light"' "$icons/AppIconLight.svg"
rg -F -q 'stop-opacity="0.035"' "$icons/AppIconLight.svg"
rg -F -q 'stop-color="#e7e7e4"' "$icons/AppIconDark.svg"
rg -F -q 'stop-color="#d9d9d6"' "$icons/AppIconDark.svg"
rg -F -q 'stop-color="#cbcbc7"' "$icons/AppIconDark.svg"
rg -F -q 'fill="#1b1b1b" mask="url(#pixel-mark-dark)"' "$icons/AppIconDark.svg"
rg -F -q 'stop-opacity="0.05"' "$icons/AppIconDark.svg"
rg -F -q 'id="top-sheen-dark"' "$icons/AppIconDark.svg"
rg -F -q 'stop-opacity="0.028"' "$icons/AppIconDark.svg"
cmp "$icons/AppIconLight.png" "$icons/AppIcon.png"

rsvg-convert --width 18 --height 18 --page-width 22 --page-height 22 --left 2 --top 2 \
  "$icons/SwitchMarkMenubar.svg" --output "$actual/TrayTemplate.png"
rsvg-convert --width 36 --height 36 --page-width 44 --page-height 44 --left 4 --top 4 \
  "$icons/SwitchMarkMenubar.svg" --output "$actual/TrayTemplate@2x.png"
cmp "$actual/TrayTemplate.png" "$icons/TrayTemplate.png"
cmp "$actual/TrayTemplate@2x.png" "$icons/TrayTemplate@2x.png"

for size in 16 32 128 256 512
do
  rsvg-convert --width "$size" --height "$size" "$icons/AppIconLight.svg" \
    --output "$iconset/icon_${size}x${size}.png"
  rsvg-convert --width "$((size * 2))" --height "$((size * 2))" "$icons/AppIconLight.svg" \
    --output "$iconset/icon_${size}x${size}@2x.png"
done
iconutil --convert icns "$iconset" --output "$actual/AppIcon.icns"
cmp "$actual/AppIcon.icns" "$icons/AppIcon.icns"

printf '%s\n' 'Pixel trace icon contract passed.'
