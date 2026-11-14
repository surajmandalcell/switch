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

# The request log holds the methods, never the params.
grep -q 'rpc accounts.status id=2' "$root/switch/application-support/logs/helper.log"

# One helper per data root; SIGTERM stops the first one cleanly (exit 0).
mkfifo "$root/fifo"
HOME="$root/home" "$binary" serve --root "$root/switch" < "$root/fifo" > /dev/null 2>&1 &
first=$!
exec 3> "$root/fifo"
for _ in $(seq 50); do [ -f "$root/switch/application-support/helper.lock" ] && break; sleep 0.1; done
sleep 0.5
if HOME="$root/home" "$binary" serve --root "$root/switch" < /dev/null 2> "$root/err2"; then
  echo "a second helper started for the same root" >&2; exit 1
fi
grep -q 'another Switch helper already runs' "$root/err2"
kill -TERM "$first"
wait "$first"
exec 3>&-
echo "switch-core serve: a second helper is refused; SIGTERM exits 0"

# doctor: every check passes on a fresh root and the exit code says so.
# A build host has no terminal emulator, so TERMINAL names a program that exists.
HOME="$root/home" TERMINAL=/bin/true "$binary" doctor --root "$root/switch" > "$root/doctor" || { cat "$root/doctor"; exit 1; }
grep -q '^result      all checks passed' "$root/doctor"
echo "switch-core doctor: all checks passed"
