#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'IIA Directeur GUI contracts require macOS.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
app_path="$build_path/gui-acceptance/IIA Directeur GUI Acceptance.app"
executable="$app_path/Contents/MacOS/AIManagerGUIAcceptance"
test_root="$(mktemp -d "/private/tmp/iia-directeur-gui-contract.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

"$repo_root/scripts/build-gui-acceptance.sh"

for appearance in light dark; do
  run_root="$test_root/$appearance"
  artifacts="$run_root/artifacts"
  receipt="$artifacts/window-contract.json"
  mkdir -p "$run_root/home" "$run_root/codex-home" "$run_root/manager" "$run_root/tmp" "$artifacts"

  HOME="$run_root/home" \
  CFFIXED_USER_HOME="$run_root/home" \
  CODEX_HOME="$run_root/codex-home" \
  AI_MANAGER_ROOT="$run_root/manager" \
  AI_MANAGER_ORCA_ACCOUNTS_ROOT="$run_root/manager/orca-accounts" \
  AI_MANAGER_CODEX_EXECUTABLE="/usr/bin/false" \
  AI_MANAGER_ACCEPTANCE_ARTIFACTS="$artifacts" \
  TMPDIR="$run_root/tmp" \
    "$executable" --contract-only "--persisted-$appearance"

  expected_appearance="NSAppearanceNameAqua"
  if [[ "$appearance" == "dark" ]]; then
    expected_appearance="NSAppearanceNameDarkAqua"
  fi
  if [[ ! -f "$receipt" ]]; then
    printf 'GUI_CONTRACT_FAIL %s: no receipt\n' "$appearance" >&2
    exit 1
  fi
  passed="$(/usr/bin/plutil -extract passed raw -o - "$receipt")"
  stage="$(/usr/bin/plutil -extract window.stage raw -o - "$receipt")"
  actual_appearance="$(/usr/bin/plutil -extract window.appearance raw -o - "$receipt")"
  if [[ "$passed" != "true" || "$stage" != "contract-only" || "$actual_appearance" != "$expected_appearance" ]]; then
    /usr/bin/plutil -p "$receipt" >&2
    exit 1
  fi
  printf 'GUI_CONTRACT_PASS %s\n' "$appearance"
done
