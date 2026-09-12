#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
output_path="$build_path/gui-single-instance-check"

swiftc \
  -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  "$repo_root/packages/gui/Sources/AIManagerGUI/AIManagerSingleInstance.swift" \
  "$repo_root/packages/gui/Tests/SingleInstanceCheck.swift" \
  -o "$output_path"

"$output_path"

[[ "$(/usr/bin/plutil -extract LSMultipleInstancesProhibited raw -o - \
  "$repo_root/packaging/macos/Info.plist")" == "true" ]]
