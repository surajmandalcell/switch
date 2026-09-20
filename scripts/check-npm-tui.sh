#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/switch-npm-test.XXXXXX")"
trap 'find "$test_root" -depth -delete' EXIT

pack_json="$(npm pack --json --pack-destination "$test_root" "$repo_root")"
printf '%s' "$pack_json" | node -e '
  let input = "";
  process.stdin.on("data", chunk => input += chunk);
  process.stdin.on("end", () => {
    const files = JSON.parse(input)[0].files.map(file => file.path).sort();
    const expected = ["LICENSE", "README.md", "npm/vendor/darwin-arm64/ai-manager", "package.json"];
    if (JSON.stringify(files) !== JSON.stringify(expected)) process.exit(1);
  });
'
tarball="$test_root/$(printf '%s' "$pack_json" | node -e '
  let input = "";
  process.stdin.on("data", chunk => input += chunk);
  process.stdin.on("end", () => process.stdout.write(JSON.parse(input)[0].filename));
')"
[[ -f "$tarball" ]]

npm install --global --prefix "$test_root/global" "$tarball" >/dev/null
installed="$test_root/global/bin/ai-manager"
[[ -x "$installed" ]]
"$installed" help | rg -F 'ai-manager interactive' >/dev/null

mkdir -p "$test_root/source-home" "$test_root/npx-home"
printf 'q\n' | AI_MANAGER_ROOT="$test_root/source-home" "$installed" \
  | rg -F '↑↓ move   →/Enter select   Esc quit' >/dev/null
npm exec --yes --package "$tarball" -- ai-manager help \
  | rg -F 'ai-manager interactive' >/dev/null
printf 'q\n' | AI_MANAGER_ROOT="$test_root/npx-home" \
  npm exec --yes --package "$tarball" -- ai-manager \
  | rg -F 'Discover accounts' >/dev/null

printf '%s\n' 'NPM_TUI_PACKAGE_PASS'
