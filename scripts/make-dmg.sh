#!/usr/bin/env bash
# Usage: scripts/make-dmg.sh <Switch.app> <output.dmg> [--public]
# Builds a drag-to-Applications disk image and checks the app inside it.
set -euo pipefail

fail() { printf 'make-dmg: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 2 ]] || fail "usage: scripts/make-dmg.sh <Switch.app> <output.dmg> [--public]"
app="$1" dmg="$2" public="${3:-}"
[[ -d "$app" && "$(basename "$app")" == Switch.app ]] || fail "expected a Switch.app folder: $app"

stage="$(mktemp -d "${TMPDIR:-/tmp}/switch-dmg.XXXXXX")"
# hdiutil cannot mount on the external data drive (Permission denied); the empty mount point lives in /private/tmp.
mount="$(mktemp -d /private/tmp/switch-dmg-mount.XXXXXX)"
cleanup() {
  hdiutil detach "$mount" >/dev/null 2>&1 || true
  rmdir "$mount" 2>/dev/null || true
  rm -rf "$stage"
}
trap cleanup EXIT

mkdir "$stage/root"
ditto "$app" "$stage/root/Switch.app"
ln -s /Applications "$stage/root/Applications"
rm -f "$dmg"
# On macOS 26, `hdiutil create -srcfolder` fails with "Resource busy"; diskutil works.
diskutil image create from --format UDZO --volumeName Switch "$stage/root" "$dmg" >/dev/null

hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount" "$dmg" >/dev/null
[[ -L "$mount/Applications" && "$(readlink "$mount/Applications")" == /Applications ]] || fail "the image has no Applications link"
codesign --verify --deep --strict "$mount/Switch.app"
if [[ "$public" == --public ]]; then
  spctl --assess --type execute "$mount/Switch.app"
  xcrun stapler validate -q "$mount/Switch.app"
fi
cmp <(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist") \
    <(plutil -extract CFBundleShortVersionString raw -o - "$mount/Switch.app/Contents/Info.plist") >/dev/null \
  || fail "the app version in the image differs"
printf 'Disk image: %s\n' "$dmg"
