#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
output_path="$build_path/mac-gui-production-check"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/switch-mac-gui-production.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

export CLANG_MODULE_CACHE_PATH="$build_path/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_path/module-cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift build --disable-sandbox --build-path "$build_path" --configuration debug --product AIManagerCore
products_path="$(swift build --disable-sandbox --build-path "$build_path" --configuration debug --show-bin-path)"

swiftc \
  -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -I "$products_path" \
  -L "$products_path" \
  -lAIManagerCore \
  -lsqlite3 \
  -Xcc "-fmodule-map-file=$repo_root/packages/core/Sources/CSQLite/module.modulemap" \
  "$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/AccountViewModel.swift" \
  "$repo_root/packages/mac-gui/Tests/ProductionAccountViewModelCheck.swift" \
  -o "$output_path"

if LC_ALL=C rg -q 'Switch Demo|/Demo/Sources/|Demo data refreshed|Demo import completed|Show demo error|DemoData|AccountViewModel\.Scenario|AcceptanceApp|AIManagerNativeContract' \
  < <(/usr/bin/strings "$output_path"); then
  printf '%s\n' 'Production Mac GUI check contains Preview-only data.' >&2
  exit 1
fi

mkdir -p "$test_root/home" "$test_root/codex-home" "$test_root/manager" "$test_root/tmp"
HOME="$test_root/home" \
CFFIXED_USER_HOME="$test_root/home" \
CODEX_HOME="$test_root/codex-home" \
AI_MANAGER_ROOT="$test_root/manager" \
TMPDIR="$test_root/tmp" \
  "$output_path"
