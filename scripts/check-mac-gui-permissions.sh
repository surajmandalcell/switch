#!/usr/bin/env bash
# Every System Settings opening and privacy ask in the Mac app goes through SamPermissions.
# A raw x-apple.systempreferences or Privacy_ URL, or openSystemSettingsLoginItems(), opens Settings with no guide
# panel, and a direct macOS ask (AX, Screen Recording, Input Monitoring, camera or microphone, location, Apple
# Events) skips SamPermissions, so a Deny is not remembered. Only Permissions.swift may talk to macOS about these
# or call SamPermissions. Notification asks (UNUserNotificationCenter) stay where they are; their Fix goes through
# SystemSettingsGuide.open(.notifications).
# Usage: check-mac-gui-permissions.sh [folder, default packages/mac-gui/Sources]
#        check-mac-gui-permissions.sh --self-test

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pattern='x-apple\.systempreferences|Privacy_|openSystemSettingsLoginItems|AXIsProcessTrustedWithOptions|CG(Request|Preflight)ScreenCaptureAccess|IOHID(Request|Check)Access|AVCaptureDevice\.requestAccess|request(WhenInUse|Always)Authorization|AEDeterminePermissionToAutomateTarget|SamPermissions\.shared'

if [[ "${1:-}" == "--self-test" ]]; then
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  mkdir -p "$dir/bad" "$dir/good"
  printf '%s\n' 'func ask() { _ = CGRequestScreenCaptureAccess(); open("x-apple.systempreferences:Privacy_ScreenCapture") }' \
    > "$dir/bad/Feature.swift"
  printf '%s\n' 'func ask() { SamPermissions.shared.guide(.notifications) }' > "$dir/good/Permissions.swift"
  if bash "$0" "$dir/bad" 2>/dev/null; then echo 'FAIL: direct ask outside Permissions.swift passed' >&2; exit 1; fi
  bash "$0" "$dir/good" || { echo 'FAIL: SamPermissions call inside Permissions.swift failed' >&2; exit 1; }
  echo 'check-mac-gui-permissions self-test passed'
  exit 0
fi

sources="${1:-$repo_root/packages/mac-gui/Sources}"
if hits="$(rg -n --glob '*.swift' --glob '!Permissions.swift' "$pattern" "$sources")"; then
  printf '%s\n' "$hits" >&2
  printf '%s\n' 'MAC_GUI_PERMISSIONS_FAIL: open Settings with SystemSettingsGuide.open(.notifications or .loginItems),' \
    'which calls SamPermissions.shared.guide(_:from:) in Permissions.swift; ask for a privacy permission with' \
    'SamPermissions.shared.request(_:confirm:) there, never with the macOS call directly.' >&2
  exit 1
fi
