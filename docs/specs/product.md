# Switch product specification

Status: Initial accepted specification
Revision: 2026-09-15

This document defines the current product model and user-visible contract. `goals.md`
retains milestone history and verification evidence. If older milestone text conflicts
with this document, this specification owns the current behavior.

## 1. Product model

Switch manages provider authentication snapshots. Codex CLI is the only enabled provider
in the current release. Claude Code, Gemini CLI, and Antigravity CLI may appear only in the
Add Account catalog as inert WIP choices.

For Codex, `~/.codex` is the one live home. Its configuration, instructions, skills,
plugins, conversations, databases, and other non-authentication state remain in place when
the account changes. Switching replaces only `~/.codex/auth.json`, atomically, from a saved
private credential after identity and digest checks. Existing Codex processes keep their
in-memory credentials; the selected account applies to new sessions.

Saved credentials are regular owner-private files at `~/.switch/codex/<account-uuid>.json`.
The UUID is the stable internal identity and paths never contain an email address. Switch's
registry, usage cache, transactions, backups, and recovery metadata live in its application
support directory. Raw authentication is never stored in SQLite.

Temporary or managed homes used for sign-in, verification, import, migration, or recovery
are implementation details. Legacy internal links may still be repaired for compatibility,
but the interface must not describe linked entries as part of the product's everyday model.

After a restart, checking a completed sign-in reads the private staged credential and uses
the same identity, digest, and transaction checks as an auth-only import. An unrelated
running Codex process must not block that check. If Switch no longer owns the sign-in
process, it retires the session metadata and retains the staging home. Cancellation follows
the same rule: stop only a process Switch owns, and preserve a home whose writer is unknown.
Retired sessions do not reappear as pending or allow another import through their old ID.

## 2. Navigation and Settings

The rail and View menu use this order: Accounts, Backup, Chat History, Settings. Command+,
opens Settings. Settings contains only:

1. **App behavior** — Minimize to menu bar and the optional keyboard-focus indicator.
2. **Data locations** — Codex home (`~/.codex`) and saved account vault
   (`~/.switch/codex`), each with a plain-language purpose and an explicit Reveal action.
3. **Menu bar defaults** — Show account usage, initially off. Accounts without an
   explicit override follow this default. Changing it preserves explicit account choices.
4. Preview-only demo controls in Preview builds.

Settings never lists files as “Linked entries,” never implies that each account owns a
separate configuration or chat library, and never exposes internal managed-home topology.
An account-specific legacy repair may appear on that account only when action is required.

Cleanup is deferred. The current basic page is a frozen prototype and is not the accepted feature
design. Do not continue Cleanup implementation until the user explicitly resumes it.

When resumed, Cleanup uses a disclosure tree rather than a flat pair of actions. The hierarchy
groups rebuildable data by provider, account, and cache type while keeping shared indexes distinct.
It supports Chrome-style time ranges (last hour, last 24 hours, last 7 days, last 4 weeks, all time)
and a custom date interval where the underlying data has timestamps. Before clearing, it reports
the selected item count and estimated size, then shows one exact review summary. Accounts, saved
auth, settings, and source conversations remain excluded from Cleanup unless a future specification
adds a separate, explicitly destructive flow.

## 3. Usage presentation

Usage refresh reads the selected saved credential in a disposable private home and never
activates that account. The main Usage panel shows returned rate-limit windows and returned
statistics. Optional fields are conditional:

- Omit a missing plan, credits value, spend-control value, activity statistic, secondary
  window, and daily-activity section.
- Render a value such as zero, `false`, `None`, or `Available` when the service explicitly
  returned it; absence alone removes the row.
- Keep actionable core states: “Usage has not been checked,” a refresh error, or the absence
  of all rate-limit windows.
- Never manufacture a value from transcripts and never combine stale usage with Needs
  sign-in.

Daily activity uses a GitHub-style calendar instead of a date table. The user can select 7 days,
1 month, or 1 year. Cell intensity reflects the token count within the selected range, and a
selected day shows its date and exact token count.

The menu popover contains only account switching, enabled limit data, a refresh timestamp,
and an Open App footer action. It has no brand/count/refresh header, column header, session
explanation, Add Account action, or Quit action. Account creation and usage refresh belong in
the main window.

Each account's Usage panel exposes Show usage in menu bar and an action to return to the
Settings default. This preference controls both that account's popover limits and the
active account's percentage beside the menu-bar icon. All accounts remain listed and
switchable. Disabled usage has no refresh action or placeholder; enabling display does
not activate an account. Preferences persist by account UUID and update the menu at once.
Main-window usage and its cache remain available regardless of this display preference.
If Codex returns only a weekly limit, show it without inventing a 5-hour value. The tray
percentage uses the 5-hour limit when available, otherwise the weekly limit.

Each account is a distinct compact card. Its identity row shows the account, provider and
workspace, active or attention state, and a dedicated Switch button when eligible. Active,
Switch, and Sign in controls share one compact ghost-button size. When menu
usage is enabled and cached, the card expands to show separate Weekly and 5 hour progress
rows with percentages and reset descriptions. A hidden or missing limit takes no space and
is never fabricated. The footer shows the newest cache refresh time on the left even when
usage display is disabled, and Open App on the right. The popover is 384 points wide, uses a
48-point footer, and scrolls at a 440-point maximum height. It has no automatic focus outline
unless the keyboard-focus indicator setting is enabled.

## 4. Visual system

Light mode retains the existing warm macOS surfaces. Dark mode uses neutral, darker
surfaces: rail `#141517`, canvas `#18191B`, panel `#202124`, stripe and raised surface
`#27282B`, secondary raised surface `#2F3034`, hover `#303238`, and selection `#393C43`.
Text remains `#F2F2F3`
with muted text no darker than `#B9BBC0`. Soft separators remain visible without turning
panels into outlined cards.

The menu popover must inherit the effective app appearance in every hosted or virtualized
row. Its dark list cannot fall back to light row colors. It opens without presentation
animation, uses three-point corners, and uses `#18191B` for its dark column/footer chrome
against the shared neutral row scale.

Compact section headers use one 40-point alignment row. A leading title, trailing count,
warning/copy action, error indicator, and progress indicator occupy explicit centered slots;
content changes must not move them vertically or horizontally.

Inter is the interface, reading, and display face. PT Mono is reserved for paths,
measurements, IDs, and other technical data. Both font families are bundled with their OFL
licenses and must load in production and Preview builds.

Account-list secondary text and menu cards identify the provider, such as Codex CLI, rather
than repeating verification language. Healthy identity badges use the provider name; only
states that need action add a separate state badge. The Add Account and Advanced Import
titlebars use one 48-point row for the title and edge-to-edge Close button. Step tabs are
28 points high and centered against the title text instead of filling the titlebar. Modal
content and actions use matching 16-point top and bottom spacing, and checkboxes align to the
same 16-point panel content edge as their headings and rows.

## 5. Verification contract

Automated tests use synthetic credentials and isolated homes. A UI change must pass the
focused Mac GUI contract, production and Preview model checks, System/Light/Dark snapshots,
and the full native gate before installation. Core or CLI changes additionally pass both
unprivileged read-only Linux Docker architectures. Public distribution still requires a
Developer ID Application signature and notarization.
