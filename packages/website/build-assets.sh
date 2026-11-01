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
magick "$shots/cover.png" -resize 1200x -gravity center -crop 1200x630+0+0 +repage -quality 84 "$out/og.jpg"

for name in overview-light overview-dark overview-insights login-swap-light login-swap-dark menubar-light menubar-dark; do
  cwebp -quiet -q 84 -m 6 "$shots/$name.png" -o "$out/$name.webp"
done

for tool in claude-code openai cursor grok-build groq kimi minimax ollama openrouter perplexity \
  poe raycast warp v0 amp devin elevenlabs fireworks jetbrains notion codebuff exa tavily \
  replicate venice litellm gitkraken deepgram manus qoder chutes t3chat abacus langdock; do
  magick "$icons/ProviderBrand/full-$tool.png" -resize 128x128 -quality 88 "$out/tools/$tool.webp"
done
for tool in antigravity xkiro; do
  magick "$icons/ProviderBrand/$tool.png" -resize 128x128 -quality 88 "$out/tools/$tool.webp"
done
