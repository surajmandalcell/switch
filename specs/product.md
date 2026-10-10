# Switch product specification

This document defines the current product model and user-visible contract. The ignored
local `goals.md` tracks active work, and `goals.archive.md` keeps old evidence. If older
milestone text conflicts with this document, this specification owns current behavior.

The app icon is the owner's selected red emergency-stop electrical switch on
an ivory tile. It appears in the standalone Dock and Spotlight and in the
MacPowerToys Switch launcher, window, and Dock identity. The original vector
mark remains the small menu-bar template.

## 1. Product model

Switch manages provider authentication snapshots. Codex CLI, Grok Build, and Claude Code
use the dedicated engines below. Every other provider uses the generic provider layer in
section 1a.

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

Claude Code profiles use separate, stable `CLAUDE_CONFIG_DIR` paths. Claude Code owns their
credentials, including any macOS Keychain entries; Switch does not copy or parse them. A
Claude default selects the profile for launches through Switch and its host app, so separate
profiles can remain signed in at the same time. Every profile shares one history with
`~/.claude` through symlinks (projects, history.jsonl, settings.json, CLAUDE.md, commands,
agents, skills, plugins, and similar shared items); `.claude.json`, `.credentials.json`, and
per-account policy caches stay per profile. Existing profile data is backed up and merged
without overwriting before a link replaces it. The default is written to
`~/.switch/claude/active`. An opt-in shell integration (Settings) makes a plain `claude`
command use it; without it, a plain `claude` keeps its own login. Claude usage reads a
file-based access token read-only when one exists, otherwise the CLI's `/usage` panel, at
most every ten minutes per profile. Switch never spends a Claude refresh token.

## 1a. Generic providers

Switch includes every usage provider from OpenUsage and CodexBar that can work without the
macOS Keychain or browser cookie stores. Each provider is a `ProviderSpec` with one of two
credential styles:

- **Files**: the official CLI or app owns credential files, a JSON member of a shared file,
  or key/value rows of its database (for example `~/.gemini/oauth_creds.json`, the
  `opencode-go` member of OpenCode's auth.json, or Cursor's `cursorAuth/*` rows). Switching
  backs up the live bytes (newest ten per provider), saves the outgoing login into its own
  vault entry (capturing rotated tokens, and auto-saving an unsaved login), and atomically
  writes only the selected account's bytes. Conversations, settings, and every other file,
  member, or row stay in place. Sign-in runs the official command in Terminal against a
  private temporary home, then imports it; "Import current sign-in" saves the live login.
- **Secret**: API keys, access tokens, or a pasted Cookie header. Switching selects the
  default saved account.

Saved credentials live at `~/.switch/<provider>/<account-uuid>.json` (0600). The index and
backups live in application support `provider-accounts/`. A usage check for the live
account of a Files provider reads the live bytes and never spends a refresh token that the
CLI also holds; vault-only accounts may refresh, and the new tokens are saved. Refreshed live
bytes are written back only when the live file is unchanged.

Usage uses one normalized model: rate windows (used share, reset time, window length),
money (spend, limit, balance), short detail rows, plan, and identity. The first window drives
the menu-bar percentage. Missing values are omitted, never invented. Provider requests use
HTTPS (plain HTTP only for loopback, RFC 1918, and `.local` gateways) and never follow a
redirect to another host.

Dropped on purpose: hooks, the QuickJS plugin engine, browser cookie import, Keychain
reads, keepalive, adaptive refresh, agent sessions, widgets, iCloud sync, Sparkle,
telemetry, local HTTP API, proxy settings, and merge-icons mode, with the providers that need them.

Defaults are provider-scoped. Codex CLI and Grok Build each retain their own default account,
matching the credential in that provider's live home. Claude Code retains a separate default
for Switch-launched sessions. Switching one provider never changes another provider's default.
The TUI account list groups saved accounts by provider, preserves order within each group,
and shows the default state inside each group. Deleting a provider default may select a
replacement only from that same provider.

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

1. **App behavior** — Open at Login, Minimize to menu bar, and the optional
   keyboard-focus indicator. Open at Login is off by default and uses the macOS login-item
   service as its source of truth; a login launch starts quietly in the menu bar, an ordinary
   launch opens the window, and if macOS requires approval, Settings explains it and links to
   Login Items. Body translucency is adjustable from 0% to 50%, initially 25%, across the
   content area and page titlebar without fading text or controls; Reduce Transparency makes
   these surfaces opaque. The rail stays distinct.
   **Reset times** (Countdown, the default, or Exact time) and **Time format** (Auto, 12-hour,
   24-hour) set how every reset text reads, such as "Resets in 2h 5m" or "Resets 5:30 PM"
   ("tomorrow", a weekday, or a date when it is not today). Clicking any reset text switches the
   same choice everywhere; hovering shows the other format. Clicking a usage percentage such as
   "52% left" switches Show percentage used the same way. **Menu shortcut** records a global
   shortcut (Command, Option, or Control plus a key; Delete clears) that opens or closes the
   menu popover from anywhere; it is off by default.
   **Refresh when the menu opens** is off by default.
   **Reset settings** (own panel, behind a confirmation) returns every Settings choice, the
   per-account Menubar and hidden-row choices, and the shortcut to their defaults; accounts,
   saved sign-ins, window placement, and Open at Login stay.
2. **Data locations** — Codex home and vault (`~/.codex`, `~/.switch/codex`) plus
   Grok Build home and vault (`~/.grok`, `~/.switch/grok-build`), each with a
   plain-language purpose and an explicit Reveal action.
3. **Menu bar defaults** — Show account usage, initially on. Accounts without an
   explicit override follow this default. Changing it preserves explicit account choices.
4. **Notifications** — Almost Out (under 10% left), pace alerts (Cutting It Close, Will
   Run Out), Available again (a full window reset), and Sign in again (one alert per
   failure episode). All are off by default; turning one on asks for permission. A state
   seen at launch never alerts, and an alert counts only after delivery succeeds.
5. **Provider status** (in App behavior) — Check provider status, initially on. Status
   pages are polled at most every five minutes for providers with saved accounts; a
   yellow or red dot beside the provider marks an incident, and failures keep the last
   good value.
6. **Claude terminals** — Use the selected Claude account in terminals, initially off.
   It adds one marked line to `~/.zshrc` (backup kept) that sources Switch's `claude`
   shell function.
7. **Privacy** — Hide email addresses masks them everywhere as `a••••@example.com`.
8. Demo controls only in locally launched Preview builds. Production and installed builds
   must not compile or render them.

Settings never lists files as “Linked entries,” never implies that each account owns a
separate configuration or chat library, and never exposes internal managed-home topology.
An account-specific legacy repair may appear on that account only when action is required.

Cleanup is a disclosure tree for shared active/archived conversations grouped by project, account usage samples, and the shared
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
The time-range select is a custom themed trigger and option list (keyboard navigation, selected
state, Escape and outside-click dismissal), attached to the trigger with a three-point gap,
matching width, three-point corners, and no native popover chrome. Expanded rows align to the
leading edge at their nesting level. Cleanup groups use clear headings, aligned counts and brief
descriptions; keep selection totals and Review together. Secondary gray buttons use stronger
neutral fills and borders in both appearances, with the established hover behavior.

Chat History loads messages in chronological pages as the reader scrolls, with no permanent
older-message cutoff. Filters and search cover the complete conversation, keep their persisted
choices, and paginate results. Copy shown exports exactly the loaded filtered messages in order.
Native rows stay virtual and parsing, search, and rendering stay off the main thread; large
messages may be compact but keep their original text for copying. The conversation header aligns
its message count and token total with the subtitle, omitting the token value when the source has
no reliable counters. The sidebar shows a small spinner in place of the count only while the first
page loads, and counts include the word conversations. Each message role has a filled surface with
shared leading alignment, not left border markers; prompt, response, tool, and other roles stay
distinct. Code blocks wrap long lines so vertical scrolling continues through the conversation.

## 3. Usage presentation

Generic, Grok Build, and Claude Code accounts read usage through `readProviderUsage`. The app
caches the last good snapshot per account on disk, shows it at launch, refreshes every
five minutes with four checks at a time and a 60-second limit each, waits five minutes
after a failure, and keeps the last good value with an Outdated tag. Their detail page
shows every window as the standard meter with a reset countdown and the OpenUsage pace
verdict (blue ahead, yellow close, red running out, with an even-pace tick), then money
and short detail rows. Their menu cards show the first two windows, or one balance line
when the provider returns only money. Add Account lists Codex CLI, Grok Build, and Claude
Code first, then every other provider alphabetically, with a search field. When the page opens,
Switch reads (off the main actor, read-only) which file-based providers already have a login on
this Mac. Those rows show "Signed in on this Mac" and sort directly after the three built-ins.
Right-click a usage window row for Hide this row, Show all hidden rows, and Refresh usage; hidden
rows are stored per account, leave the detail page and menu card, and return with Show all.
Command-R (View > Refresh Usage, and in the popover) refreshes now. Right-clicking the status
item opens a menu with Open, Refresh Usage, Settings, and Quit. The Claude
account page also shows Claude Code activity for all profiles from the local transcripts,
priced as an API-equivalent estimate.

A provider with a daily series (30 days, or its native span) returns a chart: id, title, unit
(USD, tokens, requests, credits, or a currency code), and dated points. The detail page draws one
72-point bar chart each below the windows, with the title and the total (or the hovered or
arrow-key-focused day and its exact value) in the header row and a VoiceOver summary such as
"30 days, total $12.40, peak $2.10 on Oct 3". The Claude Code activity panel charts its 30-day
cost the same way. Menu cards show no charts. `switch usage --json` adds
`charts` (schema `switch.limits.v1`, additive) and the CLI and TUI draw one ▁▂▃▄▅▆▇█ line each.
A window may report more than 100 percent used (overage): text shows the real percent
("130% used", or "0% left"), and every bar fill is clamped to its track. Sub-cent money shows up
to four decimals ("$0.0042").

Usage refresh reads the selected saved credential in a disposable private home and never
activates that account. The main Usage panel shows returned rate-limit windows and returned
statistics. Optional fields are conditional:

- Omit a missing plan, credits value, spend-control value, activity statistic, secondary
  window, and daily-activity section.
- Render a value such as zero, `false`, `None`, or `Available` when the service explicitly
  returned it; absence alone removes the row.
- Codex plan names: `prolite` Pro 100, `pro` Pro 200, `promax` Pro 500,
  `self_serve_business_prolite` Business Premium; any other id keeps its capitalized text.
- Name each Codex window by its duration (300 minutes Session, 10 080 Weekly), never by slot.
  Order two windows shorter first; a lone weekly window takes the primary slot, also for the
  menu-bar percentage. Title a model bucket by its limit name, and "Spark" for GPT-5.3-Codex-Spark.
  Codex meters use the generic pace tick, colors, and tooltip.
- Show credits as dollars plus floored credits (4 cents each), such as `$31.84 · 796 credits`.
- After the app-server read, Switch also calls `wham/usage` and `wham/rate-limit-reset-credits`
  with the private copy's ChatGPT access token and account id. It never refreshes the token: an
  expired token skips these extras. They add a "Reset credits: N" fact (soonest expiry, every
  expiry in its tooltip), model buckets the app-server did not list, a credits fact when no
  bucket has one, and a "Monthly credits" window from `individual_limit` (root, `rate_limit`, or
  `spend_control`). Code review percent, workspace `remaining_balance`, and the
  suspicious-reset guard are not shown.
- Keep actionable core states: “Usage has not been checked,” a refresh error, or the absence
  of all rate-limit windows.
- Never manufacture a value from transcripts and never combine stale usage with Needs
  sign-in.

Refresh every saved Codex account at launch and on a fixed three-minute cadence while the app
runs. Use one cache-backed model for the main window and menu bar, so both update from the same
completed refresh. The cadence does not depend on cache age or opening the menu bar; manual
refresh remains immediate, and a failed account waits five minutes before another automatic
attempt.

Settings includes a persistent “Show percentage used” toggle, off by default. When off,
every quota percentage shows the amount left; when on, every quota percentage shows the
amount used. The selected meaning applies to main-window meters, Menubar cards, status-item
percentages, tooltips, and accessibility labels, and survives app restarts.

Daily activity uses a GitHub-style calendar instead of a date table. Its header uses one themed
grouped control whose items touch: only the outside ends are rounded and faint dividers separate
the interior items. Today, Yesterday, Weekly, Monthly, and Yearly drive both the visible token total
and the activity range, initially Yearly. Use the same custom grouped treatment for compact,
mutually exclusive period filters elsewhere, including project colors and hover, focus, selected,
pressed, and disabled states; do not render a row of native controls or detached pills. The selected
range persists across app restarts.
Selecting an account only changes the displayed account; it must not activate credentials
or wait on file reads, queries, or repeated calendar aggregation. Build each calendar's
days, weeks, and token maximum once per body update, not once per cell. The full pane stays
responsive, including accounts with a year of activity; measure the real pane's layout and
drawing. Defer expensive display work without showing the previous account's data.
Dense month/year grids use one native Canvas with exact-day pointer selection, arrow keys,
and native accessibility actions for each date. Weekday labels align to a Sunday-first grid.
Routine account or hover redraws must not reload or reassign the Dock icon.
Automatic activity indexing runs at utility priority, leaving foreground interactions
ahead of long transcript scans. Accessible date actions share the drawn markers' bounds.
Cell intensity reflects the token count within the selected range, and a selected day shows
its date and exact token count. Returned Lifetime, Peak day, streak, and Longest turn facts align at the right of the
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
The monitor ignores shared-home writes outside active conversations, archived conversations, and
thread metadata. It coalesces bursts before it refreshes. An append-only JSONL change parses only
the verified appended bytes after the first complete scan; replacement, truncation, or an unsafe
record boundary falls back to a complete parse. Thread metadata is read and applied only when the
database or its write-ahead files change. An unchanged hidden app performs no transcript scan.

Show retained token statistics for the selected account inside the Daily activity section, not
a separate panel. A fixed-height summary line shows only the selected period's total, with the
exact count in its tooltip and accessibility value; async price availability must not move
surrounding content. Rolling Weekly, Monthly, and Yearly periods include the current UTC day and
cover 7, 30, and 365 days. Add no account or provider filter and no source label such as Shared
Codex home. Omit Daily activity until the account has retained history, then keep explicit
zeroes. The TUI account screen uses the same periods and data as one contiguous filter group.

The Menubar account card includes one compact token summary without adding another row to its
geometry. Put the quota percentage on the same line as Session or Weekly. Reuse the existing detail
line for the configured token period at the left and reset countdown at the right. Settings owns a
themed grouped choice for Since reset, Today, Yesterday, Weekly, Monthly, or Yearly; Since reset
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
Fit the double check's visible outline, not its empty 512-unit SVG canvas: at the 13-point
icon size, a 17⅓-by-13-point area whose centerlines span at least 15 by nine points, with
round strokes about 1.2 points thick and two complete checks (short and long arm each).
Both ticks stay distinguishable in light and dark. Single and double ticks share one icon
area so the Menubar preference does not shift the other actions.
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
button. The list scrolls only when its contents exceed that height. Below that cap every account and quota row fits without a scrollbar;
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
09 Espresso for dark mode, following the app's effective appearance. Use popup/card/button
radii of 9/7/3 points.
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
change accounts.

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

Deleting the default account first activates an eligible saved fallback: the selected other
account, then the previous selection, then the most recently used, then the first available. The
confirmation names the replacement, and a failed activation keeps the account. With no eligible
fallback, Delete account stays disabled with its normal label. Conversations and settings stay.

Close hover uses bright red `#FF453A` with a white glyph; Minimize hover uses bright yellow
`#FFD43B` with a dark glyph. Both remain square, and Minimize floats out of Close without
entering the title layout. Keep one continuous rail divider. Enabled buttons, icon actions,
range selectors, and list rows use a visible, interruptible 120 ms hover fade in both directions.
Animate color or opacity only; hit areas remain fixed and decorative overlays do not intercept
pointer input. Disabled controls do not highlight, and Reduce Motion uses immediate feedback.
Moving between controls or returning after Command-Tab must not cycle through hover,
disabled, and normal colors, and background reconciliation must not disable the interface or
publish unchanged account, history, and usage values. Hover feedback stays stable in light and
dark with body translucency on: the departed and entered controls both fade, with no brightness
reversals or flashes beyond their normal and hovered colors. Scope fades to the opacity of
constant-color layers; never animate a control's adaptive colors, foreground, or layout.
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
distinct opaque neutral surface, contrasting glyph, and bright red hover. Add Account
provider rows are single-choice buttons, not checkboxes. Clicking selects a provider,
double-clicking an enabled provider selects it and continues, and the separate Continue
action preserves the keyboard and assistive-technology path. Every Add Account step keeps
its titlebar and footer fully visible inside the modal.
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
The root README has a terminal getting-started section with all three paths. The npm package
holds the compiled executable, with no reimplemented account logic and no Swift build step.

The interactive terminal uses the approved **09 Amber Menu** structure: a compact
character-cell account list grouped by provider, one inverse selected row, selected-account
limits, and arrow-key navigation. Each action starts with a compact semantic glyph while retaining
its full text label. The TUI exposes account deletion with an explicit confirmation and preserves
every existing account operation.
It leaves foreground and background colors to the terminal and uses only native bold,
dim, and inverse ANSI attributes, avoiding appearance detection. Piped output and
`NO_COLOR` remain plain text. Show an animated loader immediately while the initial
account refresh runs, then clear it before drawing the menu. Cached limits are displayed
when present; the interface never manufactures missing usage.

On an attached terminal, navigation uses raw keyboard input: Up and Down move focus,
Right or Enter opens the focused account, Enter runs the focused action, and Left or
Escape returns; no command-letter navigation is shown or required. Normal input returns
for free-text path entry and the launched Codex process, and always on exit. Raw mode keeps the
terminal's output processing so every line returns to column zero in Terminal, iTerm, and
compatible emulators.

## 6. Verification contract

Automated tests use synthetic credentials and isolated homes. A UI change must pass the
focused Mac GUI contract, production and Preview model checks, System/Light/Dark snapshots,
and the full native gate before installation. Core or CLI changes additionally pass both
unprivileged read-only Linux Docker architectures. A public GitHub release may use an ad hoc
signature when Developer ID signing is unavailable. Keep end-user install copy concise and
do not add warning blocks about signing or Gatekeeper.
Build, validate, and upload Mac archives from the maintainer's local Mac, not GitHub Actions.
The README identifies the current Switch download accurately (older product releases are not
Switch) and leads with provider-neutral switching; provider-specific paths, session behavior,
and limits live in concise provider notes, not in a Codex-centered product model.
Before installed-app GUI actions, compare the packaged and `/Applications/Switch.app`
executable SHA-256 values, verify the embedded revision against the committed build, and
check that the running process maps the installed binary's inode. A stale process or
checksum mismatch must be corrected before clicking; record this proof in the install receipt.
