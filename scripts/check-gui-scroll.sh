#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
output_path="$build_path/gui-scroll-check"

export CLANG_MODULE_CACHE_PATH="$build_path/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_path/module-cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swiftc \
  -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  "$repo_root/packages/gui/Sources/AIManagerGUI/AIManagerDesign.swift" \
  "$repo_root/packages/gui/Sources/AIManagerGUI/AIManagerBrand.swift" \
  "$repo_root/packages/gui/Tests/NativeScrollCheck.swift" \
  -o "$output_path"

"$output_path"
