#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  printf '%s\n' 'The Linux contract must run on Linux.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/tmp/ai-manager-linux-build}"

for command in file jq ldd sqlite3 swift; do
  command -v "$command" >/dev/null
done

swift package --package-path "$repo_root" dump-package \
  | jq -e '[.products[].name] | index("AIManager") == null and index("AIManagerCore") != null and index("ai-manager") != null' \
  >/dev/null
swift build --package-path "$repo_root" --build-path "$build_path" --target AIManagerCore
swift test --package-path "$repo_root" --build-path "$build_path"
swift build --package-path "$repo_root" --build-path "$build_path" --configuration release --product ai-manager

binary="$(swift build --package-path "$repo_root" --build-path "$build_path" --configuration release --show-bin-path)/ai-manager"
file "$binary" | grep -F ELF >/dev/null
ldd "$binary" | grep -F libsqlite3 >/dev/null
TMPDIR="${TMPDIR:-/tmp}" bash "$repo_root/packages/tui/Tests/acceptance.sh" "$binary"

smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/ai-manager-linux-smoke.XXXXXX")"
trap 'rm -rf "$smoke_root"' EXIT
mkdir -p "$smoke_root/home"
HOME="$smoke_root/home" AI_MANAGER_ROOT="$smoke_root/root" "$binary" status --json \
  | jq -e '.accounts == [] and .pendingRecovery == []' >/dev/null
[[ "$(stat -c %a "$smoke_root/root/application-support")" == 700 ]]
[[ "$(stat -c %a "$smoke_root/root/application-support/manager.lock")" == 600 ]]

printf 'Linux core and CLI acceptance passed.\n'
