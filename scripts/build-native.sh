#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'AI Manager requires macOS.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
configuration="${AI_MANAGER_CONFIGURATION:-release}"
version="${AI_MANAGER_VERSION:-0.1.0}"
debug_info_format="${AI_MANAGER_DEBUG_INFO_FORMAT:-}"

if [[ -n "$debug_info_format" ]]; then
  case "$debug_info_format" in
    dwarf|codeview|none) ;;
    *)
      printf 'Unsupported debug information format: %s (expected dwarf, codeview, or none)\n' "$debug_info_format" >&2
      exit 2
      ;;
  esac
fi

export CLANG_MODULE_CACHE_PATH="$build_path/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_path/module-cache/swiftpm"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

case "$configuration" in
  debug|release) ;;
  *)
    printf 'Unsupported Swift build configuration: %s\n' "$configuration" >&2
    exit 2
    ;;
esac

swift_build() {
  if [[ -n "$debug_info_format" ]]; then
    swift build \
      --disable-sandbox \
      --build-path "$build_path" \
      --configuration "$configuration" \
      -debug-info-format "$debug_info_format" \
      "$@"
  else
    swift build \
      --disable-sandbox \
      --build-path "$build_path" \
      --configuration "$configuration" \
      "$@"
  fi
}

swift_build --product AIManager
swift_build --product ai-manager

bin_path="$(swift_build --show-bin-path)"

artifact_path="$build_path/artifacts"
package_path="$build_path/package"
app_path="$package_path/AI Manager.app"

mkdir -p "$artifact_path" "$package_path"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
chmod 0755 "$artifact_path" "$package_path" "$app_path" "$app_path/Contents" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

install -m 0755 "$bin_path/ai-manager" "$artifact_path/ai-manager"
install -m 0755 "$bin_path/AIManager" "$app_path/Contents/MacOS/AIManager"
install -m 0644 \
  "$repo_root/packaging/macos/Info.plist" \
  "$app_path/Contents/Info.plist"
ditto "$repo_root/packages/gui/Resources/Fonts" "$app_path/Contents/Resources/Fonts"

source_revision="unknown"
if source_revision="$(git -C "$repo_root" rev-parse --short=12 HEAD 2>/dev/null)"; then
  :
fi
source_dirty="false"
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]]; then
  source_dirty="true"
fi

/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" \
  "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$version" \
  "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace AIManagerBuildConfiguration -string "$configuration" \
  "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace AIManagerSourceRevision -string "$source_revision" \
  "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace AIManagerSourceDirty -bool "$source_dirty" \
  "$app_path/Contents/Info.plist"

test_root="${AI_MANAGER_TEST_ROOT:-}"
test_executable="${AI_MANAGER_TEST_CODEX_EXECUTABLE:-}"
if [[ -n "$test_root" || -n "$test_executable" ]]; then
  if [[ "$configuration" != "debug" ]]; then
    printf '%s\n' 'AI_MANAGER_TEST_ROOT and AI_MANAGER_TEST_CODEX_EXECUTABLE require a debug build.' >&2
    exit 2
  fi
  if [[ -z "$test_root" || "$test_root" != /* ]]; then
    printf '%s\n' 'AI_MANAGER_TEST_ROOT must be an absolute path for a debug test bundle.' >&2
    exit 2
  fi
  if [[ -n "$test_executable" && "$test_executable" != /* ]]; then
    printf '%s\n' 'AI_MANAGER_TEST_CODEX_EXECUTABLE must be an absolute path for a debug test bundle.' >&2
    exit 2
  fi
  if ! /usr/bin/plutil -extract LSEnvironment xml1 -o - "$app_path/Contents/Info.plist" >/dev/null 2>&1; then
    /usr/bin/plutil -insert LSEnvironment -xml '<dict/>' "$app_path/Contents/Info.plist"
  fi
  /usr/bin/plutil -replace LSEnvironment.AI_MANAGER_ROOT -string "$test_root" \
    "$app_path/Contents/Info.plist"
  if [[ -n "$test_executable" ]]; then
    /usr/bin/plutil -replace LSEnvironment.AI_MANAGER_CODEX_EXECUTABLE -string "$test_executable" \
      "$app_path/Contents/Info.plist"
  fi
fi

signing_identity="${AI_MANAGER_SIGNING_IDENTITY:-}"
if [[ -n "$signing_identity" ]]; then
  /usr/bin/codesign \
    --force \
    --entitlements "$repo_root/packaging/macos/AIManager.entitlements" \
    --sign "$signing_identity" \
    "$app_path"
else
  /usr/bin/codesign \
    --force \
    --entitlements "$repo_root/packaging/macos/AIManager.entitlements" \
    --sign - \
    "$app_path"
fi

/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$app_path"

printf 'Built %s\n' "$app_path"
printf 'Built %s\n' "$artifact_path/ai-manager"
