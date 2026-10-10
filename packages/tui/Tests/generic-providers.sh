#!/usr/bin/env bash
# Acceptance for generic provider accounts: usage, guard, add, import, and the interactive screens.
# Uses an isolated root, a synthetic key, and a loopback LiteLLM stub. No real credentials or network.

set -euo pipefail

if [[ $# -ne 1 || ! -x "$1" ]]; then
  printf '%s\n' 'Usage: generic-providers.sh <ai-manager-binary>' >&2
  exit 64
fi

binary="$1"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/ai-manager-generic-test.XXXXXX")"
stub_pid=""
cleanup() {
  [[ -n "$stub_pid" ]] && kill "$stub_pid" 2>/dev/null || true
  find "$test_root" -depth -delete
}
trap cleanup EXIT

export AI_MANAGER_ROOT="$test_root/root"
mkdir -p "$AI_MANAGER_ROOT"
secret='sk-synthetic-not-a-real-key'

fail() { printf '%s\n' "$1" >&2; exit 1; }

# expect_exit <code> <message fragment or ''> <command...>
expect_exit() {
  local want="$1" fragment="$2" got=0
  shift 2
  "$@" >"$test_root/out.log" 2>"$test_root/err.log" </dev/null || got=$?
  [[ "$got" -eq "$want" ]] || {
    cat "$test_root/err.log" >&2
    fail "Expected exit $want, got $got: $*"
  }
  if [[ -n "$fragment" ]]; then
    cat "$test_root/out.log" "$test_root/err.log" | rg -F -- "$fragment" >/dev/null \
      || fail "Expected '$fragment' in the output of: $*"
  fi
}

# usage: empty list, JSON shape, argument errors (exit 2)
"$binary" usage --json | jq -e '
    .schema == "switch.limits.v1"
    and (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    and .accounts == [] and .errors == []
    and (keys | sort) == ["accounts", "errors", "generatedAt", "schema"]
  ' >/dev/null
"$binary" usage | rg -F 'No saved accounts to check.' >/dev/null
"$binary" usage litellm --json | jq -e '.accounts == []' >/dev/null
expect_exit 2 'Unknown option' "$binary" usage --bogus
expect_exit 2 'Unknown provider' "$binary" usage not-a-provider
expect_exit 2 'No saved account' "$binary" usage 123e4567-e89b-42d3-a456-426614174000
expect_exit 2 'at most one' "$binary" usage litellm cursor

# guard: argument errors (exit 64) and unknown results (exit 69, or 0 with --fail-open)
expect_exit 64 '--provider' "$binary" guard --min-remaining 10
expect_exit 64 'Unknown provider' "$binary" guard --provider not-a-provider --min-remaining 10
expect_exit 64 '--min-remaining' "$binary" guard --provider litellm
expect_exit 64 '--min-remaining' "$binary" guard --provider litellm --min-remaining abc
expect_exit 64 '--min-remaining' "$binary" guard --provider litellm --min-remaining 101
expect_exit 64 '--min-remaining' "$binary" guard --provider litellm --min-remaining -1
expect_exit 64 '--account' "$binary" guard --provider litellm --min-remaining 10 --account nope
expect_exit 64 'No saved litellm account' "$binary" guard --provider litellm --min-remaining 10 \
  --account 123e4567-e89b-42d3-a456-426614174000
expect_exit 64 'Unknown option' "$binary" guard --provider litellm --min-remaining 10 --bogus
expect_exit 69 'No default litellm account' "$binary" guard --provider litellm --min-remaining 10
expect_exit 0 'unknown' "$binary" guard --provider litellm --min-remaining 10 --fail-open
"$binary" guard --provider litellm --min-remaining 10 --json --fail-open | jq -e '
    .decision == "unknown" and .exitCode == 0 and .provider == "litellm" and .threshold == 10
    and (.reason | length > 0) and (has("remaining") | not)
  ' >/dev/null
guard_status=0
"$binary" guard --provider litellm --min-remaining 10 --json >"$test_root/guard-unknown.json" || guard_status=$?
[[ "$guard_status" -eq 69 ]] && jq -e '.decision == "unknown" and .exitCode == 69' "$test_root/guard-unknown.json" >/dev/null \
  || fail 'Unknown guard decision did not exit 69.'

# add and import validation
expect_exit 2 'needs: apiKey, baseURL' "$binary" add litellm
expect_exit 2 'Unknown field' "$binary" add litellm --field bogus=1
expect_exit 2 'Use --field key=value' "$binary" add litellm --field apiKey
expect_exit 2 'given twice' "$binary" add litellm --field apiKey=a --field apiKey=b
expect_exit 2 'needs: baseURL' "$binary" add litellm --field "apiKey=$secret"
if rg -F -- "$secret" "$test_root/out.log" "$test_root/err.log" >/dev/null; then
  fail 'A validation message printed the key.'
fi
expect_exit 2 'Standard input was empty' "$binary" add litellm --field baseURL=http://127.0.0.1:9 --stdin
expect_exit 2 'typed credentials' "$binary" import litellm
expect_exit 1 'not signed in' "$binary" import cursor --yes
"$binary" status --json | jq -e '.accounts == []' >/dev/null

# Interactive Add Account lists generic providers and filters as you type; secure input is read from stdin here.
printf '\r' | AI_MANAGER_TUI_KEYS=always "$binary" interactive >"$test_root/tui-add.log"
rg -F 'Provider: (type to filter)' "$test_root/tui-add.log" >/dev/null
printf '\rlitel\033\033' | AI_MANAGER_TUI_KEYS=always "$binary" interactive >"$test_root/tui-filter.log"
rg -F '> LiteLLM' "$test_root/tui-filter.log" >/dev/null
rg -F '1/1' "$test_root/tui-filter.log" >/dev/null

if ! command -v python3 >/dev/null; then
  printf '%s\n' 'Generic provider checks passed (stub server checks skipped: python3 not found).'
  exit 0
fi

# Loopback LiteLLM stub: personal budget 20 of 100 used, so 80% remains.
cat >"$test_root/stub.py" <<'PY'
import http.server, json

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/key/info'):
            body = {"info": {"user_id": "u1"}}
        elif self.path.startswith('/user/info'):
            body = {"user_info": {"user_id": "u1", "user_email": "stub@example.test", "spend": 20,
                                  "max_budget": 100, "budget_reset_at": "2030-01-01T00:00:00Z"}, "teams": []}
        else:
            self.send_response(404); self.end_headers(); return
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args): pass

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 -I "$test_root/stub.py" >"$test_root/stub.port" &
stub_pid=$!
for _ in {1..50}; do [[ -s "$test_root/stub.port" ]] && break; sleep 0.1; done
port="$(cat "$test_root/stub.port")"
[[ "$port" =~ ^[0-9]+$ ]] || fail 'The loopback stub did not start.'
base="http://127.0.0.1:$port"

printf '%s\n' "$secret" | "$binary" add litellm --field "baseURL=$base" --stdin --json >"$test_root/add.json"
jq -e '.provider == "litellm" and .providerName == "LiteLLM" and .default == true' "$test_root/add.json" >/dev/null
account_id="$(jq -r '.id' "$test_root/add.json")"
if rg -F -- "$secret" "$test_root/add.json" >/dev/null; then fail 'add --json printed the key.'; fi

"$binary" usage --json >"$test_root/usage.json"
jq -e --arg id "$account_id" '
    .schema == "switch.limits.v1" and .errors == [] and (.accounts | length) == 1
    and .accounts[0].id == $id and .accounts[0].provider == "litellm"
    and .accounts[0].providerName == "LiteLLM" and .accounts[0].email == "stub@example.test"
    and .accounts[0].plan == "API" and .accounts[0].default == true
    and (.accounts[0].fetchedAt | test("Z$"))
    and .accounts[0].windows[0].id == "personal"
    and .accounts[0].windows[0].usedPercent == 20 and .accounts[0].windows[0].remainingPercent == 80
    and .accounts[0].windows[0].resetsAt == "2030-01-01T00:00:00Z"
    and (.accounts[0].windows[0] | has("windowSeconds") | not)
    and .accounts[0].cost.used == 20 and .accounts[0].cost.limit == 100 and .accounts[0].cost.currency == "USD"
    and (.accounts[0].cost | has("balance") | not)
  ' "$test_root/usage.json" >/dev/null
if rg -F -- "$secret" "$test_root/usage.json" >/dev/null; then fail 'usage --json printed the key.'; fi
"$binary" usage litellm | rg -F '80% left' >/dev/null
"$binary" usage "$account_id" --json | jq -e '(.accounts | length) == 1' >/dev/null
"$binary" usage --force --json | jq -e '(.accounts | length) == 1' >/dev/null

"$binary" guard --provider litellm --min-remaining 50 --json | jq -e '
    .decision == "allow" and .exitCode == 0 and .remaining == 80 and .threshold == 50 and .window == "personal"
  ' >/dev/null
expect_exit 0 'allow' "$binary" guard --provider litellm --min-remaining 79.9 --window personal
expect_exit 1 'block' "$binary" guard --provider litellm --min-remaining 80
expect_exit 1 'block' "$binary" guard --provider litellm --min-remaining 100 --account "$account_id"
expect_exit 69 'no window' "$binary" guard --provider litellm --min-remaining 10 --window nope
expect_exit 0 'unknown' "$binary" guard --provider litellm --min-remaining 10 --window nope --fail-open
guard_status=0
"$binary" guard --provider litellm --min-remaining 80 --json >"$test_root/guard-block.json" || guard_status=$?
[[ "$guard_status" -eq 1 ]] && jq -e '.decision == "block" and .exitCode == 1' "$test_root/guard-block.json" >/dev/null \
  || fail 'Blocked guard decision did not exit 1.'

# Interactive account screen: usage line, money row, and the three generic actions.
printf '\r\033\033' | AI_MANAGER_TUI_KEYS=always AI_MANAGER_TUI_PERCENTAGE=left "$binary" interactive >"$test_root/tui-account.log"
rg -F 'LiteLLM' "$test_root/tui-account.log" >/dev/null
rg -F 'Personal budget' "$test_root/tui-account.log" >/dev/null
rg -F '80% left' "$test_root/tui-account.log" >/dev/null
rg -F 'spend' "$test_root/tui-account.log" >/dev/null
rg -F 'Using as default' "$test_root/tui-account.log" >/dev/null
rg -F 'Refresh usage' "$test_root/tui-account.log" >/dev/null
rg -F 'Delete account' "$test_root/tui-account.log" >/dev/null
if rg -F 'Open ' "$test_root/tui-account.log" >/dev/null; then fail 'A generic account offered an Open action.'; fi

# Interactive add with type-to-filter, then prompts for each field.
printf '\033[B\rlitel\rsecond-synthetic-key\n%s\n' "$base" | AI_MANAGER_TUI_KEYS=always "$binary" interactive >"$test_root/tui-add-secret.log"
rg -F 'LiteLLM takes typed credentials' "$test_root/tui-add-secret.log" >/dev/null
rg -F 'API key:' "$test_root/tui-add-secret.log" >/dev/null
rg -F 'Saved LiteLLM account' "$test_root/tui-add-secret.log" >/dev/null
if rg -F 'second-synthetic-key' "$test_root/tui-add-secret.log" >/dev/null; then fail 'The TUI echoed the key.'; fi
"$binary" status --json | jq -e '(.accounts | length) == 2' >/dev/null
second_id="$("$binary" status --json | jq -r --arg id "$account_id" '.accounts[] | select(.id != $id) | .id')"
printf '\033[B\r\033\033' | AI_MANAGER_TUI_KEYS=always "$binary" interactive >"$test_root/tui-second.log"
rg -F 'Switch to this account' "$test_root/tui-second.log" >/dev/null

# Switch and delete through the CLI.
"$binary" use "$second_id" --yes --json | jq -e --arg id "$second_id" '.accountID == $id' >/dev/null
"$binary" status --json | jq -e --arg id "$second_id" '.defaultAccountIDs.litellm == $id' >/dev/null
"$binary" guard --provider litellm --min-remaining 50 --json | jq -e --arg id "$second_id" '.account == $id' >/dev/null
"$binary" remove "$second_id" --yes --json | jq -e --arg id "$second_id" '.accountID == $id' >/dev/null
"$binary" status --json | jq -e --arg id "$account_id" '(.accounts | length) == 1 and .defaultAccountIDs.litellm == $id' >/dev/null

# Stub gone: every fetch fails, usage exits 4 and lists the error, guard exits 69.
kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true
stub_pid=""
usage_status=0
"$binary" usage --json >"$test_root/usage-down.json" || usage_status=$?
[[ "$usage_status" -eq 4 ]] || fail "Expected usage exit 4 when every fetch fails, got $usage_status."
jq -e --arg id "$account_id" '.accounts == [] and (.errors | length) == 1 and .errors[0].accountId == $id and .errors[0].provider == "litellm" and (.errors[0].message | length > 0)' \
  "$test_root/usage-down.json" >/dev/null
expect_exit 69 'could not be read' "$binary" guard --provider litellm --min-remaining 10
expect_exit 0 'unknown' "$binary" guard --provider litellm --min-remaining 10 --fail-open

printf '%s\n' 'Generic provider checks passed.'
