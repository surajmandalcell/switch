#!/bin/sh
# Rebuilds the website images from the app's icon, screenshots, and brand tiles.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/packages/website/public/assets"
icons="$root/packages/mac-gui/Resources/Icons"
shots="$root/docs/screenshots"
mkdir -p "$out/tools"

magick "$icons/AppIcon.png" -resize 256x256 -quality 90 "$out/icon-256.webp"
magick "$icons/AppIcon.png" -resize 512x512 -quality 88 "$out/icon-512.webp"
magick "$icons/AppIcon.png" -resize 180x180 -strip "$out/apple-touch-icon.png"
magick "$icons/AppIcon.png" -resize 64x64 -strip "$out/favicon.png"
magick "$shots/cover-spaced.png" -resize 1200x630 -background '#F2F2F4' -gravity center -extent 1200x630 -quality 84 "$out/og.jpg"

for name in overview-light overview-dark overview-insights login-swap-light login-swap-dark menubar-light menubar-dark; do
  cwebp -quiet -q 84 -m 6 "$shots/$name.png" -o "$out/$name.webp"
done

# Bakes each brand mark into one rounded tile with transparent corners, so the
# page never needs a backing plate. Transparent corners are filled with the
# tile's own edge colour first; free-floating logos get a white plate.
tile() {
  src=$1 dst=$2 at="p{128,${3:-6}}"
  solid=$(magick "$src" -alpha set -resize 256x256! -format "%[fx:$at.a>=0.9]" info:)
  if [ "$solid" = 1 ]; then
    plate=$(magick "$src" -alpha set -resize 256x256! -format "%[pixel:$at]" info:)
  else
    plate=white
  fi
  magick "$src" -resize 256x256! -background "$plate" -alpha remove -alpha off \
    \( -size 256x256 xc:none -fill white -draw "roundrectangle 0,0 255,255 58,58" \) -alpha off \
    -compose CopyOpacity -composite -resize 128x128 -quality 90 "$dst"
}
for tool in claude-code openai cursor grok-build groq kimi minimax ollama openrouter perplexity \
  poe raycast warp v0 amp devin elevenlabs fireworks jetbrains notion codebuff exa tavily \
  replicate venice litellm deepgram manus qoder chutes t3chat abacus langdock; do
  tile "$icons/ProviderBrand/full-$tool.png" "$out/tools/$tool.webp"
done
tile "$icons/ProviderBrand/full-gitkraken.png" "$out/tools/gitkraken.webp" 40
for tool in antigravity xkiro; do
  tile "$icons/ProviderBrand/$tool.png" "$out/tools/$tool.webp"
done
