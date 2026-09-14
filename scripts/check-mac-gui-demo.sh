#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
output_path="$build_path/mac-gui-demo-check"

export CLANG_MODULE_CACHE_PATH="$build_path/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_path/module-cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift build --disable-sandbox --build-path "$build_path" --configuration debug --product AIManagerCore
products_path="$(swift build --disable-sandbox --build-path "$build_path" --configuration debug --show-bin-path)"

swiftc \
  -parse-as-library \
  -D AI_MANAGER_PREVIEW \
  -target "$(uname -m)-apple-macos14.0" \
  -I "$products_path" \
  -L "$products_path" \
  -lAIManagerCore \
  -lsqlite3 \
  -Xcc "-fmodule-map-file=$repo_root/packages/core/Sources/CSQLite/module.modulemap" \
  "$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/ChatHistoryMonitor.swift" \
  "$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/AccountViewModel.swift" \
  "$repo_root/packages/mac-gui/Tests/MockAccountViewModelCheck.swift" \
  -o "$output_path"

"$output_path"
