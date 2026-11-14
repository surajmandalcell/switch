#!/usr/bin/env bash
# Put each Qt shot next to its Mac capture, write a difference image, and print two numbers:
# the share of pixels that differ by more than 3% (AE with fuzz) and the RMSE (0..1).
# usage: compare.sh <qt shots dir> <mac captures dir> <out dir>      (needs ImageMagick 7: magick)
set -euo pipefail
QT=${1:?qt shots dir}
MAC=${2:?mac captures dir}
OUT=${3:?out dir}
mkdir -p "$OUT"

pair() {   # <qt png> <mac png> <name>
  local a=$1 b=$2 n=$3
  [ -f "$a" ] && [ -f "$b" ] || { echo "$n: missing $( [ -f "$a" ] || echo "$a" ) $( [ -f "$b" ] || echo "$b" )"; return; }
  # Same canvas: the Mac capture's size, the Qt shot flattened on white (window corners are transparent).
  local size; size=$(magick identify -format '%wx%h' "$b")
  magick "$a" -background white -flatten -gravity northwest -extent "$size" "$OUT/$n-qt.png"
  magick "$b" -background white -flatten "$OUT/$n-mac.png"
  magick "$OUT/$n-qt.png" "$OUT/$n-mac.png" +append "$OUT/$n-side.png"
  local ae rmse total
  ae=$(magick compare -metric AE -fuzz 3% "$OUT/$n-qt.png" "$OUT/$n-mac.png" "$OUT/$n-diff.png" 2>&1 >/dev/null | awk '{print $1}' || true)
  rmse=$(magick compare -metric RMSE "$OUT/$n-qt.png" "$OUT/$n-mac.png" null: 2>&1 >/dev/null | sed -E 's/.*\(([0-9.e-]+)\).*/\1/' || true)
  total=$(magick identify -format '%[fx:w*h]' "$b")
  printf '%-28s differing pixels %6.2f%%  rmse %s\n' "$n" "$(echo "$ae $total" | awk '{printf "%.4f", 100*$1/$2}')" "$rmse"
}

pair "$QT/compare/settings-light@1x.png" "$MAC/settings-light-no-update.png" settings-light
pair "$QT/compare/settings-dark@1x.png" "$MAC/settings-dark-no-update.png" settings-dark
pair "$QT/compare/update/settings-light@1x.png" "$MAC/settings-light-update.png" settings-light-update
pair "$QT/compare/update/settings-dark@1x.png" "$MAC/settings-dark-update.png" settings-dark-update
