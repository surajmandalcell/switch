#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Switch Mac GUI acceptance requires macOS.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
preview="${AI_MANAGER_MAC_GUI_PREVIEW:-0}"
app_name='Switch Mac GUI Acceptance'
bundle_id='com.mandalsuraj.ai-manager.mac-gui-acceptance'
output_path="$build_path/mac-gui-acceptance"
build_kind='mac-gui-acceptance'
case "$preview" in
  0) ;;
  1)
    app_name='Switch'
    bundle_id='com.mandalsuraj.ai-manager.preview'
    output_path="$build_path/preview"
    build_kind='preview'
    ;;
  *) printf '%s\n' 'AI_MANAGER_MAC_GUI_PREVIEW must be 0 or 1.' >&2; exit 2 ;;
esac
app_path="$output_path/$app_name.app"
appearance="${AI_MANAGER_MAC_GUI_APPEARANCE:-system}"
mac_gui_sources=()

case "$appearance" in
  system|light|dark) ;;
  *) printf 'Unsupported Mac GUI appearance: %s (expected system, light, or dark)\n' "$appearance" >&2; exit 2 ;;
esac

for source in "$repo_root"/packages/mac-gui/Sources/AIManagerMacGUI/*.swift; do
  if [[ "$(basename "$source")" != "AIManagerApp.swift" ]]; then
    mac_gui_sources+=("$source")
  fi
done

export CLANG_MODULE_CACHE_PATH="$build_path/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_path/module-cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$output_path"

swift build \
  --disable-sandbox \
  --build-path "$build_path" \
  --configuration debug \
  --product AIManagerCore
products_path="$(swift build --disable-sandbox --build-path "$build_path" --configuration debug --show-bin-path)"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
chmod 0755 "$app_path" "$app_path/Contents" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

swiftc \
  -parse-as-library \
  -D AI_MANAGER_PREVIEW \
  -target "$(uname -m)-apple-macos14.0" \
  -I "$products_path" \
  -L "$products_path" \
  -lAIManagerCore \
  -lsqlite3 \
  -Xcc "-fmodule-map-file=$repo_root/packages/core/Sources/CSQLite/module.modulemap" \
  "${mac_gui_sources[@]}" \
  "$repo_root/packages/mac-gui/Tests/NativeUIContract.swift" \
  "$repo_root/packages/mac-gui/Tests/AcceptanceApp.swift" \
  -o "$app_path/Contents/MacOS/AIManagerMacGUIAcceptance"

if ! LC_ALL=C rg -q '/Demo/Sources/' \
  < <(/usr/bin/strings "$app_path/Contents/MacOS/AIManagerMacGUIAcceptance"); then
  printf '%s\n' 'Preview compiler condition did not include the sample data.' >&2
  exit 1
fi

install -m 0644 "$repo_root/packaging/macos/Info.plist" "$app_path/Contents/Info.plist"
ditto "$repo_root/packages/mac-gui/Resources/Fonts" "$app_path/Contents/Resources/Fonts"
ditto "$repo_root/packages/mac-gui/Resources/Icons" "$app_path/Contents/Resources/Icons"
install -m 0644 "$repo_root/packages/mac-gui/Resources/LICENSE-smctl.txt" \
  "$app_path/Contents/Resources/LICENSE-smctl.txt"
install -m 0644 "$repo_root/packages/mac-gui/Resources/Icons/AppIcon.icns" \
  "$app_path/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$app_name" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string 'AIManagerMacGUIAcceptance' "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace AIManagerBuildConfiguration -string "$build_kind" "$app_path/Contents/Info.plist"
source_revision="$(git -C "$repo_root" rev-parse --short=12 HEAD)"
source_dirty=false
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]]; then source_dirty=true; fi
/usr/bin/plutil -replace AIManagerSourceRevision -string "$source_revision" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace AIManagerSourceDirty -bool "$source_dirty" "$app_path/Contents/Info.plist"
if [[ "$appearance" != "system" ]]; then
  /usr/bin/plutil -insert AIManagerMacGUIAppearance -string "$appearance" "$app_path/Contents/Info.plist"
fi
/usr/bin/codesign --force --entitlements "$repo_root/packaging/macos/AIManager.entitlements" \
  --sign "${AI_MANAGER_SIGNING_IDENTITY:--}" "$app_path"

/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app_path"
printf 'Built %s\n' "$app_path"
