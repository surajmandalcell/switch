#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"

if [[ "$(uname -s):$(uname -m)" != "Darwin:arm64" ]]; then
  printf '%s\n' '@smc/switch currently packages the Apple Silicon macOS binary.' >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="$build_path/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_path/module-cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift build \
  --package-path "$repo_root" \
  --disable-sandbox \
  --build-path "$build_path" \
  --configuration release \
  --product ai-manager >&2
bin_path="$(swift build \
  --package-path "$repo_root" \
  --disable-sandbox \
  --build-path "$build_path" \
  --configuration release \
  --show-bin-path)"

destination="$repo_root/npm/vendor/darwin-arm64/ai-manager"
mkdir -p "$(dirname "$destination")"
install -m 0755 "$bin_path/ai-manager" "$destination"
codesign --force --sign - "$destination"
codesign --verify --strict "$destination"
"$destination" help >/dev/null
