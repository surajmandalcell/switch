#!/usr/bin/env bash
# Removes one Mac GUI acceptance preferences domain. The acceptance app's defaults land in the real
# ~/Library/Preferences even with CFFIXED_USER_HOME set, so every gate run removes its own domain.
set -uo pipefail

domain="${1:-}"
case "$domain" in
  com.mandalsuraj.ai-manager.mac-gui-acceptance.?*) ;;
  *) printf 'Refusing to remove preferences domain: %s\n' "$domain" >&2; exit 2 ;;
esac
if [[ "$domain" == */* ]]; then
  printf 'Refusing to remove preferences domain: %s\n' "$domain" >&2
  exit 2
fi
# Through cfprefsd first, so a cached copy is not written back after the file is gone.
/usr/bin/defaults delete "$domain" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$domain.plist"
