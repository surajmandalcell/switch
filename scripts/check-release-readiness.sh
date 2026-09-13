#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
public=0
if [[ "${1:-}" == "--public" ]]; then
  public=1
  shift
fi
app_path="${1:-$build_path/package/Switch.app}"
cli_path="${2:-$build_path/artifacts/ai-manager}"

fail() {
  printf 'RELEASE_NOT_READY: %s\n' "$1" >&2
  exit 1
}

test -x "$app_path/Contents/MacOS/AIManager" || fail "app executable is missing"
test -x "$app_path/Contents/Helpers/ai-manager" || fail "bundled account launcher is missing"
test -x "$cli_path" || fail "CLI executable is missing"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist" >/dev/null || fail "Info.plist is invalid"
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$app_path/Contents/Info.plist")" == "Switch" ]] || fail "display name is incorrect"
[[ "$(/usr/bin/plutil -extract LSMultipleInstancesProhibited raw -o - "$app_path/Contents/Info.plist")" == "true" ]] || fail "multiple instances are not prohibited"
[[ "$(/usr/bin/plutil -extract AIManagerSourceDirty raw -o - "$app_path/Contents/Info.plist")" == "false" ]] || fail "package was built from a dirty source tree"
revision="$(/usr/bin/plutil -extract AIManagerSourceRevision raw -o - "$app_path/Contents/Info.plist")" || fail "source revision is missing"
expected_revision="$(git -C "$repo_root" rev-parse --short=12 HEAD)" || fail "source revision cannot be resolved"
[[ "$revision" == "$expected_revision" ]] || fail "package revision $revision does not match source revision $expected_revision"
/usr/bin/file "$app_path/Contents/MacOS/AIManager" | grep -q 'arm64' || fail "app has no verified arm64 slice"
/usr/bin/file "$app_path/Contents/Helpers/ai-manager" | grep -q 'arm64' || fail "bundled account launcher has no verified arm64 slice"
/usr/bin/file "$cli_path" | grep -q 'arm64' || fail "CLI has no verified arm64 slice"
/usr/bin/cmp -s "$app_path/Contents/Helpers/ai-manager" "$cli_path" || fail "bundled account launcher does not match the verified CLI"
/usr/bin/codesign --verify --deep --strict "$app_path" || fail "app signature is invalid"
/usr/bin/codesign --verify --strict "$app_path/Contents/Helpers/ai-manager" || fail "bundled account launcher signature is invalid"
/usr/bin/codesign --verify --strict "$cli_path" || fail "CLI signature is invalid"

if LC_ALL=C rg -q 'Switch Demo|/Demo/Sources/|Demo data refreshed|Demo import completed|Show demo error' \
  < <(/usr/bin/strings "$app_path/Contents/MacOS/AIManager"); then
  fail "production executable contains Preview-only data"
fi

if (( public )); then
  app_signature="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)" || fail "app signature metadata is unavailable"
  cli_signature="$(/usr/bin/codesign -dv --verbose=4 "$cli_path" 2>&1)" || fail "CLI signature metadata is unavailable"
  if ! grep -q '^Authority=Developer ID Application:' <<<"$app_signature"; then
    printf '%s\n' 'PUBLIC_RELEASE_NOT_READY: app lacks a Developer ID Application signature.' >&2
    exit 1
  fi
  grep -q 'flags=0x10000(runtime)' <<<"$app_signature" || fail "app lacks hardened runtime"
  grep -q '^Timestamp=' <<<"$app_signature" || fail "app signature lacks a secure timestamp"
  grep -q '^Authority=Developer ID Application:' <<<"$cli_signature" || fail "CLI lacks a Developer ID Application signature"
  grep -q 'flags=0x10000(runtime)' <<<"$cli_signature" || fail "CLI lacks hardened runtime"
  grep -q '^Timestamp=' <<<"$cli_signature" || fail "CLI signature lacks a secure timestamp"
  /usr/bin/xcrun stapler validate "$app_path" || fail "app has no valid notarization ticket"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$app_path" || fail "Gatekeeper rejected the app"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$cli_path" || fail "Gatekeeper rejected the CLI"
  printf 'PUBLIC_RELEASE_READY %s\n' "$revision"
else
  printf 'LOCAL_RELEASE_READY %s\n' "$revision"
fi
