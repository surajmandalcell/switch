#!/usr/bin/env bash
# Starts the real switch-core on a temporary root (--root), pipes three frames in, and checks three replies out.
# Usage: scripts/check-switch-core-serve.sh <path to switch-core>
set -euo pipefail

binary="${1:?Usage: check-switch-core-serve.sh <path to switch-core>}"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

frames='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
{"jsonrpc":"2.0","id":2,"method":"accounts.status"}
{"jsonrpc":"2.0","id":3,"method":"shutdown"}'

printf '%s\n' "$frames" > "$root/in"
HOME="$root/home" "$binary" serve --root "$root/switch" < "$root/in" > "$root/out" 2> "$root/err"

cat "$root/in"
echo "---"
cat "$root/out"
# Replies come in completion order; shutdown is always last.
jq -e -s --arg root "$root/switch" 'sort_by(.id) | length == 3
  and .[0].id == 1 and .[0].result.protocolVersion == 1
  and .[1].id == 2 and .[1].result.accounts == [] and (.[1].result.sharedRoot | startswith($root))
  and .[2].id == 3 and (.[2] | has("result")) and .[2].result == null' "$root/out" > /dev/null
echo "switch-core serve: 3 frames in, 3 replies out, data under --root, exit 0"
