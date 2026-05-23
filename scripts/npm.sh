#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

NPM="${NPM:-npm}"
NODE="${NODE:-node}"
TEST_HOST="${TEST_HOST:-127.0.0.1}"
TEST_PORT_WAS_SET="${TEST_PORT+x}"
TEST_PORT="${TEST_PORT:-28081}"
NPM_SCOPE="${NPM_SCOPE:-@pikoloo}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"
NPM_AUTH_TYPE="${NPM_AUTH_TYPE:-web}"
NPM_ACCESS="${NPM_ACCESS:-public}"
NPM_TAG="${NPM_TAG:-latest}"

usage() {
  cat <<'EOF'
Usage: scripts/npm.sh <command>

Commands:
  update [patch|minor|major|VERSION]
           Bump package version, verify, and commit the release bump.
  publish  Verify, login if needed, and publish to npm.

Environment:
  VERSION=1.2.3        Exact version for update.
  LEVEL=patch          npm version level for update when VERSION is not set.
  OTP=123456           npm two-factor code for publish.
  TEST_PORT=28081      Local test server port.
EOF
}

ensure_clean() {
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "Working tree must be clean before update or publish."
    git status --short
    exit 1
  fi
}

install_deps() {
  "$NPM" install
}

build() {
  "$NPM" run build
}

test_with_server() {
  mkdir -p tmp
  local log_file="tmp/test-server.log"
  rm -f "$log_file"

  local explicit_port=0
  if [ -n "$TEST_PORT_WAS_SET" ]; then
    explicit_port=1
  fi

  local test_port
  test_port="$("$NODE" scripts/resolve-test-port.mjs "$TEST_HOST" "$TEST_PORT" "$explicit_port")"
  if [ "$test_port" != "$TEST_PORT" ]; then
    echo "TEST_PORT $TEST_PORT is unavailable on $TEST_HOST; using $test_port for release verification."
  fi

  HOST="$TEST_HOST" PORT="$test_port" "$NODE" src/index.js >"$log_file" 2>&1 &
  local server_pid=$!

  cleanup() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM

  local ready=0
  for _ in {1..20}; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "Test server exited before becoming ready on http://$TEST_HOST:$test_port"
      cat "$log_file"
      exit 1
    fi

    if curl -fsS "http://$TEST_HOST:$test_port/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.5
  done

  if [ "$ready" -ne 1 ]; then
    echo "Server did not start on http://$TEST_HOST:$test_port"
    cat "$log_file"
    exit 1
  fi

  ROUTING_TEST_BASE_URL="http://$TEST_HOST:$test_port" \
    UI_TEST_URL="http://$TEST_HOST:$test_port/" \
    "$NPM" run test:all

  cleanup
  trap - EXIT INT TERM
}

login_if_needed() {
  if "$NPM" whoami --registry="$NPM_REGISTRY" >/dev/null 2>&1; then
    return
  fi

  echo "Not logged in to $NPM_REGISTRY. Starting npm login for $NPM_SCOPE."
  "$NPM" login --scope="$NPM_SCOPE" --registry="$NPM_REGISTRY" --auth-type="$NPM_AUTH_TYPE"
  "$NPM" whoami --registry="$NPM_REGISTRY" >/dev/null
}

update_version_banner() {
  local version="$1"
  "$NODE" --input-type=module - "$version" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';

const version = process.argv[2];
const file = 'src/index.js';
const content = readFileSync(file, 'utf8');
const next = content.replace(/Codex Claude Proxy v\d+\.\d+\.\d+/g, `Codex Claude Proxy v${version}`);

if (next === content) {
  throw new Error('Could not update src/index.js version banner');
}

writeFileSync(file, next);
NODE
}

resolve_update_version_arg() {
  if [ "$#" -gt 1 ]; then
    echo "update accepts at most one version argument." >&2
    usage >&2
    exit 2
  fi

  local requested="${1:-}"
  case "$requested" in
    --*)
      echo "Unknown update option: $requested" >&2
      usage >&2
      exit 2
      ;;
  esac

  if [ -n "${VERSION:-}" ]; then
    if [ -n "$requested" ] || [ -n "${LEVEL:-}" ]; then
      echo "Use VERSION by itself, without LEVEL or an update argument." >&2
      exit 2
    fi
    printf '%s\n' "$VERSION"
    return
  fi

  if [ -n "$requested" ]; then
    if [ -n "${LEVEL:-}" ]; then
      echo "Use either LEVEL or an update argument, not both." >&2
      exit 2
    fi
    printf '%s\n' "$requested"
    return
  fi

  printf '%s\n' "${LEVEL:-patch}"
}

cmd_update() {
  local version_arg
  version_arg="$(resolve_update_version_arg "$@")"

  ensure_clean
  install_deps

  "$NPM" version "$version_arg" --no-git-tag-version

  local version
  version="$("$NODE" -p "JSON.parse(require('fs').readFileSync('package.json', 'utf8')).version")"
  update_version_banner "$version"

  build
  test_with_server
  git diff --check
  git add package.json package-lock.json src/index.js
  git commit -m "Release: bump npm package to v$version"
}

cmd_publish() {
  ensure_clean
  install_deps
  ensure_clean
  build
  test_with_server
  login_if_needed

  local publish_args=(--access "$NPM_ACCESS" --tag "$NPM_TAG" --registry "$NPM_REGISTRY")
  if [ -n "${OTP:-}" ]; then
    publish_args+=(--otp "$OTP")
  fi

  "$NPM" publish "${publish_args[@]}"
}

case "${1:-}" in
  update)
    shift
    cmd_update "$@"
    ;;
  publish)
    cmd_publish
    ;;
  ""|help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
