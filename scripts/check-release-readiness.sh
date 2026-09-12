#!/usr/bin/env bash

set -euo pipefail

build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
public=0
if [[ "${1:-}" == "--public" ]]; then
  public=1
  shift
fi
app_path="${1:-$build_path/package/IIA Directeur.app}"
cli_path="${2:-$build_path/artifacts/ai-manager}"

test -x "$app_path/Contents/MacOS/AIManager"
test -x "$cli_path"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist" >/dev/null
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$app_path/Contents/Info.plist")" == "IIA Directeur" ]]
[[ "$(/usr/bin/plutil -extract LSMultipleInstancesProhibited raw -o - "$app_path/Contents/Info.plist")" == "true" ]]
[[ "$(/usr/bin/plutil -extract AIManagerSourceDirty raw -o - "$app_path/Contents/Info.plist")" == "false" ]]
revision="$(/usr/bin/plutil -extract AIManagerSourceRevision raw -o - "$app_path/Contents/Info.plist")"
[[ -n "$revision" && "$revision" != "unknown" ]]
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/bin/codesign --verify --strict "$cli_path"

if (( public )); then
  app_signature="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)"
  cli_signature="$(/usr/bin/codesign -dv --verbose=4 "$cli_path" 2>&1)"
  if ! grep -q '^Authority=Developer ID Application:' <<<"$app_signature"; then
    printf '%s\n' 'PUBLIC_RELEASE_NOT_READY: app lacks a Developer ID Application signature.' >&2
    exit 1
  fi
  grep -q 'flags=0x10000(runtime)' <<<"$app_signature"
  grep -q '^Timestamp=' <<<"$app_signature"
  grep -q '^Authority=Developer ID Application:' <<<"$cli_signature"
  grep -q 'flags=0x10000(runtime)' <<<"$cli_signature"
  grep -q '^Timestamp=' <<<"$cli_signature"
  /usr/bin/xcrun stapler validate "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$cli_path"
  printf 'PUBLIC_RELEASE_READY %s\n' "$revision"
else
  printf 'LOCAL_RELEASE_READY %s\n' "$revision"
fi
