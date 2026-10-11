#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'Switch Mac GUI contracts require macOS.' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_path="${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}"
app_path="$build_path/mac-gui-acceptance/Switch Mac GUI Acceptance.app"
executable="$app_path/Contents/MacOS/AIManagerMacGUIAcceptance"
mkdir -p "$build_path"
test_root="$(mktemp -d "$build_path/switch-mac-gui-contract.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

# The type ramp is five roles (AIMTextRole). No hardcoded sizes or removed font helpers.
# A hit here fails the contract before the app is built.
lint_pattern='AIMTheme\.(sans|mono)\b|\.system\(size:'
if rg -n "$lint_pattern" "$repo_root/packages/mac-gui/Sources"; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL font lint: use AIMTextRole through .aimText(_:), not AIMTheme.sans, AIMTheme.mono, or .system(size:)' >&2
  exit 1
fi
# Fonts come from the five roles only: a .font( call must name AIMTextRole (Design holds the roles).
if rg -n '\.font\(' "$repo_root/packages/mac-gui/Sources" --glob '!AIManagerDesign.swift' | rg -v 'AIMTextRole'; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL font lint: set fonts with .aimText(_:) or .aimFont(_:)' >&2
  exit 1
fi
# Native structure: Settings is a grouped Form and the sidebar is a plain List in a NavigationSplitView.
window_source="$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/AccountWindow.swift"
settings_body="$(awk '/^struct SettingsPage: View/{f=1} f{print} /^private struct DataLocationRow/{f=0}' "$window_source")"
if ! printf '%s\n' "$settings_body" | rg -q '^\s*Form \{' || ! printf '%s\n' "$settings_body" | rg -q '\.formStyle\(\.grouped\)'; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL Settings is not a grouped Form' >&2
  exit 1
fi
sidebar_body="$(awk '/NavigationSplitView \{/{f=1} f{print} /\} detail: \{/{f=0}' "$window_source")"
if ! printf '%s\n' "$sidebar_body" | rg -q 'List\(AIManagerPage\.allCases' \
  || printf '%s\n' "$sidebar_body" | rg -q '\.(font|padding|background|listStyle)\('; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL the sidebar is not a plain native List (only its column width may be set)' >&2
  exit 1
fi

"$repo_root/scripts/build-mac-gui-acceptance.sh"

for appearance in system light dark; do
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

  if [[ ! -f "$receipt" ]]; then
    printf 'MAC_GUI_CONTRACT_FAIL %s: no receipt\n' "$appearance" >&2
    exit 1
  fi
  passed="$(/usr/bin/plutil -extract passed raw -o - "$receipt")"
  stage="$(/usr/bin/plutil -extract window.stage raw -o - "$receipt")"
  appearance_matches=true
  if [[ "$appearance" != "system" ]]; then
    actual_appearance="$(/usr/bin/plutil -extract window.appearance raw -o - "$receipt")"
    expected_appearance="NSAppearanceNameAqua"
    if [[ "$appearance" == "dark" ]]; then expected_appearance="NSAppearanceNameDarkAqua"; fi
    if [[ "$actual_appearance" != "$expected_appearance" ]]; then appearance_matches=false; fi
  fi
  if [[ "$passed" != "true" || "$stage" != "contract-only" || "$appearance_matches" != "true" ]]; then
    /usr/bin/plutil -p "$receipt" >&2
    exit 1
  fi

  history_artifacts="$run_root/history-artifacts"
  history_receipt="$history_artifacts/window-contract.json"
  mkdir -p "$history_artifacts"
  HOME="$run_root/home" \
  CFFIXED_USER_HOME="$run_root/home" \
  CODEX_HOME="$run_root/codex-home" \
  AI_MANAGER_ROOT="$run_root/manager" \
  AI_MANAGER_ORCA_ACCOUNTS_ROOT="$run_root/manager/orca-accounts" \
  AI_MANAGER_CODEX_EXECUTABLE="/usr/bin/false" \
  AI_MANAGER_ACCEPTANCE_ARTIFACTS="$history_artifacts" \
  TMPDIR="$run_root/tmp" \
    "$executable" --contract-only --snapshot-only --history --history-stress "--persisted-$appearance"
  if [[ ! -f "$history_receipt" \
      || "$(/usr/bin/plutil -extract passed raw -o - "$history_receipt")" != "true" ]]; then
    /usr/bin/plutil -p "$history_receipt" >&2
    exit 1
  fi
  printf 'MAC_GUI_CONTRACT_PASS %s\n' "$appearance"
done
