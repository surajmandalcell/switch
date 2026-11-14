#!/usr/bin/env bash
# Test tool: fills an empty folder with synthetic Overview data (12 Codex usage accounts, 90 days of ledger rows,
# 90 days of Codex transcripts) so a GUI can test charts and the day sheet against the real helper.
# Usage: scripts/seed-synthetic-root.sh <switch-core> <empty folder>
# Then: switch-core serve --root <folder>  (or AI_MANAGER_ROOT=<folder>)
set -euo pipefail
core=${1:?usage: seed-synthetic-root.sh <switch-core> <empty folder>}
root=${2:?usage: seed-synthetic-root.sh <switch-core> <empty folder>}
mkdir -p "$root"
root=$(cd "$root" && pwd -P)
home=$(cd "$HOME" && pwd -P)
case "$root" in
  / | "$home" | "$home"/.* ) echo "seed-synthetic-root: refusing $root: use an empty test folder" >&2; exit 2 ;;
esac
if [ -n "$(ls -A "$root")" ]; then
  echo "seed-synthetic-root: refusing $root: the folder is not empty" >&2
  exit 2
fi
exec "$core" seed-synthetic --root "$root"
