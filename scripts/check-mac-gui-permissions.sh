#!/usr/bin/env bash
# Every System Settings opening and privacy ask in the Mac app goes through SamPermissions.
# A raw x-apple.systempreferences URL or openSystemSettingsLoginItems() opens Settings with no guide panel,
# and a direct macOS ask (AX, Screen Recording, Input Monitoring, camera or microphone, location, Apple Events)
# skips SamPermissions, so a Deny is not remembered. Only Permissions.swift may talk to macOS about these.
# Usage: check-mac-gui-permissions.sh [folder, default packages/mac-gui/Sources]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="${1:-$repo_root/packages/mac-gui/Sources}"
pattern='x-apple\.systempreferences|openSystemSettingsLoginItems|AXIsProcessTrustedWithOptions|CGRequestScreenCaptureAccess|IOHIDRequestAccess|AVCaptureDevice\.requestAccess|requestWhenInUseAuthorization|requestAlwaysAuthorization|AEDeterminePermissionToAutomateTarget'

if hits="$(rg -n --glob '*.swift' --glob '!Permissions.swift' "$pattern" "$sources")"; then
  printf '%s\n' "$hits" >&2
  printf '%s\n' 'MAC_GUI_PERMISSIONS_FAIL: open Settings with SystemSettingsGuide.open(.notifications or .loginItems),' \
    'which calls SamPermissions.shared.guide(_:from:) in Permissions.swift; ask for a privacy permission with' \
    'SamPermissions.shared.request(_:confirm:) there, never with the macOS call directly.' >&2
  exit 1
fi
