#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 || ! -x "$1" ]]; then
  printf '%s\n' 'Usage: acceptance.sh <ai-manager-binary>' >&2
  exit 64
fi

binary="$1"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/ai-manager-cli-test.XXXXXX")"
fixture="$test_root/ai-manager-fixture"
trap 'find "$test_root" -depth -delete' EXIT

export SWIFT_MODULECACHE_PATH="$test_root/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$test_root/clang-module-cache"
swift "$(dirname "$0")/FixtureGenerator.swift" "$fixture" >/dev/null
fixture="$(cd "$fixture" && pwd -P)"
export AI_MANAGER_ROOT="$fixture"
export AI_MANAGER_CODEX_EXECUTABLE="$fixture/fake-codex"

writer_unknown_message='Error: Could not establish whether the default home is in use.'
skip_if_native_writer_unknown() {
  local log="$1"
  if [[ "$(uname -s)" == "Darwin" ]] && rg -Fx "$writer_unknown_message" "$log" >/dev/null; then
    printf '%s\n' 'CLI mutation acceptance skipped: Codex writer ownership is unknown on this host.'
    exit 0
  fi
  return 1
}

"$binary" discover "$fixture/source-one" --json \
  | jq -e '[.[] | select(.identity.workspaceID == "workspace-a")] | length == 1' >/dev/null

interactive_result="$test_root/interactive-result.log"
printf 'i\n%s\n2\nk\nn\nn\nq\n' "$fixture/source-one" | "$binary" interactive >"$interactive_result"
rg -F 'Reviewed linked setting rules:' "$interactive_result" >/dev/null
rg -e 'Target: .*/ai-manager-fixture/external-rules$' "$interactive_result" >/dev/null
rg -e 'Size: [1-9][0-9]* bytes' "$interactive_result" >/dev/null
rg -e 'Fingerprint: [0-9a-f]{64}' "$interactive_result" >/dev/null
rg -F 'Use this imported linked setting? [y/N]' "$interactive_result" >/dev/null
rg -F 'Import cancelled.' "$interactive_result" >/dev/null

auth_result="$test_root/auth-result.json"
auth_error="$test_root/auth-error.log"
if ! "$binary" import "$fixture/source-two" --mode auth-only --yes --json >"$auth_result" 2>"$auth_error"; then
  skip_if_native_writer_unknown "$auth_error" || true
  cat "$auth_error" >&2
  exit 1
fi
jq -e '.importedChats == 0 and (.unresolved | length) == 0' "$auth_result" >/dev/null
auth_account_id="$(jq -r '.account.id' "$auth_result")"

full_result="$test_root/full-result.json"
"$binary" plan "$fixture/source-one" --mode full --json \
  | jq -e --arg root "$fixture" '
      .credentialDestination == ("file://" + $root + "/.switch/codex/" + .id + ".json")
      and .sharedDestination == ("file://" + $root + "/default-home/")
      and (.conflicts[] | select(.relativePath == "rules") | .externalTarget != null and .externalTargetBytes == null)
    ' >/dev/null
if "$binary" import "$fixture/source-one" --mode full --keep-shared config.toml --use-imported rules --yes --json >"$test_root/unreviewed.json" 2>"$test_root/unreviewed-error.log"; then
  printf '%s\n' 'Expected linked data to require explicit review.' >&2
  exit 1
fi
rg -F -- '--review-external rules' "$test_root/unreviewed-error.log" >/dev/null
"$binary" plan "$fixture/source-one" --mode full --use-imported rules --review-external rules --json \
  | jq -e '.conflicts[] | select(.relativePath == "rules") | .externalTargetBytes > 0 and .reviewedContentFingerprint != null' >/dev/null
if "$binary" import "$fixture/source-one" --mode full --keep-shared config.toml --use-imported rules --review-external rules --yes --json >"$full_result" 2>"$test_root/full-error.log"; then
  printf '%s\n' 'Expected an unresolved import to return a nonzero status.' >&2
  exit 1
fi
if ! jq -e '.account.id != null' "$full_result" >/dev/null 2>&1; then
  skip_if_native_writer_unknown "$test_root/full-error.log" || true
  cat "$test_root/full-error.log" >&2
  exit 1
fi
jq -e '.importedChats == 1 and (.unresolved | length) == 1' "$full_result" >/dev/null
rg -F 'Reviewed linked setting rules:' "$test_root/full-error.log" >/dev/null
rg -F 'Import completed with unresolved items' "$test_root/full-error.log" >/dev/null
account_id="$(jq -r '.account.id' "$full_result")"
expected_accounts=2

"$binary" status --json \
  | jq -e --argjson expected "$expected_accounts" '(.accounts | length == $expected) and (.accounts | all(has("credentialDigest") | not))' >/dev/null
"$binary" verify "$account_id" --json \
  | jq -e '.state == "verifiedLocally"' >/dev/null
if ! "$binary" open "$account_id" -- resume --all 2>"$test_root/open-error.log"; then
  skip_if_native_writer_unknown "$test_root/open-error.log" || true
  cat "$test_root/open-error.log" >&2
  exit 1
fi
saved_auth_path="$("$binary" saved-auth "$account_id")"
[[ "$saved_auth_path" == "$fixture/.switch/codex/$account_id.json" ]]
cmp "$saved_auth_path" "$fixture/default-home/auth.json"
rg -F "$fixture/default-home" "$fixture/launch.log" >/dev/null

interactive_open_result="$test_root/interactive-open.log"
printf 'o\n1\nq\n' | "$binary" interactive >"$interactive_open_result"
skip_if_native_writer_unknown "$interactive_open_result" || true
if rg -F 'Error:' "$interactive_open_result" >/dev/null; then
  cat "$interactive_open_result" >&2
  exit 1
fi
cmp "$("$binary" saved-auth "$auth_account_id")" "$fixture/default-home/auth.json"
[[ "$(wc -l < "$fixture/launch.log" | tr -d ' ')" == 2 ]]

if "$binary" profile "$account_id" >"$test_root/profile.log" 2>&1; then
  printf '%s\n' 'Expected the removed profile command to fail with migration guidance.' >&2
  exit 1
fi
rg -F 'Use saved-auth to print the saved auth file' "$test_root/profile.log" >/dev/null

transactions="$fixture/application-support/transactions"
mkdir -p "$transactions"
direct_recovery_id='11111111-1111-4111-8111-111111111111'
cp "$fixture/recovery-fixtures/$direct_recovery_id.json" "$transactions/$direct_recovery_id.json"
if "$binary" resolve-recovery "$direct_recovery_id" --yes >"$test_root/missing-choice.log" 2>&1; then
  printf '%s\n' 'Expected recovery resolution to require one choice.' >&2
  exit 1
fi
rg -F 'Choose exactly one of --keep-current or --restore-backup.' "$test_root/missing-choice.log" >/dev/null
if "$binary" resolve-recovery "$direct_recovery_id" --keep-current --restore-backup --yes >"$test_root/double-choice.log" 2>&1; then
  printf '%s\n' 'Expected recovery resolution to reject two choices.' >&2
  exit 1
fi
rg -F 'Choose exactly one of --keep-current or --restore-backup.' "$test_root/double-choice.log" >/dev/null
if ! "$binary" resolve-recovery "$direct_recovery_id" --keep-current --yes --json \
  >"$test_root/direct-recovery.json" 2>"$test_root/direct-recovery-error.log"; then
  skip_if_native_writer_unknown "$test_root/direct-recovery-error.log" || true
  cat "$test_root/direct-recovery-error.log" >&2
  exit 1
fi
jq -e --arg id "$direct_recovery_id" \
  '(.operationID | ascii_downcase) == $id and .outcome == "completed"' \
  "$test_root/direct-recovery.json" >/dev/null

interactive_recovery_id='22222222-2222-4222-8222-222222222222'
cp "$fixture/recovery-fixtures/$interactive_recovery_id.json" "$transactions/$interactive_recovery_id.json"
recovery_result="$test_root/interactive-recovery.log"
printf 'r\nk\nq\n' | "$binary" interactive >"$recovery_result"
skip_if_native_writer_unknown "$recovery_result" || true
rg -Fi "Recovery conflict $interactive_recovery_id (import)" "$recovery_result" >/dev/null
rg -F '[k] Keep current data  [b] Restore protected backup  [s] Skip:' "$recovery_result" >/dev/null
rg -F $'\tcompleted\tCurrent files were kept.' "$recovery_result" >/dev/null

printf '%s\n' 'CLI acceptance passed.'
