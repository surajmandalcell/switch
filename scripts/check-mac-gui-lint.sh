#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Every run builds in its own folder, so parallel runs never share objects or run state.
lint_root=${AI_MANAGER_BUILD_PATH:-/Volumes/External1TB/data/_custom/orca/workspaces/switch/switch-build}
mkdir -p "$lint_root"
export AI_MANAGER_BUILD_PATH="$(mktemp -d "$lint_root/lint-run.XXXXXX")"
trap 'rm -rf "$AI_MANAGER_BUILD_PATH"' EXIT
export PLAYWRIGHT_BROWSERS_PATH=/Volumes/External1TB/data/_custom/cache/playwright
export CLANG_MODULE_CACHE_PATH="$AI_MANAGER_BUILD_PATH/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$AI_MANAGER_BUILD_PATH/module-cache/swiftpm"
export TMPDIR="$AI_MANAGER_BUILD_PATH/ui-lint-run/tmp"
frontmost() { lsappinfo front; }
front="$(frontmost)"
# Only these two entry points are allowed: prohibited self-check and ordered-out contract export.
if ! rg -q 'setActivationPolicy\(.prohibited\)' "$repo_root/packages/mac-gui/Tests/UILintSelfCheck.swift" ||
   ! rg -q 'controller.window\?.orderOut\(nil\)' "$repo_root/packages/mac-gui/Tests/AcceptanceApp.swift"; then
  printf 'Refusing a window-capable run while frontmost is %s: ordered-out path is missing.\n' "$front" >&2
  exit 3
fi
run_offscreen() {
  local before pid status=0 deadline
  before="$(frontmost)"
  "$@" & pid=$!
  deadline=$((SECONDS + 120))
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$(frontmost)" != "$before" ]]; then
      kill "$pid"; wait "$pid" || true
      printf '%s\n' 'Frontmost app changed during the offscreen check. Stopping.' >&2
      return 3
    fi
    if (( SECONDS >= deadline )); then kill "$pid"; wait "$pid" || true; return 2; fi
    sleep 1
  done
  wait "$pid" || status=$?
  if [[ "$(frontmost)" != "$before" ]]; then
    printf '%s\n' 'Frontmost app changed during the offscreen check. Stopping.' >&2
    return 3
  fi
  return "$status"
}
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$AI_MANAGER_BUILD_PATH/ui-lint-self-check" "$TMPDIR"
flags=(-disable-sandbox -parse-as-library -D AI_MANAGER_PREVIEW -target "$(uname -m)-apple-macos14.0")
swiftc "${flags[@]}" -D UI_LINT_SELF_CHECK "$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/UILint.swift" \
  "$repo_root/packages/mac-gui/Tests/UILintSelfCheck.swift" -o "$AI_MANAGER_BUILD_PATH/ui-lint-self-check/check"
mkdir -p "$AI_MANAGER_BUILD_PATH/ui-lint-run/home" "$AI_MANAGER_BUILD_PATH/ui-lint-run/tmp"
run_offscreen env HOME="$AI_MANAGER_BUILD_PATH/ui-lint-run/home" CFFIXED_USER_HOME="$AI_MANAGER_BUILD_PATH/ui-lint-run/home" \
  TMPDIR="$AI_MANAGER_BUILD_PATH/ui-lint-run/tmp" "$AI_MANAGER_BUILD_PATH/ui-lint-self-check/check" "$AI_MANAGER_BUILD_PATH/ui-lint-self-check"
bad_status=0
bad="$(node "$repo_root/packages/mac-gui/ui-lint/mirror.mjs" "$AI_MANAGER_BUILD_PATH/ui-lint-self-check/BAD.json")" || bad_status=$?
printf '%s\n' "$bad"
if [[ "$bad_status" != 1 ]] || ! printf '%s\n' "$bad" | rg -q '^layout-alignment ' ||
   printf '%s\n' "$bad" | rg '^[-a-z]+ \|' | rg -q -v '^layout-alignment '; then
  printf '%s\n' 'SELF_CHECK_FAIL: BAD must fail with layout-alignment only.' >&2; exit 2
fi
uneven_status=0
uneven="$(node "$repo_root/packages/mac-gui/ui-lint/mirror.mjs" "$AI_MANAGER_BUILD_PATH/ui-lint-self-check/UNEVEN.json")" || uneven_status=$?
printf '%s\n' "$uneven"
if [[ "$uneven_status" != 1 ]] || ! printf '%s\n' "$uneven" | rg -q '^card-inset ' ||
   printf '%s\n' "$uneven" | rg '^[-a-z]+ \|' | rg -q -v '^card-inset '; then
  printf '%s\n' 'SELF_CHECK_FAIL: UNEVEN must fail with card-inset only.' >&2; exit 2
fi
node "$repo_root/packages/mac-gui/ui-lint/mirror.mjs" "$AI_MANAGER_BUILD_PATH/ui-lint-self-check/GOOD.json"
printf '%s\n' 'SELF_CHECK_PASS: BAD catches inset mismatch; UNEVEN catches card padding; GOOD passes.'

products="$AI_MANAGER_BUILD_PATH/ui-lint-core"
mkdir -p "$products"
core_sources=()
while IFS= read -r source; do core_sources+=("$source"); done < <(rg --files "$repo_root/packages/core/Sources/AIManagerCore" -g '*.swift' | sort)
# macOS Core uses only platform libraries. Compile it directly, like the existing swiftc harnesses.
swiftc -disable-sandbox -parse-as-library -emit-library -static -emit-module -module-name AIManagerCore \
  -target "$(uname -m)-apple-macos14.0" -lsqlite3 \
  -Xcc "-fmodule-map-file=$repo_root/packages/core/Sources/CSQLite/module.modulemap" \
  "${core_sources[@]}" -emit-module-path "$products/AIManagerCore.swiftmodule" -o "$products/libAIManagerCore.a"
sources=()
for source in "$repo_root"/packages/mac-gui/Sources/AIManagerMacGUI/*.swift; do
  [[ "$(basename "$source")" == AIManagerApp.swift ]] || sources+=("$source")
done
flags+=(-I "$products" -L "$products" -lAIManagerCore -lsqlite3
  -Xcc "-fmodule-map-file=$repo_root/packages/core/Sources/CSQLite/module.modulemap")

run_root="$AI_MANAGER_BUILD_PATH/ui-lint-run"
mkdir -p "$run_root/home" "$run_root/codex" "$run_root/claude" "$run_root/grok" "$run_root/manager" "$run_root/tmp" "$run_root/artifacts"
app="$run_root/Switch Lint.app"
mkdir -p "$app/Contents/MacOS"
swiftc "${flags[@]}" "${sources[@]}" "$repo_root/packages/mac-gui/Tests/NativeUIContract.swift" \
  "$repo_root/packages/mac-gui/Tests/MenuBarContract.swift" "$repo_root/packages/mac-gui/Tests/ConversationsCheck.swift" \
  "$repo_root/packages/mac-gui/Tests/AcceptanceApp.swift" \
  -o "$app/Contents/MacOS/check"
install -m 0644 "$repo_root/packaging/macos/Info.plist" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string check "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string com.mandalsuraj.switch.ui-lint "$app/Contents/Info.plist"
status=0
for appearance in light dark; do
  for page in overview accounts conversations maintenance cleanup settings; do
    args=()
    case "$page" in accounts) args=(--accounts);; conversations) args=(--history);; maintenance) args=(--backup);; cleanup) args=(--cleanup);; settings) args=(--settings);; esac
    run_offscreen env HOME="$run_root/home" CFFIXED_USER_HOME="$run_root/home" \
      CODEX_HOME="$run_root/codex" CLAUDE_CONFIG_DIR="$run_root/claude" GROK_HOME="$run_root/grok" \
      AI_MANAGER_ROOT="$run_root/manager" AI_MANAGER_ORCA_ACCOUNTS_ROOT="$run_root/manager/orca-accounts" \
      AI_MANAGER_CODEX_EXECUTABLE=/usr/bin/false AI_MANAGER_ACCEPTANCE_ARTIFACTS="$run_root/artifacts" \
      TMPDIR="$run_root/tmp" "$app/Contents/MacOS/check" --contract-only --snapshot-only --ui-lint "--persisted-$appearance" "${args[@]+"${args[@]}"}"
    result=0
    node "$repo_root/packages/mac-gui/ui-lint/mirror.mjs" "$run_root/artifacts/ui-lint-$page-$appearance.json" || result=$?
    if (( result > status )); then status=$result; fi
  done
done
exit "$status"
