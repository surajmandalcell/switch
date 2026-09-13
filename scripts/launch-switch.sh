#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"

if [[ "${1:-}" != "--preview" || "$#" -ne 1 ]]; then
  printf '%s\n' 'Usage: scripts/launch-switch.sh --preview' >&2
  exit 2
fi

AI_MANAGER_MAC_GUI_PREVIEW=1 "$repo_root/scripts/build-mac-gui-acceptance.sh"
open "$build_path/preview/Switch.app"
