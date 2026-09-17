# Switch product specification

Status: Initial accepted specification
Revision: 2026-09-17

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
   Body translucency is adjustable from 0% to 50%, initially 25% (75% opacity),
   and applies to the entire content area and its page titlebar without fading text or
   controls. Reduce Transparency makes these surfaces opaque. The rail stays distinct.
2. **Data locations** — Codex home (`~/.codex`) and saved account vault
   (`~/.switch/codex`), each with a plain-language purpose and an explicit Reveal action.
3. **Menu bar defaults** — Show account usage, initially on. Accounts without an
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
1 month, or 1 year, initially 1 year. The selected range persists across app restarts.
Selecting an account only changes the displayed account; it must not activate credentials
or wait on file reads, queries, or repeated calendar aggregation. Build each displayed
calendar's days, weeks, and token maximum once per body update, rather than once per cell.
Sidebar hover has one bounded target and animates only its highlight, without animating
hitbox geometry or leaving previous items lit while the pointer crosses rows.
Cell intensity reflects the token count within the selected range, and a selected day shows
its date and exact token count. The Daily activity label is 20% larger than its prior 11-point
size. Returned Lifetime, Peak day, streak, and Longest turn facts align at the right of the
Ordinary usage and Authentication row rather than occupying another row below the limits.

Retain a compact durable daily summary separately from expiring quota snapshots. Merge
repeated authoritative account/day totals without double counting and preserve days omitted
from later responses. Retain per-project daily summaries from explicit local token events,
without assigning shared conversations to the currently selected account or retaining message
content. Incremental scans, app restarts, and deletion of old source conversations must not
erase or duplicate retained totals. Clearing rebuildable caches must preserve this ledger.
The ledger is an owner-private SQLite database at application support `activity/daily.sqlite`.
Account totals come from authoritative Codex account/day responses; newer values replace prior
values, including downward corrections and zero. Local project totals use UTC event days and
increases in cumulative token counters, never repeated last-turn counters. Thread IDs deduplicate
archived or copied transcripts. Unknown fork boundaries and reset or incomplete source records
retain known totals with an incomplete indication. Project totals remain separate from account
totals, and selected days identify their shared-home provenance. One background file monitor and
coalesced bounded worker scans maintain summaries independently of the visible page.

The menu popover contains only account switching, enabled limit data, a refresh timestamp,
and an Open App footer action. It has no brand/count/refresh header, column header, session
explanation, Add Account action, or Quit action. Account creation and usage refresh belong in
the main window.

Each account exposes a labeled **Show in Menubar** toggle immediately before Open Codex
in its action row. Both stateful actions use a single tick when false (Set as Default or
Menubar display off), and an outlined double tick with two complete checkmarks when true
(Using as default or Menubar display on). The icon reflects the current state, not the
action that clicking will perform. The Menubar toggle's accessible value
explains whether usage display is on or off. Its context menu offers Use Settings default.
Fit the double check's visible outline, including stroke clearance, rather than its empty
512-unit SVG canvas. At the ordinary 13-point icon size, give it a 17⅓-by-13-point area:
visible centerlines must occupy at least 15 points in width and nine points in height, with
round strokes about 1.2 points thick. Both checks have a complete short arm and long arm;
this supersedes the disconnected second check in the exact Ionicons source geometry.
Both ticks must remain distinguishable at actual size in light and dark appearances.
Single and double ticks use the same icon area so changing the Menubar preference does
not shift the other actions.
Identity's header retains Default and attention badges, without a redundant provider badge
or menu-bar toggle. There is no separate preference row in Usage.
This preference controls both that account's popover limits and its menu-bar entry.
With any account enabled, replace Switch's tray mark with **remaining** quota percentages
for the first four enabled accounts in the saved sidebar order. Show one 12-point monochrome
glyph per service, followed by all that service's selected percentages. Order services by
their first selected account and preserve sidebar order within each service. Changing the
default never changes this order. When an enabled account has no cached limit, show a dash, with its identity
and unavailable-limit state in the tooltip and accessible description; never invent a value.
Keep the Switch mark only when no account is enabled. All accounts remain listed and
switchable. Disabled usage has no refresh action or placeholder; enabling display does
not activate an account. Preferences persist by account UUID and update the menu at once.
Main-window usage and its cache remain available regardless of this display preference.
Accounts support drag-and-drop reordering, plus Move up and Move down context-menu actions.
Persist the order atomically in the existing private registry, shared by the app and CLI;
reopening preserves it, new accounts append, and deletion preserves remaining relative order.
Reordering never selects, activates, verifies, or changes credentials. Reject stale or foreign
account identifiers without changing the order; an unchanged drop performs no write.
If Codex returns only a weekly limit, show it without inventing a 5-hour value. The tray
percentage uses the 5-hour limit when available, otherwise the weekly limit, subtracting
the clamped used percentage from 100. The popover continues to show used percentages.
Package a sourced monochrome glyph catalog for current and future providers locally;
having artwork does not enable an unsupported provider or add any network work on menu open.

Each account is a distinct compact card. Its single 30-point identity row shows a truncated
account name with a full-name tooltip, a cached provider glyph instead of a status dot,
active or attention state, and a dedicated Switch
button when eligible. Provider and workspace remain in the accessible description. Active,
Switch, and Sign in controls share one compact 56-by-22-point size and five-point corners.
Switch uses a blue outlined button; Active is a disabled gray button rather
than a colored badge. When menu
usage is enabled and cached, the card expands to show separate Weekly and 5 hour progress
rows. Each row places the limit name above its percentage, followed by a horizontal progress
bar and a right-aligned reset description. Quota rows are 28 points high with six-point
vertical insets and four-point spacing. Account names are 11 points, quota labels nine,
and percentages 11. The whole popover, including cards and footer, is translucent over
one native macOS backdrop blur. Card tints stay translucent; text and icons remain opaque.
Use the existing native visual-effect wrapper and cached provider glyphs, without per-card
blur, software image filters, polling, or icon downloads on open. Reduce Transparency
uses an opaque fallback. The cards use a quiet tint, fine border,
and restrained hover change while preserving three-point corners. A hidden or missing limit
takes no space and is never fabricated. The footer shows the newest cache refresh time on the
left even when usage display is disabled, and Open App on the right. The popover is 344 points wide,
uses a compact 28-point footer with eight-point horizontal insets and a text-only ghost
Open App button with a subtle hover tint, and scrolls at the smaller of 900 points or 80% of the smallest attached
display's visible height. It has no automatic focus outline
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

Identity and Usage are the primary account sections. Their header tint is restrained;
secondary and settings headers use a lighter tint. Decorative header strokes use half the
previous opacity. Default and attention badges sit at the right of Identity's
header. Set as Default and Open remain labeled primary actions; Check, Copy, and Refresh use quiet
tooltip icon buttons. Healthy verification detail is not repeated under the identity.
Check account files uses a magnifying-glass icon. Set as Default uses a single tick;
the default account shows a double tick and Using as default. That action remains enabled
when idle to reapply the saved credential. Displayed filesystem paths copy their exact text
on click and show a brief local Copied confirmation without shifting layout. Copyable text
uses a pointing-hand cursor, middle truncation, and a full-path tooltip; accessible
names identify the copy action, and Preview must not mutate the real clipboard.
Body prose uses Inter rather than monospace. Disabled actions stay legible and every icon
action retains an accessible name, focus behavior, and its existing safety guards.

Deleting the default account automatically activates an eligible saved fallback before
deleting its saved credential. Prefer the currently selected other account, then the previous
selection, then the most recently used eligible account, then the first available account.
The deletion confirmation names the replacement. A failed activation preserves the account
being deleted. With no eligible fallback, the normal Delete account action remains disabled;
do not replace its label with a long instruction. Conversations and settings are preserved.

Close hover uses bright red `#FF453A` with a white glyph; Minimize hover uses bright yellow
`#FFD43B` with a dark glyph. Both remain square, and Minimize floats out of Close without
entering the title layout. Keep one continuous rail divider and immediate hover feedback.

Inter is the interface, reading, and display face. PT Mono is reserved for paths,
measurements, IDs, and other technical data. Both font families are bundled with their OFL
licenses and must load in production and Preview builds.

Dock and Spotlight use the approved pixel trace as a dark glyph on a light neutral tile,
with the existing generous padding, optical placement, shallow surface shade, and slight
top sheen. Both app appearance variants retain this light-tile treatment. Menu-bar artwork
remains the native monochrome template.

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
