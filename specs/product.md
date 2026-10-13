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
Account-scoped sign-in confirms the target name before starting. Switch runs `droid doctor --auth --json`
with `FACTORY_HOME_OVERRIDE` and matching `FACTORY_DISABLE_KEYRING` on the login's own home (the
sign-in staging home, or the live home on import, with Factory.app's bundled droid when present),
never on a copy: a refresh there could spend a rotating refresh token and sign Factory.app out.
The passing `auth.verify` result supplies a masked email hint, shown beside the account name.
Different saved and new hints reject re-sign-in and discard staging without changing the account.
Equal masks can belong to different people, so the name confirmation remains required.
Add Account warns before adding a mask that matches an existing Droid account.
Failed or unknown doctor output falls back to named accounts and reports that limit.
Only the active default refreshes live files through the guarded switch path. Other accounts refresh
only their saved copy. Droid has no verified non-interactive limits command. An optional
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
  On launch and on every refresh, Switch also imports, once, each live login of a provider that
  supports "Import current sign-in" (for example Droid and OpenCode Go) when no saved account
  has the same identity; when identity cannot be told apart (equal Droid masks), it skips the
  import. The imported account becomes the provider's default, because the live files belong
  to it. An account the user deleted is remembered and never imported again. An
  auto-imported account shows a small "i" icon after its name whose tooltip says it was added
  from the login on this Mac; there is no other label. The same pass imports each z.ai
  coding-plan API key that the Z Code app saved in ~/.zcode/v2/credentials.json as a z.ai
  account named after its plan ("Z Code individual plan"). Switch decrypts it the way Z Code
  does (AES-GCM, key from the user name and home folder), never through the Keychain, and
  skips the file when it cannot decrypt it.
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
Settings. Switch remembers every choice across restarts: page, tab, each page's selected account,
scroll position, filters, chart period and grouping, cleanup source and range, backup source and
destination, the selected conversation, and expanded popover rows. "When Switch opens" (Last
place, the default, or Overview) picks the page shown at launch. Settings groups, in order:
General (Open at Login, Minimize to menu bar, When Switch opens, Menu shortcut), Appearance
(System, Light, or Dark; Show percentage used; Reset times; Time format), Accounts (Show full
email addresses, off by default, so "ada@gmail.com" reads "ada@gmail" with the top-level domain
dropped, and "ada@mail.example.co.uk" reads "ada@mail.example"; Hide email addresses; Check provider
status; the Claude terminal setting), Menu bar, Notifications, Data locations, and Reset. The
items are:

1. **App behavior** — Open at Login (off by default, backed by the macOS login-item service;
   a login launch starts quietly in the menu bar, and needed approval links to Login Items) and
   Minimize to menu bar.
   **Reset times** (Countdown, the default, or Exact time) and **Time format** (Auto, 12-hour,
   24-hour) set how every reset text reads, such as "Resets in 2h 5m" or "Resets 5:30 PM"
   ("tomorrow", a weekday, or a date when it is not today). Clicking any reset text switches the
   same choice everywhere; hovering shows the other format. Clicking a usage percentage such as
   "52% left" switches Show percentage used the same way. **Menu shortcut** records a global
   shortcut (Command, Option, or Control plus a key; Delete clears) that opens or closes the
   menu popover from anywhere; it is off by default.
   **Refresh when the menu opens** is off by default.
   **Reset settings** (own panel, confirmed) resets every Settings choice, per-account Menubar
   and hidden rows, and the shortcut; accounts, sign-ins, placement, and Open at Login stay.
2. **Data locations** — Codex and Grok Build homes and vaults (`~/.codex`, `~/.switch/codex`,
   `~/.grok`, `~/.switch/grok-build`), each with its purpose and a Reveal action.
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
8. Demo controls only in locally launched Preview builds; Preview data covers every service the
   owner uses, Droid included. Production and installed builds
   must not compile or render them.

Settings never lists files as "Linked entries," implies per-account chat libraries, or exposes
managed-home topology. A legacy repair appears on its account only when action is required.

Maintenance's source picker (searchable, built like the account picker) lists one entry per
tool home that accounts share, such as "Codex CLI · 3 accounts", and one per account where each
account has its own home, such as a Claude Code profile. Cleanup and Backup act on that source.
Cleanup is a disclosure tree of the source's known clutter by category, with real sizes: active and
archived conversations by project, logs, caches, debug and temp files, file history, shell
snapshots, usage samples, and the conversation index. Categories follow established cleanup
tools for each AI tool. Conversations are shared data and are never attributed to the selected account.
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

Backup keeps versioned snapshots of the source's chosen files and folders (presets per source
plus custom items) in a destination folder the owner picks. The first snapshot copies
everything; later ones copy only changed files and hard-link unchanged ones, so each snapshot is
complete alone. A snapshot is written to a temporary folder with a manifest (path, size, modified
time, SHA-256) and renamed when complete. Options: Back Up Now, a schedule (off, daily, weekly),
snapshots to keep, and Restore of a whole snapshot or chosen items, either in place after a safety
snapshot of the current files, or to another folder. Login files are excluded unless the owner
includes them per backup set. Backup never deletes source data; pruning removes only Switch's own
snapshots. A missing destination, such as an unplugged drive, waits and says so.

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
Nothing clips or overlaps: each message header (role, model, date) keeps its own line, and
responses and code blocks always show their full height.

## 3. Usage presentation

Generic, Grok Build, and Claude Code accounts read usage through `readProviderUsage`. The app
caches the last good snapshot per account on disk, shows it at launch, refreshes every
five minutes with four checks at a time and a 60-second limit each, waits five minutes
after a failure, and keeps the last good value with an Outdated tag. Their detail page
shows every window as the standard meter with a reset countdown and the OpenUsage pace
verdict (blue ahead, yellow close, red running out, with an even-pace tick), then money
and short detail rows. Their menu cards show the first two windows (all when expanded), or one
balance line when the provider returns only money. Add Account lists Codex CLI, Grok Build, and Claude
Code first, then every other provider alphabetically, with a search field. File-based
providers already signed in on this Mac (read off the main actor) show "Signed in on this Mac"
and sort after the built-ins. A usage row's context menu offers Hide, Show all, and Refresh;
hidden rows are per account and leave the detail page and menu card. Command-R refreshes. The
status item's context menu offers Open, Refresh Usage, Settings, and Quit. The Claude
account page also shows Claude Code activity for all profiles from the local transcripts,
priced as an API-equivalent estimate.

A provider with a daily series (30 days or its native span) returns a chart: id, title, unit (USD,
tokens, requests, credits, or a currency), and dated points. The detail page draws a 72-point bar
chart per series under the windows, with the title and total (or the hovered or focused day's
value) in its header and a VoiceOver summary ("30 days, total $12.40, peak $2.10 on Oct 3"); the
Claude Code panel charts 30-day cost the same way. Menu cards show no charts. `switch usage
--json` adds `charts` (`switch.limits.v1`); the CLI and TUI draw one ▁▂▃▄▅▆▇█ line each. Overage
shows the real percent ("130% used", "0% left") with bar fills clamped. Sub-cent money shows up
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
- After the app-server read, Switch calls `wham/usage` and `wham/rate-limit-reset-credits` with
  the private copy's access token and account id, never refreshing it (expired skips them). They
  add "Reset credits: N" (soonest expiry; all in its tooltip), unlisted model buckets, a credits
  fact when no bucket has one, and "Monthly credits" from `individual_limit` (root, `rate_limit`,
  or `spend_control`). Code review percent, `remaining_balance`, and the reset guard stay hidden.
- Keep actionable states: "Usage has not been checked," a refresh error, or no windows at all.
- Never manufacture a value from transcripts or combine stale usage with Needs sign-in.

Refresh every saved Codex account at launch and on a fixed three-minute cadence while the app
runs. Use one cache-backed model for the main window and menu bar, so both update from the same
completed refresh. The cadence does not depend on cache age or opening the menu bar; manual
refresh remains immediate, and a failed account waits five minutes before another automatic
attempt.

Settings has a persistent “Show percentage used” toggle, off by default: off shows the amount
left, on shows the amount used, in every meter, popover row, tray percentage, tooltip, and
accessibility label.

Daily activity is a GitHub-style calendar. A segmented control (Today, Yesterday, Weekly,
Monthly, Yearly; initially Yearly, remembered) drives the token total and the range. Selecting
an account changes only the display: no credential activation and no waiting on reads or
aggregation; the pane stays responsive with a year of activity and never shows the previous
account's data. Dense grids use one Canvas with exact-day pointer
selection, arrow keys, and per-date accessibility actions on the markers' bounds; weekday labels
follow a Sunday-first grid. Redraws never reload the Dock icon. Indexing runs at utility priority.
Cell intensity follows the selected range; a selected day shows its date and exact tokens.
Lifetime, Peak day, streak, and Longest turn sit at the right of the Ordinary usage row.

Keep a durable daily ledger, apart from expiring quota snapshots, in the owner-private SQLite
`activity/daily.sqlite`. Account/day totals come from authoritative Codex responses: newer values
replace older ones (downward and zero too), and omitted days stay. Project/day totals come from
local token events: UTC days, increases of cumulative counters (never repeated last-turn
counters), thread IDs to drop archived or copied duplicates, and an incomplete flag for unknown
forks or reset records. They never attach shared conversations to the selected account, keep no
message content, stay apart from account totals, and record shared-home provenance per day.
Incremental scans, restarts, source deletion, and cache clearing never erase or duplicate totals.
One background monitor watches only active and archived conversations and thread metadata,
coalesces bursts, parses only verified appended JSONL bytes after the first full scan (a
replacement, truncation, or unsafe boundary forces a full parse), and reads thread metadata only
when its database or WAL changes. A hidden app with no changes scans nothing.

The selected account's retained token statistics live inside Daily activity: one fixed-height
line with the period total (exact count in tooltip and accessibility value); late prices never
move content. Weekly, Monthly, and Yearly roll over 7, 30, and 365 days including today (UTC).
No account or provider filter and no source label. Omit Daily activity until history exists, then
keep explicit zeroes. The TUI account screen uses the same periods and data.

The Codex popover row may add one token summary line for the period chosen in Settings (Since
reset, the default, Today, Yesterday, Weekly, Monthly, Yearly). Since reset starts at the weekly
window start when the service returns duration and reset time, else falls back to Weekly.

Beside the token total, show an API-equivalent value when the shared Codex config's model has
published pricing (LiteLLM's public catalog, cached 24 hours). Label it an input-rate equivalent,
never billed cost; help text shows the model and the cached-input, input, and output values.

Shared-home project totals serve history and cleanup, never the selected account's statistics.
The popover body scrolls above a fixed footer (section 4). It has no token band, brand header,
column header, session explanation, or Add Account. A "0 tokens since reset" line is hidden.

Each account's More menu has a **Show in Menubar** checkmark (with Use Settings default) that
controls its popover row and menu-bar entry. With any account enabled, the tray shows
**remaining** percentages for the first four enabled accounts in saved order: one 12-point
monochrome glyph per service, then that service's percentages, services ordered by their first
account. Changing the default never reorders. An account with no limit to show (signed out, or
none cached) is left out and the next enabled account takes its place; the tooltip names it.
With none to show, the Switch mark stays. Disabled usage has
no refresh or placeholder; enabling never activates an account. Choices persist by account UUID
and apply at once; main-window usage ignores them.
Accounts support drag-and-drop reordering, plus Move up and Move down context-menu actions.
Persist the order atomically in the existing private registry, shared by the app and CLI;
reopening preserves it, new accounts append, and deletion preserves remaining relative order.
Reordering never selects, activates, or changes credentials. Stale or foreign IDs change
nothing; an unchanged drop writes nothing.
If Codex returns only a weekly limit, show it without inventing a 5-hour value. The tray
percentage uses the 5-hour limit when available, otherwise the weekly limit, subtracting
the clamped used percentage from 100. The popover continues to show used percentages.
Bundle a monochrome glyph per provider; a glyph never enables a provider or adds network work.

The popover's layout is in section 4. A hidden or missing limit takes no space and is never
fabricated. Refresh checks enabled accounts in saved order without activating an account or
closing the popover; it is disabled while running and keeps its space while showing progress.
The popover fits every row up to 80% of the visible height of its screen, then scrolls; one or
two accounts never collapse or clip.

## 4. Visual system

Follow macOS HIG, the owner's popover mockup, and Overview concept (`docs/design/overview-concept.png`).
Keep the concept's Sequoia 15 style on every macOS version; draw it when the OS supplies glass.
No Liquid Glass. Use a translucent sidebar, light grey content (dark grey in Dark Mode), white
grouped cards with hairline borders (slightly lighter fills in Dark Mode), and Sequoia push
buttons, menus, and search. Use semantic colors and the user's accent in both appearances.

**Design gate:** lintapple (`packages/mac-gui/ui-lint`) checks the HTML reference (Overview and
shared-part states) and a measured SwiftUI mirror of every page. Both must have zero findings
in light and dark before a UI change ships.

- **Type and color:** five macOS roles, consistent across screens and popover: Title (Title 2,
  semibold, 17 pt, focused account name, once per page); Section (Headline, bold, 13 pt, card/form
  titles); Body (regular, 13 pt, row labels, values, buttons, Default marker); Secondary (Subheadline,
  11 pt, secondary color, providers/descriptions/resets); Caption (10 pt, badges). No other sizes
  or weights. Numbers add monospaced digits; only paths and IDs use a monospaced font.
  Remaining-quota bars are 6 pt capsules: green above 50% left, yellow at 20-50%, red below 20%.
  Pace uses the same colors; unknown values show an empty grey track. Show percentage used flips
  text and fill to the used share.
- **Geometry (points):** content margins 20, 12 between cards. A card has a 10 radius and a
  16 inset; its title row (Section title left, Secondary count or an accent "View … →" link
  right) is 44 tall. Every card spans the full content width, and its title, column headers,
  rows, and separators share the same 16 inset, so no header is wider than its body. Rows are
  36 tall with hairline separators. Push buttons are 28 tall in cards and 22 tall in table rows;
  icon buttons are square. Tiles inside a card (for example Current limits) follow the card's
  16 inset: the first tile starts at 16, the last ends 16 from the right edge, tiles sit 12
  apart with a 6 radius, and the card keeps 16 below the tiles.
- **Window:** translucent 220 pt sidebar, 52 pt unified title bar, empty system toolbar.
  The content is always 1200 pt wide; only the height resizes, from 800 pt up, and a new
  window opens 900 pt tall (less when the screen is shorter). The green button zooms to the
  screen's full height at the same width; there is no full screen. Traffic lights use the
  system inset and share a vertical center with "Switch" and the top row.
  Sidebar filled SF Symbols follow section 2: Overview `house.fill`, Accounts `person.2.fill`,
  Settings `gearshape.fill`, Maintenance `wrench.and.screwdriver.fill`, Conversations
  `ellipsis.message.fill`. The top row reads Add, More, then "Search accounts…" at the right edge,
  following the lightest-to-heaviest rule. Search is 300 pt wide, filters every account list,
  and shows ⌘K; Command-K focuses it. Settings cards span the full content width and end at the
  top bar's edge, like every page.
- **Overview:** a usage dashboard. Account switching lives only on Accounts, so Overview has no
  focused-account card and no account table. A Week/Month period control and an Accounts/Models/
  Projects grouping control (both remembered) drive the cards: (1) totals (tokens, estimated
  cost, active accounts, busiest day) with rolling digits; (2) a streamgraph of daily tokens per
  group; (3) a one-year activity heatmap across all accounts; (4) Trends, a ridgeline of daily
  usage per group, each ridge scaled to its own peak, filling a fixed-height card; (5) a waffle
  chart of each group's share; (6) Maintenance: recent backups (time, source, size, state) and
  Open Backup, or a prompt to set up a backup. Charts follow uiarc.dev's ridgeline, activity
  heatmap, waffle chart, and streamgraph, with their draw-in animations, hover values, a faint
  date axis, and one stable palette. Groups past six fold into "Other"; account grouping leaves
  out history no account owns. Data comes from local history and the activity ledger, computed
  off the main actor; a group without data shows an explained empty state in the same space.
- **Accounts:** the account table, then the focused account card for the selected row (44 pt
  icon tile, name with no picker, provider with an Active dot or badge, primary window, actions:
  "Using as default" or Make Default, Open <tool>, Copy, More). The card's right side keeps its
  space: an account without usage shows its bars disabled with "Unavailable", and its primary
  button reads "Sign in again". The table has no column header and no Provider column. Each
  provider group starts with a 32 pt header row: a 16 pt brand tile, the provider name in
  semibold, and the count as plain secondary text ("×2"). The card header shows no account
  total. Its accounts sit 24 pt in, under the provider name, and a thin
  guide line runs from the tile down to an elbow at each account, like a Finder outline. Groups
  are 6 pt apart with no zebra fill. Row separators start at the indent and stay lighter than
  card borders. The usage column holds the bar and "83% · 6d 19h" (percent, then reset time);
  there is no reset column. A row without usage says why in that column ("Sign in to see
  usage"), so the reason replaces the empty bar and dashes. The default account is marked
  with a disabled button, the macOS look of an action that is already done (like Safari's Set
  Default once Safari is the default): "Default" in the table row and "Using as default" on
  the focused card, in the normal button frame at the system's disabled fill and text. No
  green, no accent color, no check.
- **Conversations, Maintenance, Settings:** the same cards, rows, and buttons. Maintenance
  shows Cleanup, then Backup, in a 28 pt segmented control with 120 pt segments, left-aligned
  to the cards, label-colored icons, and a searchable source picker at the bar's right end.
- **Stability and focus:** nothing shifts when content loads, rows are hovered or selected, or
  pages change. Every scroll view (pages, sheets and dialogs such as Add Account, popovers,
  pickers, and text views) hides the system indicators and draws a thin scroll bar in a fixed
  gutter, with no track or border. The bar is hidden at rest. It fades in (150 ms) and grows
  from 4 to 6 pt when the user scrolls with a mouse or trackpad, or when the pointer enters the
  gutter; on hover or drag it widens to 8 pt and brightens. It fades out (300 ms) 1 s after the
  last scroll or after the pointer leaves. Reduce Motion keeps the fade only. Clicks and
  selections never draw focus rings or outlines, including the sidebar and lists; keyboard
  focus is a subtle tint even with keyboard navigation (Full Keyboard Access) on. In Dark Mode,
  selection, focus, and focused fields use a neutral lighter gray, never a blue tint. System
  focus rings show only with Increase Contrast on. Provider tiles use each brand's own full
  icon, including its original background color, never a generic dark tile. Dark Mode controls are flat fills
  with no light rim. Every container has equal top and bottom inner padding; hover and
  selection highlights have even insets.
- **Motion:** micro-interactions everywhere: hover and press fades, bars filling on appear and
  on change, rolling numbers, cards fading in on page change, sliding segment indicators,
  springy popover row expansion, and chart draw-ins, at 150-350 ms with ease-out or a soft
  spring. Reduce Motion keeps fades only. A page switch shows its first frame with no visible
  delay; heavy work runs off the main actor.
- **Menu bar popover:** about 360 pt wide, compact, with no app name header. Its surface is
  less see-through than the default popover material; in Dark Mode it stays dark (about
  #262628), never a lifted gray. Separators use half the hairline opacity and fade at both ends.
  The group headers, rows, and footer share the footer's 12 pt inset from the popover edge.
  Hover highlights reach 4 pt past the content to the sides and below, and 6 pt above the
  name, so they never touch the group header; row spacing never changes. Text and footer controls use native contrast (primary
  label icons, not dimmed). Buttons keep the
  Sequoia size (24 pt painted, 5 pt radius, flat fill); hover and press never grow them.
  Expanding or collapsing a row never moves the rows above it, and the popover height and its
  content animate as one motion with no dropped frames, also in Low Power Mode. Accounts are
  grouped by service: one group header per service (its brand logo tile and name), then that
  service's accounts, each as its own row with its usage lines under it. The default account's
  checkmark sits in a leading column left of the name; every row's text starts after that
  column. Credit and amount values are right-aligned and start at the bar column. The tokens
  line never wraps; a long value uses the free width instead. Account rows carry no logo and no service
  name. Show in Menubar uses the Settings default or an account override. Each account shows
  its service's reported windows, including unknown values; plan differences and an account's
  hidden-row override can reduce them. Each line aligns the window name, a 4 pt rounded bar,
  percentage, and reset in fixed columns. Bars everywhere (popover and window) fill with the
  provider's brand color and turn red from 90% used.
  Clicking an account expands it to every reported window (model buckets and credits too) plus
  Switch and Open <tool> actions. An account that needs sign-in shows "Sign in again to see
  usage" as its subtitle, with Sign in at the row's right, bottom-aligned so it lines up with
  the buttons the row shows when it expands. A model-specific weekly window is
  named by its model: "Weekly Fable" in the window and just "Fable" in the popover.
  The context menu offers Switch, Open <tool>, Refresh, and Copy name. The footer holds Open
  Switch (Command-O) at the left and the Refresh, Quit (power), and Settings icon buttons at the
  right in that order, 6 pt apart.
- **Behavior kept:** displayed paths copy on click with a brief Copied confirmation (Preview
  never touches the real clipboard); every icon action has an accessible name and keyboard
  focus; Reduce Motion and Reduce Transparency follow the system; Preview data is synthetic.

Deleting the default account first activates an eligible saved fallback: the selected other
account, then the previous selection, then the most recently used, then the first available. The
confirmation names the replacement, and a failed activation keeps the account. With no eligible
fallback, Delete account stays disabled with its normal label. Conversations and settings stay.

Background reconciliation never disables the interface or republishes unchanged values. Secondary text identifies the provider (such as Codex CLI); only
states that need action add a badge. The Dock and Spotlight icon and the monochrome menu-bar
template are unchanged.

Add Account and Advanced Import are native sheets: a provider search and single-choice list
(double-click continues), then the provider's form or sign-in page, with standard Cancel and
Continue buttons and a small step indicator; every step keeps its buttons visible.

## 5. Terminal distribution

`ai-manager` owns the terminal interface and opens it without arguments. `make tui` is the
checkout entry point. Distribute the compiled Apple Silicon macOS executable as `@smdl/switch`:
npx opens the interface; global installation exposes `switch` and the `ai-manager` alias.
The root README documents all three paths. The package adds no account logic or Swift build step.

Use **09 Amber Menu**: compact character-cell accounts grouped by provider, one inverse selected
row, selected-account limits, and arrow navigation. Keep every account operation, including
confirmed deletion. Actions retain their full text after a compact semantic glyph. Leave colors
to the terminal; use only bold, dim, and inverse ANSI attributes, without appearance detection.
Piped output and `NO_COLOR` are plain. Start the animated loader with the initial refresh and
clear it before the menu. Show cached limits; never invent usage.

Attached terminals use raw input: Up/Down move focus, Right/Enter opens the account, Enter runs
the action, and Left/Escape returns. No command-letter navigation. Restore normal input for
paths, the launched Codex process, and exit. Preserve terminal output processing so lines start
at column zero in Terminal, iTerm, and compatible emulators.

## 6. Verification contract

Tests use synthetic credentials and isolated homes. Before UI installation, pass the Mac GUI
contract, production and Preview model checks, System/Light/Dark snapshots, lintapple (section 4),
and the full native gate. Core or CLI changes also pass both Linux Docker architectures without
privileges or writes. Public GitHub releases may use ad hoc signing if Developer ID is unavailable.
Keep install copy concise, without signing or Gatekeeper warning blocks.

Build, validate, and upload Mac archives on the maintainer's Mac, not GitHub Actions. The README
links the current Switch download; older product releases are not Switch. Lead with provider-neutral
switching. Keep provider paths, session behavior, and limits in concise provider notes.

Before installed-app GUI actions, match the packaged and `/Applications/Switch.app` executable
SHA-256 values, the embedded and committed revisions, and the running process's installed binary
inode. Correct stale processes or checksum mismatches before clicking. Record proof in the install receipt.
