# Switch product specification

Status: Initial accepted specification
Revision: 2026-09-20

This document defines the current product model and user-visible contract. The ignored
local `goals.md` tracks active work, and `goals.archive.md` keeps old evidence. If older
milestone text conflicts with this document, this specification owns current behavior.

## 1. Product model

Switch manages provider authentication snapshots. Codex CLI and Grok Build are enabled in
the current release. Claude Code, Gemini CLI, and Antigravity CLI may appear only in the Add
Account catalog as inert WIP choices.

For Codex, `~/.codex` is the one live home. Its configuration, instructions, skills,
plugins, conversations, databases, and other non-authentication state remain in place when
the account changes. Switching replaces only `~/.codex/auth.json`, atomically, from a saved
private credential after identity and digest checks. Existing Codex processes keep their
in-memory credentials; the selected account applies to new sessions.

Saved credentials are regular owner-private files at `~/.switch/codex/<account-uuid>.json`.
The UUID is the stable internal identity and paths never contain an email address. Switch's
registry, usage cache, transactions, backups, and recovery metadata live in its application
support directory. Raw authentication is never stored in SQLite.

For Grok Build, `~/.grok` (or `$GROK_HOME`) is the one live home. Switching atomically
replaces only its `auth.json`; configuration, rules, plugins, MCP credentials, and sessions
stay in place. Switch supports the official CLI's subscription OAuth entries (`oidc` and
first-party external OAuth), not `XAI_API_KEY`. Saved credentials are owner-private files at
`~/.switch/grok-build/<account-uuid>.json`. Add Account runs `grok login --oauth` with a
private temporary `GROK_HOME`. If the browser cannot reach the loopback callback, the sign-in
sheet accepts the authorization code or complete callback URL and sends it once to the waiting
official CLI without saving it. The official CLI hot-reloads `auth.json`, so an existing Grok
process may use the newly selected account on its next API call. Switch does not claim that
existing Grok sessions retain their earlier account.

Temporary or managed homes used for sign-in, verification, import, migration, or recovery
are implementation details. Legacy internal links may still be repaired for compatibility,
but the interface must not describe linked entries as part of the product's everyday model.

After a restart, checking a completed sign-in reads the private staged credential and uses
the same identity, digest, and transaction checks as an auth-only import. An unrelated
running Codex process must not block that check. If Switch no longer owns the sign-in
process, it retires the session metadata. Cancellation stops only a process Switch owns.
After a restart or refresh, remove retired staging homes once the home-scoped writer check
proves they are inactive; preserve active or unknown homes and any home needed by recovery.
Retired sessions do not reappear as pending or allow another import through their old ID.

Full imports, legacy settings repair, and recovery check writers for their affected homes,
including shared symlink targets. Attribute a Codex process through its held home-scoped
runtime lock, without reading its environment or credentials. An unrelated verified home
does not block the operation. Missing, inaccessible, or unrecognized ownership evidence
remains unknown and blocks destructive changes; unlocked stale runtime files are not writers.

## 2. Navigation and Settings

The rail and View menu use this order: Accounts, Backup, Chat History, Settings. Command+,
opens Settings. Settings contains only:

1. **App behavior** — Minimize to menu bar and the optional keyboard-focus indicator.
   Body translucency is adjustable from 0% to 50%, initially 25% (75% opacity),
   and applies to the entire content area and its page titlebar without fading text or
   controls. Reduce Transparency makes these surfaces opaque. The rail stays distinct.
2. **Data locations** — Codex home and vault (`~/.codex`, `~/.switch/codex`) plus
   Grok Build home and vault (`~/.grok`, `~/.switch/grok-build`), each with a
   plain-language purpose and an explicit Reveal action.
3. **Menu bar defaults** — Show account usage, initially on. Accounts without an
   explicit override follow this default. Changing it preserves explicit account choices.
4. Preview-only demo controls in Preview builds.

Settings never lists files as “Linked entries,” never implies that each account owns a
separate configuration or chat library, and never exposes internal managed-home topology.
An account-specific legacy repair may appear on that account only when action is required.

Cleanup is resumed on 2026-09-19. Replace the frozen prototype with a disclosure tree for
shared active/archived conversations grouped by project, account usage samples, and the shared
conversation index. Conversations are shared data and are never attributed to the selected account.
Provide date ranges, older-than shortcuts, all time, and a custom interval. Conversation dates mean
last updated; a selected conversation is removed as a whole. Untimestamped indexes support all time.
Preview exact selected items and bytes before one explicit confirmation. Conversation removal uses
recoverable private trash with a journal, restart recovery, Restore, and separately confirmed
permanent removal. Moving to trash does not claim freed disk space. Preserve compact activity totals
before removing a source; reject changed/unsafe files and active or unknown writers. Keep auth,
settings, account registry/defaults, backups, Codex databases, and the activity ledger protected.
Show linked or foreign-owned conversation files as protected entries; they never block selection
of safe files and cannot enter a removal review.
The time-range select uses a custom themed trigger and option list, with keyboard navigation,
selected-state feedback, and Escape dismissal. Expanded tree and account-cache checkbox rows
align to the leading edge at their nesting level; no disclosure content is centered.
Attach the compact option list to the trigger with a three-point gap, matching width, three-point
corners, and no native popover arrow or chrome. Outside clicks dismiss it. Cleanup groups use
clear headings, aligned counts and brief descriptions; keep selection totals and Review together.
Secondary gray buttons use stronger neutral fills and borders in both appearances without
changing the established hover behavior or fading foreground text.

Chat History loads messages in chronological pages as the reader scrolls, without a permanent
older-message cutoff. Filters and search operate across the complete conversation, retain their
persisted choices, and paginate their results. Copy shown exports exactly the loaded filtered
messages in order. Native rows remain virtual and parsing/search/rendering stays off the main
thread. Large message presentation may be compact, but original text remains available for copying.
The conversation header aligns its message count and recorded token total with the
conversation subtitle; omit a token value when the source has no reliable token counters.
In the sidebar, replace the count with a small spinner only while the first page loads;
keep counts visible during later refreshes. Sidebar counts include the word conversations.
Give each message role a filled surface with shared leading content alignment instead of
left border markers. Keep prompt, response, tool, and other roles distinct. Code blocks
wrap long lines so vertical scrolling over their text continues through the conversation.

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

Settings includes a persistent “Show percentage used” toggle, off by default. When off,
every quota percentage shows the amount left; when on, every quota percentage shows the
amount used. The selected meaning applies to main-window meters, Menubar cards, status-item
percentages, tooltips, and accessibility labels, and survives app restarts.

Daily activity uses a GitHub-style calendar instead of a date table. Its header uses one native
segmented control whose items touch: only the outside ends are rounded and faint dividers separate
the interior items. Today, Yesterday, Weekly, Monthly, and Yearly drive both the visible token total
and the activity range, initially Yearly. Use the same native grouped treatment for compact,
mutually exclusive period filters elsewhere; do not render a row of detached pills. The selected
range persists across app restarts.
Selecting an account only changes the displayed account; it must not activate credentials
or wait on file reads, queries, or repeated calendar aggregation. Build each displayed
calendar's days, weeks, and token maximum once per body update, rather than once per cell.
The full account pane must remain responsive during ordinary selection, including accounts
with a year of activity. Measure the real pane's layout and drawing, not only its calendar
or the selected-ID setter. Defer expensive display work when necessary without showing
the previous account's data under the new identity.
Dense month/year grids use one native Canvas with exact-day pointer selection, arrow keys,
and native accessibility actions for each date. Weekday labels align to a Sunday-first grid.
Routine account or hover redraws must not reload or reassign the Dock icon.
Automatic activity indexing runs at utility priority, leaving foreground interactions
ahead of long transcript scans. Accessible date actions share the drawn markers' bounds.
Sidebar hover has one bounded target and fades its highlight in and out within 120 ms,
without animating hitbox geometry or leaving previous items persistently lit.
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

Show retained token statistics for the selected account inside the existing Daily activity
section, not in a separate panel. The section header contains one grouped row of Today, Yesterday,
Weekly, Monthly, and Yearly filters. One filter is active at a time. A fixed-height summary line
shows only that period's total, with the exact token count in its tooltip and accessibility value;
async price availability must not move surrounding content. Rolling Weekly, Monthly, and Yearly
periods include the current UTC day and cover 7, 30, and 365 days. Do not add an account or provider
filter because the surrounding account view owns the statistic. Do not repeat a source label such
as Shared Codex home. Omit Daily activity until that account has retained history, then preserve
explicit zeroes. The TUI account screen uses the same periods and account-day data and renders its
filter as one contiguous group.

The Menubar account card includes one compact token summary without adding another row to its
geometry. Put the quota percentage on the same line as Session or Weekly. Reuse the existing detail
line for the configured token period at the left and reset countdown at the right. Settings owns a
native segmented choice for Since reset, Today, Yesterday, Weekly, Monthly, or Yearly; Since reset
is the default. Since-reset totals use the weekly window start when the service returns a duration
and reset time, and otherwise fall back to Weekly without inventing precision.

Show an API-equivalent comparison beside the selected token total when the shared Codex config has
a model with published pricing. Follow OpenUsage's pricing source pattern: prefer the public
LiteLLM model catalog, cache its raw response for 24 hours, and use a stale valid cache when offline.
The Codex account feed supplies aggregate tokens but not an input/output/cache breakdown, so never
present the comparison as billed cost. Label the visible value as an input-rate equivalent and put
the configured model plus cached-input, input, and output equivalents in help and accessibility
text. Keep tokens visible when pricing is unavailable.

Retained shared-home project totals continue to support history and cleanup but must not appear as
the selected account's token statistics. The menu popover remains focused on account switching,
enabled quota data, and the compact account token summary. Its scrollable body is followed by the
fixed refresh timestamp and refresh/Open
App actions. It has no separate token-statistics band, brand/count/refresh header, column header,
session explanation, Add Account action, or Quit action. Account creation belongs in the main
window.

Each Codex account exposes a labeled **Show in Menubar** toggle immediately before Open Codex
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

Each account is a distinct compact card. Its single 35-point identity row shows a truncated
account name with a full-name tooltip, a cached provider glyph instead of a status dot,
active or attention state, and a dedicated Switch
button when eligible. Provider and workspace remain in the accessible description. Active,
Switch, and Sign in controls share one compact 56-by-22-point size and three-point corners.
Switch uses an outline in the progress bar's accent color; Active is a disabled gray button rather
than a colored badge. When menu
usage is enabled and cached, the card expands to show Session followed by Weekly limits.
Each 40-point quota row places its name above a full-width four-point progress bar,
then its used percentage on the left and reset description on the right. Use 13-point
spacing between limits, four-point top and ten-point bottom usage insets. Account names
and quota labels are 11 points, used percentages ten, and bold reset descriptions nine.
Show reset time as a live countdown in days, hours, and minutes, such as
"Resets in 1 day 23h 59m", in both the Menubar and main account view.
The whole popover, including cards and footer, is translucent over
one native macOS backdrop blur. Card tints stay translucent; text and icons remain opaque.
Use the existing native visual-effect wrapper and cached provider glyphs, without per-card
blur, software image filters, polling, or icon downloads on open. Reduce Transparency
uses an opaque fallback. The Soft rectangles account panels use a uniform solid tint
and seven-point corners, without a header divider, outline, or active-state gradient.
A hidden or missing limit
takes no space and is never fabricated. The footer shows the newest cache refresh time on the
left even when usage display is disabled, and Open App on the right. A small refresh icon
immediately precedes the timestamp. It checks enabled supported accounts in saved sidebar order
using the existing saved-auth background checks, without activating an account or closing the
popover. Disable repeat refreshes while running and disable refresh when no supported account
has usage display enabled. Keep the icon's space fixed while showing progress.
The popover is 344 points wide,
uses a compact 29-point footer with ten-point horizontal insets and a text-only ghost
Open App button with a subtle hover tint. Its native host fits all account cards and the
footer, growing up to 80% of the visible height of the display containing its status-item
button. This display-specific rule supersedes the previous smallest-display cap. There is
no additional 900-point cap, and the list scrolls only when its contents exceed that
available height. Below that cap every account and quota row fits without a scrollbar;
measure the rendered scroll viewport and document, not just the requested popup size.
AppKit's intrinsic sizing must not collapse the scroll area or clip
quota rows for one or two accounts. It has no automatic focus outline
unless the keyboard-focus indicator setting is enabled.

## 4. Visual system

Light mode retains the existing warm macOS surfaces. Dark mode uses neutral, darker
surfaces: rail `#141517`, canvas `#18191B`, panel `#202124`, stripe and raised surface
`#27282B`, secondary raised surface `#2F3034`, hover `#303238`, and selection `#393C43`.
Text remains `#F2F2F3`
with muted text no darker than `#B9BBC0`. Soft separators remain visible without turning
panels into outlined cards.

The owner selects the Soft rectangles layout with preview 04 Ivory for light mode and
09 Espresso for dark mode, following the app's effective appearance. This supersedes
the earlier fixed-palette request. Use popup/card/button radii of 9/7/3 points.
The Menubar has its own palette, separate from the main window's colors:

| Role | Ivory | Espresso |
|---|---|---|
| Shell | `#F0ECE2` | `#292722` |
| Account panel | `#FFFDF6` | `#3B372F` |
| Text | `#323229` | `#F1E8D5` |
| Secondary text | `#6B665A` | `#C8BCA6` |
| Limit track | `#E0DED4` | `#625B4B` |
| Limit fill | `#4B706E` | `#B4C8DD` |
| Switch text and outline | `#4B706E` | `#B4C8DD` |
| Disabled Active control | `#E9E7DF` | `#504A3E` |
| Footer separator | `#DCD8CC` | `#534A3B` |

Use a 92% shell tint over the single native backdrop and 94% panel tints, with opaque
text/icons and fully opaque fallback surfaces when Reduce Transparency is enabled.
Appearance changes update all virtualized panels without altering their geometry.
Preserve compact multi-account switching, visible limits, the refresh timestamp, and
Open App. Keep the single native backdrop and reduced-transparency fallback, and open
without presentation animation. Preview data is illustrative and does not query or
change accounts. The review artifact is `tmp/index.html`; its radius inputs and slider
are review controls, not new app settings.

Compact section headers use one 40-point alignment row. A leading title, trailing count,
warning/copy action, error indicator, and progress indicator occupy explicit centered slots;
content changes must not move them vertically or horizontally.
In Chat History's Conversations header, warning and loading/error slots precede the
right-aligned conversation count. Use a mini spinner and reserve no status space after the count.

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
Primary button text and icons, including Using as default, remain fully opaque
regardless of body translucency. The main window has three-point rounded corners
with a transparent exterior; preserve its size, placement, controls, and native shadow.

Deleting the default account automatically activates an eligible saved fallback before
deleting its saved credential. Prefer the currently selected other account, then the previous
selection, then the most recently used eligible account, then the first available account.
The deletion confirmation names the replacement. A failed activation preserves the account
being deleted. With no eligible fallback, the normal Delete account action remains disabled;
do not replace its label with a long instruction. Conversations and settings are preserved.

Close hover uses bright red `#FF453A` with a white glyph; Minimize hover uses bright yellow
`#FFD43B` with a dark glyph. Both remain square, and Minimize floats out of Close without
entering the title layout. Keep one continuous rail divider. Enabled buttons, icon actions,
range selectors, and list rows use a visible, interruptible 120 ms hover fade in both directions.
Animate color or opacity only; hit areas remain fixed and decorative overlays do not intercept
pointer input. Disabled controls do not highlight, and Reduce Motion uses immediate feedback.
Moving between controls or returning after Command-Tab must not cycle through hover,
disabled, and normal colors. Background account reconciliation must not disable the
interface or publish unchanged account, history, and usage values.
Light and dark hover feedback must remain stable with body translucency enabled.
During a crossing, both the departed and entered controls must fade without repeated
brightness reversals or flashes beyond their normal and hovered colors in light mode.
Scope hover fades to the opacity of constant-color layers; do not animate the entire
control's adaptive colors, foreground, or layout when pointer ownership changes.
Show in Menubar uses the same normal button colors as Open Codex and Use & Open Codex;
its tick state communicates the saved choice without a separate blue surface.

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
titlebars use one 48-point row for the title and edge-to-edge Close button. Close has a
distinct opaque neutral surface, contrasting glyph, and bright red hover.
Step tabs are 28 points high and centered horizontally in the bottom action row,
alongside Continue, Check Now, or the current page's navigation actions. Keep their
center fixed independently of unequal left and right buttons. Modal
content and actions use matching 16-point top and bottom spacing, and checkboxes align to the
same 16-point panel content edge as their headings and rows.

## 5. Terminal distribution

The existing `ai-manager` executable owns the terminal interface and opens it when
run without arguments. The repository root provides `make tui` as the source checkout
entry point. Distribute the Apple Silicon macOS executable as the `@smdl/switch` npm
package, so npx opens the interface and a global install exposes `switch` and
the existing `ai-manager` alias.
The root README has a dedicated terminal getting-started section with all three paths.
The npm package contains the compiled executable and must not reimplement account logic
or require a Swift build after package installation.

The interactive terminal uses the approved **09 Amber Menu** structure: a compact
character-cell account list, one inverse selected row, selected-account limits, and
arrow-key navigation. It preserves every existing account operation.
It leaves foreground and background colors to the terminal and uses only native bold,
dim, and inverse ANSI attributes, avoiding appearance detection. Piped output and
`NO_COLOR` remain plain text. Show an animated loader immediately while the initial
account refresh runs, then clear it before drawing the menu. Cached limits are displayed
when present; the interface never manufactures missing usage.

On an attached terminal, navigation uses raw keyboard input: Up and Down move focus,
Right or Enter opens the focused account, Enter runs the focused action, and Left or
Escape returns. The interface must not display or require command-letter navigation.
Temporarily restore normal terminal input for free-text path entry and the launched Codex
process, and always restore it when the interface exits.
Raw keyboard mode must preserve the terminal's existing output processing so every rendered
line returns to column zero in Terminal, iTerm, and compatible emulators.

## 6. Verification contract

Automated tests use synthetic credentials and isolated homes. A UI change must pass the
focused Mac GUI contract, production and Preview model checks, System/Light/Dark snapshots,
and the full native gate before installation. Core or CLI changes additionally pass both
unprivileged read-only Linux Docker architectures. A public GitHub release may use an ad hoc
signature when Developer ID signing is unavailable. Keep end-user install copy concise and
do not add warning blocks about signing or Gatekeeper.
Build, validate, and upload Mac archives from the maintainer's local Mac, not GitHub Actions.
The README must identify the current Switch download accurately; older product releases
are not Switch.
Before installed-app GUI actions, compare the packaged and `/Applications/Switch.app`
executable SHA-256 values, verify the embedded revision against the committed build, and
check that the running process maps the installed binary's inode. A stale process or
checksum mismatch must be corrected before clicking; record this proof in the install receipt.
