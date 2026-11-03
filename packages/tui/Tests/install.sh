#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/switch-cli-install.XXXXXX")"
trap 'find "$test_root" -depth -delete' EXIT

bash "$repo_root/scripts/install-cli.sh" /usr/bin/true "$test_root/bin" >/dev/null
cmp -s /usr/bin/true "$test_root/bin/ai-manager"
[[ "$(readlink "$test_root/bin/switch")" == ai-manager ]]
bash "$repo_root/scripts/install-cli.sh" /usr/bin/false "$test_root/bin" >/dev/null
cmp -s /usr/bin/false "$test_root/bin/ai-manager"

mkdir -p "$test_root/conflict"
cp /usr/bin/true "$test_root/conflict/switch"
if bash "$repo_root/scripts/install-cli.sh" /usr/bin/false "$test_root/conflict" 2>/dev/null; then
  printf '%s\n' 'Installer replaced an unrelated switch command.' >&2
  exit 1
fi
cmp -s /usr/bin/true "$test_root/conflict/switch"
[[ ! -e "$test_root/conflict/ai-manager" ]]

mkdir -p "$test_root/directory/ai-manager"
if bash "$repo_root/scripts/install-cli.sh" /usr/bin/true "$test_root/directory" 2>/dev/null; then
  printf '%s\n' 'Installer replaced a directory.' >&2
  exit 1
fi
[[ -d "$test_root/directory/ai-manager" ]]
printf '%s\n' 'CLI_INSTALL_PASS'
