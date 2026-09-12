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
export AI_MANAGER_ROOT="$fixture"
export AI_MANAGER_CODEX_EXECUTABLE="$fixture/fake-codex"

"$binary" discover "$fixture/source-one" --json \
  | jq -e 'length == 1 and .[0].identity.workspaceID == "workspace-a"' >/dev/null

interactive_result="$test_root/interactive-result.log"
printf 'i\n%s\n2\nk\nn\nn\nq\n' "$fixture/source-one" | "$binary" interactive >"$interactive_result"
rg -F 'Reviewed linked setting rules:' "$interactive_result" >/dev/null
rg -e 'Target: .*/ai-manager-fixture/external-rules$' "$interactive_result" >/dev/null
rg -e 'Size: [1-9][0-9]* bytes' "$interactive_result" >/dev/null
rg -e 'Fingerprint: [0-9a-f]{64}' "$interactive_result" >/dev/null
rg -F 'Use this imported linked setting? [y/N]' "$interactive_result" >/dev/null
rg -F 'Import cancelled.' "$interactive_result" >/dev/null

auth_result="$test_root/auth-result.json"
"$binary" import "$fixture/source-two" --mode auth-only --yes --json >"$auth_result"
jq -e '.importedChats == 0 and (.unresolved | length) == 0' "$auth_result" >/dev/null

full_result="$test_root/full-result.json"
"$binary" plan "$fixture/source-one" --mode full --json \
  | jq -e '.conflicts[] | select(.relativePath == "rules") | .externalTarget != null and .externalTargetBytes == null' >/dev/null
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
if jq -e '.account.id != null' "$full_result" >/dev/null 2>&1; then
  jq -e '.importedChats == 1 and (.unresolved | length) == 1' "$full_result" >/dev/null
  rg -F 'Reviewed linked setting rules:' "$test_root/full-error.log" >/dev/null
  rg -F 'Import completed with unresolved items' "$test_root/full-error.log" >/dev/null
  account_id="$(jq -r '.account.id' "$full_result")"
  expected_accounts=2
else
  rg -F 'Could not establish whether the default home is in use' "$test_root/full-error.log" >/dev/null
  account_id="$(jq -r '.account.id' "$auth_result")"
  expected_accounts=1
fi

"$binary" status --json \
  | jq -e --argjson expected "$expected_accounts" '(.accounts | length == $expected) and (.accounts | all(has("credentialDigest") | not))' >/dev/null
"$binary" verify "$account_id" --json \
  | jq -e '.state == "verifiedLocally"' >/dev/null
"$binary" open "$account_id" -- resume --all
profile_path="$("$binary" profile "$account_id")"
rg -F "$profile_path" "$fixture/launch.log" >/dev/null

printf '%s\n' 'CLI acceptance passed.'
