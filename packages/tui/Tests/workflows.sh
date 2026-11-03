#!/usr/bin/env bash
set -euo pipefail

binary="$1"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/switch-workflows.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root"
export AI_MANAGER_ROOT="$test_root"
export AI_MANAGER_DROID_EXECUTABLE="$test_root/fake-droid"
mkdir -p "$test_root/.factory" "$test_root/default-home/sessions" "$test_root/project"
chmod 700 "$test_root/.factory"
printf '%s' 'synthetic-login' > "$test_root/.factory/auth.v2.file"
printf '%s' 'synthetic-key' > "$test_root/.factory/auth.v2.key"
chmod 600 "$test_root/.factory/"auth.v2.*
cat > "$test_root/fake-droid" <<'SH'
#!/bin/sh
if [ "$1" = doctor ]; then
  printf '%s\n' '{"results":[{"id":"auth.verify","status":"pass","detail":"authenticated as d***@example.test via stored login session"}]}'
  exit 0
fi
printf '%s\n' "$@" > "$HOME/droid-arguments"
SH
chmod 700 "$test_root/fake-droid"

"$binary" import-droid --name 'Personal' --yes --json > "$test_root/import.json"
account_id="$(jq -r '.id' "$test_root/import.json")"
"$binary" rename "$account_id" --name 'Work' --yes --json > "$test_root/renamed.json"
jq -e --arg id "$account_id" '.accounts[] | select(.id == $id) | .identity.accountID == "Work"' "$test_root/renamed.json" >/dev/null
if "$binary" rename "$account_id" --name ' ' --yes > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Blank Droid name was accepted.' >&2; exit 1
fi
"$binary" reorder "$account_id" --yes --json > "$test_root/order.json"
if "$binary" reorder "$account_id" "$account_id" --yes > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Duplicate account order was accepted.' >&2; exit 1
fi
for operation in rename reorder submit-login-code; do
  if "$binary" "$operation" "$account_id" --unknown --yes --json > "$test_root/invalid.log" 2>&1; then
    printf '%s\n' "Unknown $operation option was accepted." >&2; exit 1
  fi
  rg -F 'Unknown option' "$test_root/invalid.log" >/dev/null
done
if "$binary" rename "$account_id" extra --name 'Unexpected' --yes --json > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Extra rename argument was accepted.' >&2; exit 1
fi
if "$binary" rename "$account_id" --name 'First' --name 'Second' --yes --json > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Repeated rename name was accepted.' >&2; exit 1
fi
"$binary" status > "$test_root/status.log"
rg -F "Droid default: $account_id" "$test_root/status.log" >/dev/null

(printf '%s' 'synthetic-'; sleep 0.05; printf '%s' 'usage-key') | "$binary" droid-usage-key "$account_id" --stdin --yes --json | jq -e '.saved == true' >/dev/null
jq -e '.fields.apiKey == "synthetic-usage-key"' "$test_root/application-support/droid-usage/$account_id.json" >/dev/null
"$binary" droid-usage-key "$account_id" --remove --yes --json | jq -e '.saved == false' >/dev/null
if "$binary" droid-usage-key "$account_id" --stdin --remove --yes > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Conflicting key actions were accepted.' >&2; exit 1
fi
"$binary" claude-shell status --json | jq -e '.enabled == false' >/dev/null
"$binary" claude-shell enable --yes --json | jq -e '.enabled == true' >/dev/null
"$binary" claude-shell disable --yes --json | jq -e '.enabled == false' >/dev/null

cat > "$test_root/default-home/sessions/conversation.jsonl" <<'JSONL'
{"type":"session_meta","timestamp":"2026-10-01T00:00:00Z","payload":{"id":"synthetic-thread","cwd":"/synthetic","source":"cli","originator":"codex-tui"}}
{"type":"response_item","timestamp":"2026-10-01T00:00:01Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Synthetic CLI question"}]}}
{"type":"response_item","timestamp":"2026-10-01T00:00:02Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Synthetic CLI answer"}]}}
JSONL
"$binary" conversations list --query 'Synthetic CLI' --json > "$test_root/conversations.json"
jq -e '.matching == 1 and .threads[0].title == "Synthetic CLI question"' "$test_root/conversations.json" >/dev/null
thread_id="$(jq -r '.threads[0].id' "$test_root/conversations.json")"
for option in '--offset 1' '--role prompts'; do
  if "$binary" conversations list $option --json > "$test_root/invalid.log" 2>&1; then
    printf '%s\n' 'Message-only options were accepted for the conversation list.' >&2; exit 1
  fi
done
if "$binary" conversations show "$thread_id" --limit 201 --json > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Conversation page limit was silently truncated.' >&2; exit 1
fi
"$binary" conversations show "$thread_id" --limit 1 --json > "$test_root/page.json"
jq -e '.messages | length == 1' "$test_root/page.json" >/dev/null
offset="$(jq -r '.nextOffset' "$test_root/page.json")"
"$binary" conversations show "$thread_id" --offset "$offset" --json | jq -e '.messages[0].role == "assistant"' >/dev/null
"$binary" conversations show "$thread_id" --role prompts --json | jq -e '.matching == 1 and .messages[0].role == "user"' >/dev/null
"$binary" conversations export "$thread_id" > "$test_root/export.txt"
rg -F 'Synthetic CLI question' "$test_root/export.txt" >/dev/null
rg -F 'Synthetic CLI answer' "$test_root/export.txt" >/dev/null
if "$binary" conversations show "$thread_id" --offset -1 > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Negative conversation offset was accepted.' >&2; exit 1
fi

mission_id='11111111-2222-4333-8444-555555555555'
mkdir -p "$test_root/.factory/missions/$mission_id"
jq -n --arg directory "$test_root/project" '{state:"paused",workingDirectory:$directory,createdAt:"2026-10-01T00:00:00Z"}' > "$test_root/.factory/missions/$mission_id/state.json"
printf '%s\n' '{"features":[{"id":"first","description":"First feature","status":"completed"},{"id":"second","description":"Second feature","status":"pending"}]}' > "$test_root/.factory/missions/$mission_id/features.json"
printf '# Synthetic mission\n' > "$test_root/.factory/missions/$mission_id/mission.md"
"$binary" missions list --json | jq -e '.[0].completed == 1 and .[0].left == 1' >/dev/null
"$binary" missions owner "$mission_id" --account "$account_id" --yes --json | jq -e --arg id "$account_id" '.owner == $id' >/dev/null
"$binary" missions plan "$mission_id" --yes --json > "$test_root/plan.json"
plan_path="$(jq -r '.path' "$test_root/plan.json")"
test -f "$plan_path"
"$binary" missions resume "$mission_id" --yes
test "$(head -1 "$test_root/droid-arguments")" = '--resume'
test "$(tail -1 "$test_root/droid-arguments")" = "$mission_id"
"$binary" missions start "$mission_id" --yes
rg -Fx -- '--mission' "$test_root/droid-arguments" >/dev/null

if "$binary" auto-switch --provider unknown --yes > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Unknown automatic switch provider was accepted.' >&2; exit 1
fi
if "$binary" auto-switch --provider droid --min-remaining nan --yes > "$test_root/invalid.log" 2>&1; then
  printf '%s\n' 'Nonfinite automatic switch threshold was accepted.' >&2; exit 1
fi

mkdir -p "$test_root/grok-home/sessions/%2Fsynthetic%2Fproject/session" "$test_root/decoy-grok/sessions/%2Fdecoy/session"
timestamp_ms="$(( $(date +%s) * 1000 ))"
jq -cn --argjson timestamp "$timestamp_ms" '{params:{update:{sessionUpdate:"turn_completed",usage:{modelUsage:{"grok-4":{inputTokens:300,outputTokens:100,costUsdTicks:10000000000}}}},_meta:{agentTimestampMs:$timestamp,eventId:"synthetic-history"}}}' > "$test_root/grok-home/sessions/%2Fsynthetic%2Fproject/session/updates.jsonl"
jq -cn --argjson timestamp "$timestamp_ms" '{params:{update:{sessionUpdate:"turn_completed",usage:{modelUsage:{"grok-4":{inputTokens:900,outputTokens:900,costUsdTicks:90000000000}}}},_meta:{agentTimestampMs:$timestamp,eventId:"decoy-history"}}}' > "$test_root/decoy-grok/sessions/%2Fdecoy/session/updates.jsonl"
GROK_HOME="$test_root/decoy-grok" "$binary" history --json > "$test_root/history.json"
jq -e '.totals.tokens == 400 and .totals.costUSD == 1' "$test_root/history.json" >/dev/null
printf '%s\n' 'Workflow CLI acceptance passed.'
