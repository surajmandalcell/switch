#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'AI Manager GUI acceptance requires macOS.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
output_path="$build_path/gui-acceptance"
preview="${AI_MANAGER_GUI_PREVIEW:-0}"
app_name='AI Manager GUI Acceptance'
bundle_id='com.mandalsuraj.ai-manager.gui-acceptance'
case "$preview" in
  0) ;;
  1) app_name='AI Manager Preview'; bundle_id='com.mandalsuraj.ai-manager.preview' ;;
  *) printf '%s\n' 'AI_MANAGER_GUI_PREVIEW must be 0 or 1.' >&2; exit 2 ;;
esac
app_path="$output_path/$app_name.app"
appearance="${AI_MANAGER_GUI_APPEARANCE:-system}"
narrow="${AI_MANAGER_GUI_NARROW:-0}"
seeded="${AI_MANAGER_GUI_SEEDED:-0}"
if [[ "$preview" == "1" ]]; then seeded=1; fi
gui_sources=()

case "$appearance" in
  system|light|dark) ;;
  *) printf 'Unsupported GUI appearance: %s (expected system, light, or dark)\n' "$appearance" >&2; exit 2 ;;
esac
case "$narrow:$seeded" in
  0:0|0:1|1:0|1:1) ;;
  *) printf '%s\n' 'AI_MANAGER_GUI_NARROW and AI_MANAGER_GUI_SEEDED must be 0 or 1.' >&2; exit 2 ;;
esac

for source in "$repo_root"/packages/gui/Sources/AIManagerGUI/*.swift; do
  if [[ "$(basename "$source")" != "AIManagerApp.swift" ]]; then
    gui_sources+=("$source")
  fi
done

export CLANG_MODULE_CACHE_PATH="$build_path/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_path/module-cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$output_path"

swift build \
  --disable-sandbox \
  --build-path "$build_path" \
  --configuration debug \
  --target AIManagerCore
products_path="$(swift build --disable-sandbox --build-path "$build_path" --configuration debug --show-bin-path)"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
chmod 0755 "$app_path" "$app_path/Contents" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

swiftc \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -I "$products_path" \
  -L "$products_path" \
  -lAIManagerCore \
  -lsqlite3 \
  -Xcc "-fmodule-map-file=$repo_root/packages/core/Sources/CSQLite/module.modulemap" \
  "${gui_sources[@]}" \
  "$repo_root/packages/gui/Tests/AcceptanceApp.swift" \
  -o "$app_path/Contents/MacOS/AIManagerGUIAcceptance"

install -m 0644 "$repo_root/packaging/macos/Info.plist" "$app_path/Contents/Info.plist"
ditto "$repo_root/packages/gui/Resources/Fonts" "$app_path/Contents/Resources/Fonts"
/usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$app_name" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string 'AIManagerGUIAcceptance' "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace AIManagerBuildConfiguration -string 'gui-acceptance' "$app_path/Contents/Info.plist"
source_revision="$(git -C "$repo_root" rev-parse --short=12 HEAD)"
source_dirty=false
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]]; then source_dirty=true; fi
/usr/bin/plutil -replace AIManagerSourceRevision -string "$source_revision" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace AIManagerSourceDirty -bool "$source_dirty" "$app_path/Contents/Info.plist"
if [[ "$appearance" != "system" ]]; then
  /usr/bin/plutil -insert AIManagerGUIAppearance -string "$appearance" "$app_path/Contents/Info.plist"
fi
narrow_bool=false
seeded_bool=false
if [[ "$narrow" == "1" ]]; then narrow_bool=true; fi
if [[ "$seeded" == "1" ]]; then seeded_bool=true; fi
/usr/bin/plutil -insert AIManagerGUINarrow -bool "$narrow_bool" "$app_path/Contents/Info.plist"
/usr/bin/plutil -insert AIManagerGUISeeded -bool "$seeded_bool" "$app_path/Contents/Info.plist"
/usr/bin/codesign --force --entitlements "$repo_root/packaging/macos/AIManager.entitlements" \
  --sign "${AI_MANAGER_SIGNING_IDENTITY:--}" "$app_path"

/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app_path"
printf 'Built %s\n' "$app_path"
