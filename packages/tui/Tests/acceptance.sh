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

"$binary" providers --json \
  | jq -e '
      map(.id) == ["codex", "claude-code", "gemini-cli", "antigravity-cli"]
      and .[0].displayName == "Codex CLI"
      and .[0].availability == "enabled"
      and (.[1:] | all(.availability == "disabled"))
    ' >/dev/null
if "$binary" add claude-code --json >"$test_root/disabled-provider.json" 2>"$test_root/disabled-provider.log"; then
  printf '%s\n' 'Expected a disabled provider to remain unavailable.' >&2
  exit 1
fi
rg -F 'Claude Code account setup is not available yet.' "$test_root/disabled-provider.log" >/dev/null
"$binary" help >"$test_root/help.log"
rg -F 'ai-manager add [codex]' "$test_root/help.log" >/dev/null
rg -F 'ai-manager remove <account-uuid>' "$test_root/help.log" >/dev/null
rg -F 'Only Codex CLI is available in this release.' "$test_root/help.log" >/dev/null
rg -F 'use status to recover their IDs' "$test_root/help.log" >/dev/null

printf '\033[B\033[A\033' | AI_MANAGER_TUI_KEYS=always \
  AI_MANAGER_TUI_STYLE=always AI_MANAGER_TUI_SPINNER=always \
  "$binary" interactive >"$test_root/tui-native.log"
rg -F 'Loading accounts…' "$test_root/tui-native.log" >/dev/null
grep -F "$(printf '\033[2K')" "$test_root/tui-native.log" >/dev/null
grep -F "$(printf '\033[2m')" "$test_root/tui-native.log" >/dev/null
grep -F "$(printf '\033[7m')" "$test_root/tui-native.log" >/dev/null
if grep -F "$(printf '\033[38;2;')" "$test_root/tui-native.log" >/dev/null \
  || grep -F "$(printf '\033[48;2;')" "$test_root/tui-native.log" >/dev/null; then
  printf '%s\n' 'Terminal UI unexpectedly forced RGB colors.' >&2
  exit 1
fi
rg -F 'No saved accounts' "$test_root/tui-native.log" >/dev/null
rg -F '↑↓ move   →/Enter select   Esc quit' "$test_root/tui-native.log" >/dev/null

printf '\r\033[B\033[A\033\033' | AI_MANAGER_TUI_KEYS=always \
  AI_MANAGER_TUI_STYLE=always "$binary" interactive >"$test_root/tui-choice.log"
rg -F 'Provider: ←' "$test_root/tui-choice.log" >/dev/null
rg -F '2/4' "$test_root/tui-choice.log" >/dev/null
rg -F 'Account login cancelled.' "$test_root/tui-choice.log" >/dev/null
if rg -F 'Provider number:' "$test_root/tui-choice.log" >/dev/null; then
  printf '%s\n' 'Attached terminal prompt fell back to number entry.' >&2
  exit 1
fi

if "$binary" refresh --json >"$test_root/unconfirmed-refresh.json" 2>"$test_root/unconfirmed-refresh.log"; then
  printf '%s\n' 'Expected empty-registry refresh to require confirmation.' >&2
  exit 1
fi
rg -F 'repeat with --yes' "$test_root/unconfirmed-refresh.log" >/dev/null
"$binary" refresh --yes --json \
  | jq -e '.status.accounts == [] and .pendingLoginSessions == []' >/dev/null

login_start="$test_root/login-start.json"
"$binary" start-login codex --yes --json >"$login_start"
login_id="$(jq -r '.session.id' "$login_start")"
jq -e --arg root "$fixture" '
    .session.providerID == "codex"
    and .stagingHome == ("file://" + $root + "/application-support/account-login/" + .session.id + "/home/")
    and .checkCommand == ("ai-manager check-login " + .session.id + " --yes")
    and .cancelCommand == ("ai-manager cancel-login " + .session.id + " --yes")
    and (keys | sort) == ["cancelCommand", "checkCommand", "session", "stagingHome"]
  ' "$login_start" >/dev/null
if rg -i 'access.token|refresh.token|openai.api.key|codex.access.token' "$login_start" >/dev/null; then
  printf '%s\n' 'Login output exposed authentication or inherited environment names.' >&2
  exit 1
fi
"$binary" status --json \
  | jq -e --arg id "$login_id" '
      (.pendingLoginSessions | map(.id) | index($id)) != null
      and .accounts == []
    ' >/dev/null
"$binary" status >"$test_root/pending-status.log"
rg -F "Pending Codex CLI login: $login_id" "$test_root/pending-status.log" >/dev/null
rg -F "Check: ai-manager check-login $login_id --yes" "$test_root/pending-status.log" >/dev/null
rg -F "Cancel: ai-manager cancel-login $login_id --yes" "$test_root/pending-status.log" >/dev/null
"$binary" check-login "$login_id" --yes --json \
  | jq -e '.state == "waitingForLogin" and .account == null' >/dev/null
login_home="$fixture/application-support/account-login/$login_id/home"
cp "$fixture/source-two/auth.json" "$login_home/auth.json"
chmod 600 "$login_home/auth.json"
if ! "$binary" check-login "$login_id" --yes --json >"$test_root/login-check.json" 2>"$test_root/login-check.log"; then
  cat "$test_root/login-check.log" >&2
  exit 1
fi
jq -e '.state == "completed" and .account.identity.accountID == "account-two"' "$test_root/login-check.json" >/dev/null
"$binary" status --json \
  | jq -e --arg id "$login_id" '(.pendingLoginSessions | map(.id) | index($id)) == null' >/dev/null
if rg -i 'access.token|refresh.token|synthetic\.' "$test_root/login-check.json" >/dev/null; then
  printf '%s\n' 'Completed login output exposed authentication content.' >&2
  exit 1
fi

cancel_start="$test_root/cancel-start.json"
"$binary" add --yes --json >"$cancel_start"
cancel_id="$(jq -r '.session.id' "$cancel_start")"
"$binary" cancel-login "$cancel_id" --yes --json \
  | jq -e --arg id "$cancel_id" '.sessionID == $id and .state == "cancelled"' >/dev/null
[[ -d "$fixture/application-support/account-login/$cancel_id/home" ]]
jq -e '.retiredAt != null' "$fixture/application-support/account-login/$cancel_id/session.json" >/dev/null
"$binary" status --json \
  | jq -e --arg id "$cancel_id" '(.pendingLoginSessions | map(.id) | index($id)) == null' >/dev/null
if "$binary" check-login "$cancel_id" --yes --json >"$test_root/retired-check.json" 2>"$test_root/retired-check.log"; then
  printf '%s\n' 'Retired login unexpectedly allowed another check.' >&2
  exit 1
fi
printf '%s\n' 'CLI resumed login and cancellation passed.'

adopt_fixture="$test_root/auto-adopt-fixture"
swift "$(dirname "$0")/FixtureGenerator.swift" "$adopt_fixture" >/dev/null
cp "$adopt_fixture/source-one/auth.json" "$adopt_fixture/default-home/auth.json"
chmod 600 "$adopt_fixture/default-home/auth.json"
if ! AI_MANAGER_ROOT="$adopt_fixture" \
  AI_MANAGER_CODEX_EXECUTABLE="$adopt_fixture/fake-codex" \
  "$binary" status --json >"$test_root/auto-adopt-status.json" 2>"$test_root/auto-adopt-status.log"; then
  skip_if_native_writer_unknown "$test_root/auto-adopt-status.log" || true
  cat "$test_root/auto-adopt-status.log" >&2
  exit 1
fi
jq -e '
    (.accounts | length) == 1
    and .accounts[0].identity.accountID == "account-one"
    and .defaultAccountID == .accounts[0].id
    and .pendingLoginSessions == []
  ' "$test_root/auto-adopt-status.json" >/dev/null
adopted_credential="$(jq -r '.accounts[0].credentialFile | sub("^file://"; "")' "$test_root/auto-adopt-status.json")"
cmp "$adopt_fixture/source-one/auth.json" "$adopt_fixture/default-home/auth.json"
cmp "$adopt_fixture/default-home/auth.json" "$adopted_credential"

"$binary" discover "$fixture/source-one" --json \
  | jq -e '[.[] | select(.identity.workspaceID == "workspace-a")] | length == 1' >/dev/null

interactive_result="$test_root/interactive-result.log"
printf 'm\n%s\n2\nk\nn\nn\nq\n' "$fixture/source-one" | "$binary" interactive >"$interactive_result"
rg -F 'Advanced import' "$interactive_result" >/dev/null
rg -F '↑↓ move   →/Enter select   Esc quit' "$interactive_result" >/dev/null
rg -F 'Reviewed linked setting rules:' "$interactive_result" >/dev/null
rg -e 'Target: .*/ai-manager-fixture/external-rules$' "$interactive_result" >/dev/null
rg -e 'Size: [1-9][0-9]* bytes' "$interactive_result" >/dev/null
rg -e 'Fingerprint: [0-9a-f]{64}' "$interactive_result" >/dev/null
rg -F 'Use this imported linked setting? [y/N]' "$interactive_result" >/dev/null
rg -F 'Import cancelled.' "$interactive_result" >/dev/null

auth_result="$test_root/auth-result.json"
auth_error="$test_root/auth-error.log"
if ! "$binary" advanced-import "$fixture/source-two" --mode auth-only --yes --json >"$auth_result" 2>"$auth_error"; then
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

printf '\033[H\r\033[B\033[B\r\033[D\033' | AI_MANAGER_TUI_KEYS=always \
  AI_MANAGER_TUI_PERCENTAGE=left AI_MANAGER_TUI_STYLE=always \
  "$binary" interactive >"$test_root/interactive-usage.log"
grep -F "$(printf '\033[7m')" "$test_root/interactive-usage.log" >/dev/null
grep -F "$(printf '\033[1m')" "$test_root/interactive-usage.log" >/dev/null
rg -F '75% session left' "$test_root/interactive-usage.log" >/dev/null
rg -F 'session left : 75%' "$test_root/interactive-usage.log" >/dev/null
rg -F 'Token statistics' "$test_root/interactive-usage.log" >/dev/null
rg -e 'Today.*Yesterday.*Weekly.*Monthly.*Yearly' "$test_root/interactive-usage.log" >/dev/null
rg -F 'today      : 1,200 tokens' "$test_root/interactive-usage.log" >/dev/null
printf '\033' | AI_MANAGER_TUI_KEYS=always AI_MANAGER_TUI_PERCENTAGE=used \
  "$binary" interactive >"$test_root/interactive-usage-used.log"
rg -F '25% session used' "$test_root/interactive-usage-used.log" >/dev/null

"$binary" status --json \
  | jq -e --argjson expected "$expected_accounts" '(.accounts | length == $expected) and (.accounts | all(has("credentialDigest") | not))' >/dev/null
verification_status=0
"$binary" verify "$account_id" --json \
  >"$test_root/verification.json" 2>"$test_root/verification.log" || verification_status=$?
if [[ "$verification_status" -ne 0 ]]; then
  cat "$test_root/verification.log" >&2
  printf 'Verification command exited with status %s.\n' "$verification_status" >&2
  exit 1
fi
if ! jq -e '.state == "verifiedWithCodex"' "$test_root/verification.json" >/dev/null; then
  cat "$test_root/verification.json" >&2
  exit 1
fi
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
printf '\033[H\r\033[B\r\033[D\033' | AI_MANAGER_TUI_KEYS=always \
  "$binary" interactive >"$interactive_open_result"
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

if "$binary" remove "$account_id" --json >"$test_root/unconfirmed-remove.json" 2>"$test_root/unconfirmed-remove.log"; then
  printf '%s\n' 'Expected account removal to require confirmation.' >&2
  exit 1
fi
rg -F 'repeat with --yes' "$test_root/unconfirmed-remove.log" >/dev/null
"$binary" remove "$account_id" --yes --json \
  | jq -e --arg id "$account_id" '
      .accountID == $id
      and .replacementDefaultAccountID == null
      and .removedManagedHome
      and .removedCredential
    ' >/dev/null
"$binary" status --json \
  | jq -e --arg id "$account_id" '(.accounts | all(.id != $id))' >/dev/null

human_remove_import="$test_root/human-remove-import.json"
"$binary" advanced-import "$fixture/source-one" --mode auth-only --yes --json >"$human_remove_import"
human_remove_id="$(jq -r '.account.id' "$human_remove_import")"
"$binary" delete-account "$human_remove_id" --yes >"$test_root/human-remove.log"
rg -F "Removed account $human_remove_id from Switch." "$test_root/human-remove.log" >/dev/null

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
printf '\033[F\033[A\r\r\033' | AI_MANAGER_TUI_KEYS=always \
  "$binary" interactive >"$recovery_result"
skip_if_native_writer_unknown "$recovery_result" || true
rg -Fi "Recovery conflict $interactive_recovery_id (import)" "$recovery_result" >/dev/null
rg -F 'Recovery: ←' "$recovery_result" >/dev/null
rg -F 'Keep current data' "$recovery_result" >/dev/null
rg -F $'\tcompleted\tCurrent files were kept.' "$recovery_result" >/dev/null

printf '%s\n' 'CLI acceptance passed.'
