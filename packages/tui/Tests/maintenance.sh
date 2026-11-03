#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -x "$1" ]]; then
  printf '%s\n' 'Usage: maintenance.sh <ai-manager-binary>' >&2
  exit 64
fi

binary="$1"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/ai-manager-maintenance.XXXXXX")"
trap 'find "$test_root" -depth -delete' EXIT
export HOME="$test_root/home"
export AI_MANAGER_ROOT="$test_root/root"
mkdir -p "$HOME" "$AI_MANAGER_ROOT/grok-home/logs" "$test_root/backups" "$test_root/restored"
printf '%s\n' 'synthetic configuration' >"$AI_MANAGER_ROOT/grok-home/config.toml"
printf '%s\n' 'synthetic old log' >"$AI_MANAGER_ROOT/grok-home/logs/old.log"
touch -t 202001010000 "$AI_MANAGER_ROOT/grok-home/logs/old.log"

expect_failure() {
  if "$@" >"$test_root/unexpected.log" 2>"$test_root/error.log" </dev/null; then
    printf 'Expected failure: %s\n' "$*" >&2
    exit 1
  fi
}

"$binary" cleanup sources --json | jq -e 'any(.[]; .id == "grok-build")' >/dev/null
expect_failure "$binary" cleanup sources extra --json
expect_failure "$binary" cleanup trash grok-build --item --yes --json
expect_failure "$binary" cleanup trash grok-build --unknown --yes --json
"$binary" cleanup samples --json | jq -e 'length == 0' >/dev/null
expect_failure "$binary" cleanup samples --older-than invalid --json
expect_failure "$binary" cleanup remove-samples --sample 1 --yes --json
expect_failure "$binary" cleanup clear-index --json
"$binary" cleanup clear-index --yes --json | jq -e '.cleared == "conversation-index"' >/dev/null
"$binary" cleanup scan grok-build --json >"$test_root/scan.json"
item="$(jq -r '.categories[] | select(.id == "logs") | .items[] | select(.item.path == "logs/old.log") | .id' "$test_root/scan.json")"
[[ "$item" == '0:logs/old.log' ]]
"$binary" cleanup review grok-build --item "$item" --json | jq -e '.count == 1 and .bytes > 0' >/dev/null
expect_failure "$binary" cleanup trash grok-build --item "$item" --json
[[ -f "$AI_MANAGER_ROOT/grok-home/logs/old.log" ]]
expect_failure "$binary" cleanup trash grok-build --item '0:auth.json' --yes --json
"$binary" cleanup trash grok-build --item "$item" --yes --json >"$test_root/batch.json"
batch="$(jq -r '.id' "$test_root/batch.json")"
[[ ! -e "$AI_MANAGER_ROOT/grok-home/logs/old.log" ]]
"$binary" cleanup trash-list grok-build --json | jq -e --arg id "$batch" 'any(.[]; .id == $id)' >/dev/null
"$binary" cleanup restore grok-build "$batch" --yes --json >/dev/null
[[ "$(cat "$AI_MANAGER_ROOT/grok-home/logs/old.log")" == 'synthetic old log' ]]
touch -t 202001010000 "$AI_MANAGER_ROOT/grok-home/logs/old.log"
"$binary" cleanup trash grok-build --item "$item" --yes --json >"$test_root/batch.json"
batch="$(jq -r '.id' "$test_root/batch.json")"
expect_failure "$binary" cleanup purge grok-build "$batch" --json
"$binary" cleanup purge grok-build "$batch" --yes --json >/dev/null
"$binary" cleanup trash-list grok-build --json | jq -e 'length == 0' >/dev/null

expect_failure "$binary" backup configure grok-build --destination "$test_root/backups" --json
"$binary" backup list --json | jq -e 'length == 0' >/dev/null
expect_failure "$binary" backup configure grok-build --destination "$test_root/backups" --keep 0 --yes --json
expect_failure "$binary" backup configure grok-build --destination --yes --json
expect_failure "$binary" backup configure grok-build --destination "$test_root/backups" --keep 1 --keep 2 --yes --json
"$binary" backup configure grok-build --destination "$test_root/backups" --yes --json >"$test_root/sets.json"
set_id="$(jq -r '.[0].id' "$test_root/sets.json")"
jq -e 'length == 1 and .[0].includeLogins == false and .[0].schedule == "off"' "$test_root/sets.json" >/dev/null
"$binary" backup run "$set_id" --yes --json >"$test_root/snapshot.json"
snapshot="$(jq -r '.id' "$test_root/snapshot.json")"
jq -e '.manifest.entries | any(.[]; .path == "config.toml")' "$test_root/snapshot.json" >/dev/null
"$binary" backup history "$set_id" --json | jq -e --arg id "$snapshot" 'any(.[]; .id == $id)' >/dev/null
printf '%s\n' 'changed configuration' >"$AI_MANAGER_ROOT/grok-home/config.toml"
expect_failure "$binary" backup restore "$set_id" "$snapshot" --destination "$AI_MANAGER_ROOT/grok-home" --yes --json
[[ "$(cat "$AI_MANAGER_ROOT/grok-home/config.toml")" == 'changed configuration' ]]
expect_failure "$binary" backup restore "$set_id" "$snapshot" --item '../auth.json' --destination "$test_root/restored" --yes --json
"$binary" backup restore "$set_id" "$snapshot" --destination "$test_root/restored" --yes --json >"$test_root/restored.json"
jq -e '.restored > 0' "$test_root/restored.json" >/dev/null
[[ "$(cat "$test_root/restored/config.toml")" == 'synthetic configuration' ]]
[[ "$(cat "$AI_MANAGER_ROOT/grok-home/config.toml")" == 'changed configuration' ]]
"$binary" backup retire grok-build --yes --json | jq -e '.[0].retired == true and .[0].schedule == "off"' >/dev/null
"$binary" backup history "$set_id" --json | jq -e --arg id "$snapshot" 'any(.[]; .id == $id)' >/dev/null
expect_failure "$binary" backup run "$set_id" --yes --json
"$binary" backup configure grok-build --destination "$test_root/backups" --yes --json | jq -e --arg id "$set_id" 'length == 1 and .[0].id == $id and .[0].retired == false' >/dev/null
"$binary" backup run "$set_id" --yes --json >/dev/null
expect_failure "$binary" backup configure grok-build --destination "$test_root/backups" --include-logins --exclude-logins --yes --json
expect_failure "$binary" backup configure grok-build --destination "$test_root/backups" --prompts-only --full-content --yes --json
"$binary" backup configure grok-build --destination "$test_root/backups" --include-logins --prompts-only --yes --json | jq -e '.[0].includeLogins == true and .[0].promptsOnly == true' >/dev/null
"$binary" backup configure grok-build --destination "$test_root/backups" --keep 7 --yes --json | jq -e '.[0].keep == 7 and .[0].includeLogins == true and .[0].promptsOnly == true' >/dev/null
"$binary" backup configure grok-build --destination "$test_root/backups" --exclude-logins --full-content --yes --json | jq -e '.[0].includeLogins == false and .[0].promptsOnly == false' >/dev/null

printf '%s\n' 'Maintenance CLI acceptance passed.'
