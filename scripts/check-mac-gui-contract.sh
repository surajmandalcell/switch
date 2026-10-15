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
# Removed test defaults suites still leave an empty plist (cfprefsd writes it later); clear old ones.
find "$HOME/Library/Preferences" -maxdepth 1 -name 'switch-*-????????-????-????-????-????????????.plist' -mmin +10 -delete 2>/dev/null || true

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
# Flat controls: system pickers, checkboxes, and bordered buttons draw a light rim in Dark Mode. Use the AIM parts.
if rg -n '\.pickerStyle\(|(^|[^A-Za-z])(Date)?Picker\(|\.toggleStyle\(\.(checkbox|switch)\)|\.buttonStyle\(\.bordered' "$repo_root/packages/mac-gui/Sources" \
    --glob '!AIManagerParts.swift' --glob '!AccountWindow.swift' --glob '!AIManagerApp.swift'; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL system rimmed control: use AIMPopUp, AIMSegmentedPicker, AIMToggleStyle, or AIMCheckboxToggleStyle' >&2
  exit 1
fi
# Native structure: Settings is a column of shared cards as wide as the top bar, and the sidebar is the window's own AIMSidebar.
window_source="$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/AccountWindow.swift"
settings_source="$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/SettingsPage.swift"
settings_body="$(awk '/^struct SettingsPage: View/{f=1} f{print} /^private struct DataLocationRow/{f=0}' "$settings_source")"
if ! printf '%s\n' "$settings_body" | rg -q 'AIMScrollPage \{' || printf '%s\n' "$settings_body" | rg -q 'maxWidth|^\s*Form \{'; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL Settings is not a full-width column of AIMSection cards' >&2
  exit 1
fi
settings_groups="$(printf '%s\n' "$settings_body" | awk '/AIMSection\("/{split($0, parts, "\""); print parts[2]} /AIMSection\(SettingsCopy.notificationsTitle\)/{print "Notifications"}')"
if [[ "$settings_groups" != $'General\nAppearance\nAccounts\nAuto switch\nMenu bar\nNotifications\nData locations\nReset\nDemo states' ]]; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL Settings groups do not match the product contract' >&2
  exit 1
fi
parts_source="$repo_root/packages/mac-gui/Sources/AIManagerMacGUI/AIManagerParts.swift"
# The default account is marked with a disabled button, never a colored chip.
if rg -n 'AIMStateChip' "$repo_root/packages/mac-gui/Sources"; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL obsolete default state chip' >&2
  exit 1
fi
# The result of an action is a macOS notification, never a card: only the model and the Maintenance store touch `notice`.
if rg -n 'model\.notice' "$repo_root/packages/mac-gui/Sources" --glob '!AccountViewModel.swift' --glob '!MaintenanceStore.swift'; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL a view renders model.notice: post the message as a notification instead' >&2
  exit 1
fi
if rg -n '(^|[^A-Za-z])(ScrollView\s*(\(|\{)|List\s*\(|Form\s*\{)|\.scrollIndicators\(\.hidden\)' \
    "$repo_root/packages/mac-gui/Sources" --glob '!AIManagerParts.swift'; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL every surface must use AIMScrollView or AIMSheetForm' >&2
  exit 1
fi
if ! rg -q 'AIMSidebar\(' "$window_source" || ! rg -q 'NSVisualEffectView' "$parts_source" \
  || rg -q '\.toolbar \{|NavigationSplitView' "$window_source"; then
  printf '%s\n' 'MAC_GUI_CONTRACT_FAIL the window must draw its own sidebar (AIMSidebar over a visual-effect material) with no toolbar bar' >&2
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

# Both system scroll bar styles (legacy as with a mouse, overlay as with a trackpad): after a page
# round trip every card and the top bar end at W-20 and no scroll view reserves a scroller strip.
for style in always overlay; do
  run_root="$test_root/scrollers-$style"
  artifacts="$run_root/artifacts"
  mkdir -p "$run_root/home" "$run_root/codex-home" "$run_root/manager" "$run_root/tmp" "$artifacts"
  HOME="$run_root/home" \
  CFFIXED_USER_HOME="$run_root/home" \
  CODEX_HOME="$run_root/codex-home" \
  AI_MANAGER_ROOT="$run_root/manager" \
  AI_MANAGER_ORCA_ACCOUNTS_ROOT="$run_root/manager/orca-accounts" \
  AI_MANAGER_CODEX_EXECUTABLE="/usr/bin/false" \
  AI_MANAGER_ACCEPTANCE_ARTIFACTS="$artifacts" \
  TMPDIR="$run_root/tmp" \
    "$executable" --contract-only --persisted-light "--scrollers=$style"
  if [[ "$(/usr/bin/plutil -extract passed raw -o - "$artifacts/window-contract.json")" != "true" ]]; then
    /usr/bin/plutil -p "$artifacts/window-contract.json" >&2
    exit 1
  fi
  printf 'MAC_GUI_CONTRACT_PASS scrollers %s\n' "$style"
done

# Focus rings: with Full Keyboard Access on (the owner's Mac, `-AppleKeyboardUIMode 2`), no
# system focus ring may draw unless Increase Contrast is on. The history page holds the virtual
# table, Settings the pop-ups and the shortcut recorder, Maintenance the date field.
for focus_args in "--history --history-stress" "--accounts" "--settings" "--backup" "--cleanup"; do
  run_root="$test_root/focus-rings-${focus_args//[^a-z]/}"
  artifacts="$run_root/artifacts"
  mkdir -p "$run_root/home" "$run_root/codex-home" "$run_root/manager" "$run_root/tmp" "$artifacts"
  # shellcheck disable=SC2086
  HOME="$run_root/home" \
  CFFIXED_USER_HOME="$run_root/home" \
  CODEX_HOME="$run_root/codex-home" \
  AI_MANAGER_ROOT="$run_root/manager" \
  AI_MANAGER_ORCA_ACCOUNTS_ROOT="$run_root/manager/orca-accounts" \
  AI_MANAGER_CODEX_EXECUTABLE="/usr/bin/false" \
  AI_MANAGER_ACCEPTANCE_ARTIFACTS="$artifacts" \
  TMPDIR="$run_root/tmp" \
    "$executable" --contract-only --snapshot-only $focus_args --persisted-light \
      --require-full-keyboard-access -AppleKeyboardUIMode 2
  if [[ "$(/usr/bin/plutil -extract passed raw -o - "$artifacts/window-contract.json")" != "true" ]]; then
    /usr/bin/plutil -p "$artifacts/window-contract.json" >&2
    printf 'MAC_GUI_CONTRACT_FAIL focus rings (%s): a system focus ring can draw with Full Keyboard Access on\n' "$focus_args" >&2
    exit 1
  fi
  printf 'MAC_GUI_CONTRACT_PASS focus rings %s\n' "$focus_args"
done

# Conversations: long messages (code blocks of hundreds of lines, long lines, nested fences) render
# with no clipped or overlapping row at two window widths, and every page switch renders its first
# frame within the bound against a large synthetic dataset.
for conversation_args in "--conversations-check" "--conversations-check --page-switch-only"; do
  run_root="$test_root/conversations-${conversation_args//[^a-z]/}"
  mkdir -p "$run_root/home" "$run_root/codex-home" "$run_root/manager" "$run_root/tmp" "$run_root/artifacts"
  # shellcheck disable=SC2086
  HOME="$run_root/home" \
  CFFIXED_USER_HOME="$run_root/home" \
  CODEX_HOME="$run_root/codex-home" \
  AI_MANAGER_ROOT="$run_root/manager" \
  AI_MANAGER_ORCA_ACCOUNTS_ROOT="$run_root/manager/orca-accounts" \
  AI_MANAGER_CODEX_EXECUTABLE="/usr/bin/false" \
  AI_MANAGER_ACCEPTANCE_ARTIFACTS="$run_root/artifacts" \
  TMPDIR="$run_root/tmp" \
    "$executable" --contract-only $conversation_args
  printf 'MAC_GUI_CONTRACT_PASS conversations %s\n' "$conversation_args"
done
