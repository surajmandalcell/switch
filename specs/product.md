# Switch product specification

This document defines the current product model and user-visible contract. The ignored
local `goals.md` tracks active work, and `goals.archive.md` keeps old evidence. If older
milestone text conflicts with this document, this specification owns current behavior.

The app icon is the owner's selected red emergency-stop electrical switch on
an ivory tile. It appears in the standalone Dock and Spotlight and in the
MacPowerToys Switch launcher, window, and Dock identity. The original vector
mark remains the small menu-bar template.

## 1. Product model

Switch manages provider authentication snapshots. Codex CLI, Grok Build, Droid (Factory), and
Claude Code use the dedicated engines below. Every other provider uses the generic provider layer in
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

For Droid (Factory), the live home is `$FACTORY_HOME_OVERRIDE/.factory`, or `~/.factory` when
the variable is unset, the same rule droid and Factory.app use. Both read one login store there:
`auth.v2.loginkeychain`, or `auth.v2.file` plus `auth.v2.key` when the keyring is off. It is
encrypted with one fixed Keychain key that every Factory login reuses. Switching atomically
replaces only those auth files from an owner-private copy at
`~/.switch/droid/<account-uuid>/`. Switch first captures the outgoing files into the outgoing
account and honors droid's `auth.v2.write.lock`. Switch never reads the key or decrypts the
files. Sessions, settings, and history stay in the live home. droid reads the store on demand,
so new requests use the new account. When Factory.app or a droid process is running on the live
home, a switch first asks, and Cancel is the default. The existing login is imported as the
first account without a new sign-in. Add Account runs droid's interactive `/login` in Terminal
with a private temporary `FACTORY_HOME_OVERRIDE`, and runs only one Droid login at a time. A
Droid login needs an existing Factory login on this Mac, so the shared key already exists. While
Factory.app has work running, live tests use a separate test home through
`FACTORY_HOME_OVERRIDE` with the droid CLI, and they never touch `~/.factory`.

Droid identities stay opaque. The owner names each import or sign-in, for example "Droid 1".
Account-scoped sign-in confirms the target name before starting; Switch cannot detect a wrong login.
Only the active default refreshes live files through the guarded switch path. Other accounts refresh
only their saved copy. Droid has no verified non-interactive identity or limits command. An optional
Factory API key belongs to each Droid account and reuses the existing Factory usage provider.
The generic Factory API-key provider remains separate and keeps its own default.
The write lock is a nonempty directory published by rename, with a 0600 `owner.json`
containing a random token and process ID. Switch honors the `.reclaim` guard and never removes
another writer's lock. A process whose home cannot be proved requires confirmation too.

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
most every ten minutes per profile. Switch never spends a Claude refresh token. A pending
macOS privacy prompt for Switch blocks the CLI; Switch then shows an uncached Allow hint.

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

Existing-account "Sign in" binds the isolated login session to that account ID. Completion
must match the provider's saved identity before changing any account or credential. A mismatch
discards the isolated home and reports the signed-in and required identities. A match atomically
refreshes only that managed credential. Only an active default refreshes its live auth through
the existing switch path, with the same identity. Account-scoped sign-in never signals running
CLI processes. "Add account" keeps provider-scoped sign-in.

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

The sidebar and View menu list pages from the shortest name to the longest: Overview, Accounts,
Settings, Maintenance (cleanup, backup, recovery), Conversations (chat history). Command+, opens
Settings. Each page remembers its tab, selection, and scroll position. "When Switch opens" (Last
place, the default, or Overview) picks the page shown at launch. Settings groups, in order:
General (Open at Login, Minimize to menu bar, When Switch opens, Menu shortcut), Appearance
(System, Light, or Dark; Show percentage used; Reset times; Time format), Accounts (Show email
domains, off by default, so "ada@gmail.com" reads "ada"; Hide email addresses; Check provider
status; the Claude terminal setting), Menu bar, Notifications, Data locations, and Reset. The
items are:

1. **App behavior** — Open at Login and Minimize to menu bar. Open at Login is off by default
   and uses the macOS login-item service as its source of truth; a login launch starts quietly
   in the menu bar, an ordinary launch opens the window, and if macOS requires approval,
   Settings explains it and links to Login Items.
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
The time range is a native pop-up button. Expanded rows align to the leading edge at their
nesting level. Cleanup groups use clear headings, aligned counts and brief descriptions; keep
selection totals and Review together.

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
Code first, then every other provider alphabetically, with a search field. File-based
providers already signed in on this Mac (read off the main actor) show "Signed in on this Mac"
and sort after the built-ins. A usage row's context menu offers Hide, Show all, and Refresh;
hidden rows are per account and leave the detail page and menu card. Command-R refreshes. The
status item's context menu offers Open, Refresh Usage, Settings, and Quit. The Claude
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

Daily activity uses a GitHub-style calendar instead of a date table. Its header uses a native
segmented control: Today, Yesterday, Weekly, Monthly, and Yearly drive both the visible token
total and the activity range, initially Yearly. Other compact, mutually exclusive period
filters use segmented controls too. The selected range persists across app restarts.
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

The Codex account's popover row may add one compact token summary line for the configured
token period. Settings owns a segmented choice for Since reset, Today, Yesterday, Weekly,
Monthly, or Yearly; Since reset is the default. Since-reset totals use the weekly window start when the service returns a duration
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

Every account has a **Show in Menubar** checkmark item in its More menu (header and table
row), with Use Settings default; it controls both that account's popover row and its
menu-bar entry.
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

The popover's layout is in section 4. A hidden or missing limit takes no space and is never
fabricated. Refresh checks enabled accounts in saved order without activating an account or
closing the popover; it is disabled while running and keeps its space while showing progress.
The popover fits every row up to 80% of the visible height of its screen, then scrolls; one or
two accounts never collapse or clip.

## 4. Visual system

Switch follows the macOS Human Interface Guidelines, the owner's menu bar popover mockup, and
the owner's Overview concept (`docs/design/overview-concept.png`). The window stays close to the
concept and looks like macOS Sequoia 15 on every macOS version: no Liquid Glass, a translucent
sidebar, a light grey content background (dark grey in Dark Mode), white grouped cards with a
hairline border (a slightly lighter fill in Dark Mode), and Sequoia-style push buttons, menus, and
search field. Where the running macOS draws a newer glass style, Switch draws the Sequoia style
itself. System semantic colors and the user's accent color, in light and dark.

**Design gate:** lintapple (`packages/mac-gui/ui-lint`) checks the HTML reference of the window
(Overview plus the shared parts in their other states) and a mirror page exported from the real
SwiftUI layout of every window page. Both pass with zero findings in light
and dark before a UI change ships.

- **Type and color:** exactly five text roles, all macOS text styles, used the same way on
  every screen and in the popover: Title (Title 2 semibold, 17 pt, at most once per page, for
  the focused account name), Section (Headline, 13 pt bold, card and form section titles),
  Body (13 pt regular, every row label, value, and button), Secondary (Subheadline, 11 pt, in
  the secondary color, for providers, descriptions, and reset text), and Caption (10 pt, badges
  only). Numbers keep their role and add monospaced digits; only paths and IDs use the
  monospaced font. No other sizes or weights. Buttons and the Default state chip use Body.
  Remaining-quota bars are 6 pt capsules, green above 50% left, yellow from 20% to 50%, and red
  below 20%; the pace verdict uses the same colors; an unknown value shows an empty grey track.
  Show percentage used flips text and fill to the used share.
- **Geometry (points):** content margins 20, 12 between cards. A card has a 10 radius and a
  16 inset; its title row (Section title left, Secondary count or an accent "View … →" link
  right) is 44 tall. Every card spans the full content width, and its title, column headers,
  rows, and separators share the same 16 inset, so no header is wider than its body. Rows are
  36 tall with hairline separators. Push buttons are 28 tall in cards and 22 tall in table rows;
  icon buttons are square. A tile inside a card sits 6 in with a 4 radius, so corners stay
  concentric, and its text lines up with the card's 16 inset.
- **Window:** a translucent 220 pt sidebar under a 52 pt unified title bar (an empty system
  toolbar, so macOS places the traffic lights). The traffic lights sit at the system inset, not
  in the corner, and share one vertical center with the "Switch" name and the content's top
  row. Sidebar rows use filled SF Symbols in the order of section 2: Overview `house.fill`,
  Accounts `person.2.fill`, Settings `gearshape.fill`, Maintenance
  `wrench.and.screwdriver.fill`, Conversations `ellipsis.message.fill`. The content's top row
  holds, from the right edge in, a "Search accounts…" field 300 pt wide with a ⌘K hint
  (Command-K focuses it; it filters every account list), then a More menu and an Add button to
  its left, so the bar reads lightest to heaviest. Settings uses the full content width, so its
  cards end at the top bar's edge like every page.
- **Overview:** five cards, as in the concept. (1) Focused account: a 44 pt provider icon tile,
  the name (Title) with a chevron menu that picks another account, the provider (Secondary) with
  a green Active dot or an attention badge; a hairline divider, then the primary window (label,
  "N% left", bar, reset text). An action row: "Using as default" with a checkmark (prominent,
  inert) or Make Default (prominent), Open <tool>; on the right Copy, then a More menu (Show in
  Menubar, Refresh, Check, Delete), which comes last in cards and table rows. (2) Accounts: title with the count, then a table with
  columns Account (name, under its provider group label), Usage (bar and percent), Resets, and Actions
  (a green Default chip or a Switch button, plus a More menu); clicking a row focuses it.
  (3) Current limits of the focused account: up to three window tiles (label, "N% left", bar,
  reset) and "View all limits →". (4) Recent activity for the focused account's tool from local
  history: Today, Yesterday, and Last 30 days with tokens and an estimated cost, and "View full
  history →"; a tool without local history says so in one Secondary line. (5) Maintenance: a
  green check and "All systems operational" or a yellow warning naming pending backup work,
  plus Open Backup.
- **Accounts, Conversations, Maintenance, Settings:** the same cards, tables, rows, and buttons
  as the Overview. Account tables have no Provider column. Provider groups are light: a 24 pt
  label row (12 pt provider icon, "Codex CLI · 2" in Secondary) above each group and one
  hairline between groups at the 16 inset; account rows then drop their own provider icon.
  Maintenance shows Cleanup first, then Backup, in a 28 pt segmented control with 120 pt
  segments, left-aligned to the cards; segment icons use the label color, never the accent.
- **Stability and focus:** nothing shifts when content loads, rows are hovered or selected, or
  pages change. Scroll views hide the system indicators and draw a thin, always-visible scroll
  bar in a fixed gutter whose track matches the page, with no border. Clicks and selections
  never draw focus rings or outlines, including the sidebar and lists; keyboard focus is a
  subtle tint even with keyboard navigation (Full Keyboard Access) on. System focus rings show
  only with Increase Contrast on. Dark Mode controls are flat fills
  with no light rim. Every container has equal top and bottom inner padding; hover and
  selection highlights have even insets.
- **Menu bar popover:** native popover material, about 360 pt wide, compact, with no app name
  header. Accounts are grouped by service: one group header per service (its brand logo tile and
  name), then that service's accounts, each as its own row (one-line truncated name, checkmark
  for the default) with its usage lines under it. Account rows carry no logo and no service
  name. Show in Menubar uses the Settings default or an account override. Each account shows
  its service's reported windows, including unknown values; plan differences and an account's
  hidden-row override can reduce them. Each line aligns the window name, a 4 pt rounded bar,
  percentage, and reset in fixed columns. Bars everywhere (popover and window) fill with the
  provider's brand color and turn red from 90% used.
  Clicking an account reveals Switch and Open <tool> actions while keeping usage visible.
  The context menu offers Switch, Open <tool>, Refresh, and Copy name. Hover highlights have even
  insets. A compact footer holds Refresh and Settings icon buttons and Open Switch with Command-O.
- **Behavior kept:** displayed paths copy on click with a brief Copied confirmation (Preview
  never touches the real clipboard); every icon action has an accessible name and keyboard
  focus; Reduce Motion and Reduce Transparency follow the system; Preview data is synthetic.

Deleting the default account first activates an eligible saved fallback: the selected other
account, then the previous selection, then the most recently used, then the first available. The
confirmation names the replacement, and a failed activation keeps the account. With no eligible
fallback, Delete account stays disabled with its normal label. Conversations and settings stay.

Background reconciliation never disables the interface or republishes unchanged account,
history, and usage values. Secondary text identifies the provider (such as Codex CLI); only
states that need action add a badge. The Dock and Spotlight icon and the monochrome menu-bar
template are unchanged.

Add Account and Advanced Import are native sheets: a provider search and single-choice list
(double-click continues), then the provider's form or sign-in page, with standard Cancel and
Continue buttons and a small step indicator; every step keeps its buttons visible.

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
the lintapple design gate (section 4), and the full native gate before installation. Core or CLI changes additionally pass both
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
