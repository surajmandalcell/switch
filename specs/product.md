# Switch product specification

This spec owns current behavior; ignored `goals.md` tracks work, `goals.archive.md` evidence.

The owner's red emergency-stop switch on ivory marks Switch in the Dock, Spotlight, MacPowerToys,
and the window. Its original vector mark is the small menu-bar template.

## 1. Product model

Switch manages authentication snapshots for Codex CLI, Grok Build, Droid (Factory), and Claude
Code; section 1a covers other providers.

Codex's live home is `~/.codex`. After identity and digest checks, Switch atomically replaces only
`~/.codex/auth.json` from saved private credentials. Configuration, instructions, skills, plugins,
conversations, databases, and other non-authentication state stay. Running processes keep their
in-memory credentials; new sessions use the selected account.

Owner-private credentials live at `~/.switch/codex/<account-uuid>.json`. Stable UUIDs keep emails
out of paths. Application support holds the registry, usage cache, transactions, backups, and
recovery metadata. SQLite never stores raw authentication.

Grok Build's live home is `~/.grok` or `$GROK_HOME`. Switch atomically replaces only `auth.json`;
configuration, rules, plugins, MCP credentials, and sessions stay. It supports subscription OAuth
(`oidc` and first-party external OAuth), not `XAI_API_KEY`. Credentials live at
`~/.switch/grok-build/<account-uuid>.json`. Add Account runs `grok login --oauth` in a private
temporary `GROK_HOME`. If browser loopback fails, the sheet sends an authorization code or full
callback URL once to the waiting official CLI without saving it. Grok hot-reloads `auth.json`;
existing processes may use the new account on their next API call.

Droid and Factory.app share `$FACTORY_HOME_OVERRIDE/.factory`, or `~/.factory` when unset. Their
store is `auth.v2.loginkeychain`, or `auth.v2.file` plus `auth.v2.key` with the keyring off.
A fixed Keychain key encrypts all Factory logins. Switch saves outgoing files, honors
`auth.v2.write.lock`, then atomically replaces only auth files from owner-private
`~/.switch/droid/<account-uuid>/`. Sessions, settings, and history stay. droid reads on demand;
new requests use the selected account. Ask before switching if Factory.app or droid uses the live
home, or a process's home is unproved; Cancel is default. Only a usage click starts the one macOS
prompt to read the shared Keychain key; background refreshes never prompt. Switch decrypts
in memory for the access token and never writes the key, decrypted login, or refreshed token.
Import the existing login first without sign-in. Add Account runs interactive `/login` in
Terminal with a private temporary `FACTORY_HOME_OVERRIDE`, one Droid login at a time. An existing
Factory login supplies that key. While Factory.app runs work, live tests use the droid CLI
in a separate `FACTORY_HOME_OVERRIDE` test home, never `~/.factory`.

Droid identities are opaque. The owner names imports and sign-ins ("Droid 1"). Account-scoped
sign-in confirms the target name first. Run `droid doctor --auth --json` with
`FACTORY_HOME_OVERRIDE` and matching `FACTORY_DISABLE_KEYRING` on the login's own home (staging
for sign-in, live for import). Use Factory.app's bundled droid when present. Never use a copy:
a refresh could spend a rotating token and sign Factory.app out. Passing `auth.verify` gives
a masked email beside the name. Changed hints reject re-sign-in, discard staging, and preserve
the account. Confirm names even with equal masks.
Add Account warns about duplicate masks. If doctor fails or its output is unknown, Switch uses
named accounts and reports that limit. Only the active default refreshes live files through the
guarded switch path;
others refresh saved copies. Factory usage APIs `/api/billing/limits`
and `/api/organization/subscription/usage` use that access token. On expiry, usage returns after
droid refreshes; Switch never refreshes it. An optional per-account Factory API key uses the
existing Factory usage provider as fallback. The generic Factory API-key provider is separate,
with its own default. The write lock is a nonempty directory published by rename; its 0600
`owner.json` holds a random token and process ID. Honor `.reclaim`; never remove another writer's lock.

Claude Code profiles use stable, separate `CLAUDE_CONFIG_DIR` paths and can stay signed in.
Claude Code owns credentials and Keychain entries; Switch never copies or parses them.
`~/.switch/claude/active` selects the default for Switch and host-app launches. Opt-in shell
integration applies it to plain `claude`; otherwise that command keeps its login. Profiles
share `~/.claude` history through symlinks (projects, history.jsonl, settings.json, CLAUDE.md,
commands, agents, skills, plugins, and similar items). `.claude.json`, `.credentials.json`,
and policy caches stay per profile. Before adding links, back up and merge existing data without
overwriting. Usage reads a file-based access token read-only when present, else the CLI's
`/usage` panel, at most every ten minutes per profile. Never spend a Claude refresh token.
If a pending macOS privacy prompt for Switch blocks the CLI, show an uncached Allow hint.

## 1a. Generic providers

Switch includes every OpenUsage and CodexBar usage provider without macOS Keychain or browser
cookie stores. Each `ProviderSpec` uses one of two credential styles:

- **Files**: The official CLI or app owns credential files, shared JSON members, or database
  key and value rows, such as `~/.gemini/oauth_creds.json`, OpenCode auth.json's `opencode-go`,
  or Cursor's `cursorAuth/*`. Switching keeps the newest ten live-byte backups per provider,
  saves outgoing and rotated tokens (including unsaved logins), then atomically writes only selected
  bytes. Other files, members, rows, conversations, and settings stay. Run official Terminal
  sign-in in a private temporary home; import its login. "Import current
  sign-in" saves the live login. At launch and refresh, Droid and OpenCode Go
  import each distinct unsaved live login once as default. Skip equal Droid masks and never
  re-import deleted accounts. Auto-import adds a small "i" after the name; its tooltip
  names this Mac's login. The same pass imports Z Code's z.ai coding-plan keys from
  ~/.zcode/v2/credentials.json, named by plan ("Z Code individual plan"). Decrypt with Z Code's
  AES-GCM key from user name and home folder, never Keychain. Skip undecryptable files.
  OpenCode 2 keeps logins in ~/.local/share/opencode/opencode.db's `credential` table, not
  auth.json. Switch reads active `opencode-go` as live OpenCode Go and imports unsaved
  `zai-coding-plan` keys as z.ai. It never writes the database; changing the OpenCode Go default
  asks for `opencode auth login`. Usage 403 EntitlementError means no Go subscription: show
  "No Go plan" with a usage reason, not an error or sign-in. OpenCode has no
  Free plan; without Go, it uses pay-as-you-go Zen.
- **Secret**: API keys, access tokens, or a pasted Cookie header. Switching selects the
  default saved account.

Saved credentials live at `~/.switch/<provider>/<account-uuid>.json` (0600); index and backups
live in application support `provider-accounts/`. Files usage reads live bytes without spending
CLI-held refresh tokens. Vault-only accounts may refresh and save tokens. Write refreshed live
bytes back only if unchanged.

Usage holds rate windows (used share, reset time, length), money (spend, limit, balance),
detail rows, plan, and identity. Its first window drives the menu-bar percentage. Omit missing
values. Use HTTPS; allow HTTP only for loopback, RFC 1918, and `.local` gateways. Never follow
cross-host redirects.

Excluded: hooks, the QuickJS plugin engine, browser cookie import, Keychain
reads, keepalive, adaptive refresh, agent sessions, widgets, iCloud sync, Sparkle,
telemetry, local HTTP API, proxy settings, and merge-icons mode, with the providers that need them.

Codex CLI and Grok Build defaults match live credentials; Claude Code's default selects
Switch-launched sessions. Switching and deletion change defaults only within that provider.
The TUI groups accounts by provider, keeps their order, and marks each group's default.

Existing-account "Sign in" binds an isolated session to its account ID. Before changes, match
the saved provider identity. On mismatch, discard the home and report both identities. On a match,
atomically refresh only that credential. Only active defaults update live auth through the
same-identity switch path. Account-scoped sign-in never signals running CLIs. "Add account"
remains provider-scoped.

After restart, sign-in checks read private staging with auth-only import's identity, digest, and
transaction checks; unrelated Codex processes cannot block them. Retire metadata when process
ownership ends and cancel only owned processes. After restart or refresh, remove retired staging
homes only when home-scoped checks prove no writer. Keep active, unknown, and recovery homes.
Retired IDs never return as pending or permit re-import.

Full imports, legacy settings repair, and recovery check writers in affected homes and shared
symlink targets. Identify Codex processes by held home-scoped runtime locks, never environment
or credentials. Verified unrelated homes do not block. Missing, inaccessible, or unknown
ownership evidence blocks destructive changes; unlocked stale files are not writers.

## 2. Navigation and Settings

The sidebar and View menu order pages by name length: Overview, Accounts, Settings, Maintenance
(cleanup, backup, recovery), Conversations (chat history). Command+, opens Settings. Save page,
tab, each page's account, scroll, filters, chart period and grouping, cleanup source and range,
backup source and destination, conversation selection, and expanded popover rows across restarts.
"When Switch opens" selects Last place (default) or Overview. Settings groups follow this order:
General (Open at Login, Minimize to menu bar, When Switch opens, Menu shortcut), Appearance
(System, Light, or Dark; Usage percentage; Reset times; Time format), Accounts (Show full email
addresses, Hide email addresses, Check provider status, Claude terminals), Auto switch, Menu bar,
Notifications, Data locations, and Reset. Show full email addresses defaults off:
"ada@gmail.com" reads "ada@gmail" and "ada@mail.example.co.uk" reads "ada@mail.example".

1. **App behavior** includes Open at Login (off by default, macOS login-item service, quiet
   menu-bar launch, approval link to Login Items).
   **Reset times** offers Countdown (default) or Exact time; **Time format** offers Auto, 12-hour,
   or 24-hour. Reset text uses them: "Resets in 2h 5m", "Resets 5:30 PM", or "tomorrow",
   a weekday, or a date beyond today. Clicking toggles the choice everywhere; hover shows the other.
   **Usage percentage** has Left (default, "90% left") or Used ("10% used"). Save and apply it to
   text and fill in every meter, popover row, tray percentage, tooltip, and accessibility label.
   Clicking a percentage ("52% left") toggles it everywhere.
   **Menu shortcut** records Command, Option, or Control plus a key; Delete clears it. It is off
   by default and toggles the popover from anywhere.
   **Refresh when the menu opens** is off by default.
   **Reset settings** confirms separately. It resets Settings choices, account Menubar and hidden
   rows, and the shortcut; it keeps accounts, sign-ins, placement, and Open at Login.
2. **Data locations** explains Codex and Grok Build homes and vaults (`~/.codex`,
   `~/.switch/codex`, `~/.grok`, `~/.switch/grok-build`) and offers Reveal actions.
3. **Menu bar defaults** has Show account usage on by default; explicit overrides survive changes.
4. **Notifications** offers Almost Out (under 10% left), pace (Cutting It Close, Will Run Out),
   Available again (full window reset), and Sign in again (once per failure episode). All are off
   by default; enabling or first post asks permission. Launch never alerts; count only delivered alerts.
5. **Provider status** is on by default. Poll saved providers'
   pages at most every five minutes. Yellow or red dots mark incidents; failures keep the last
   good value.
6. **Claude terminals** has Use the selected Claude account in terminals off by default. It adds
   one marked line to `~/.zshrc`, with backup, sourcing Switch's `claude` shell function.
7. **Privacy** masks hidden email addresses everywhere as `a••••@example.com`.
7a. **Auto switch** (owner picks A1 and R1) offers Switch accounts automatically, off by default.
   Thresholds are 1% (default), 2%, 5%, 10%, or 20% left of the lower session or weekly limit;
   a past-reset window counts as full. Running CLIs offers Restart when idle (default) or Leave
   running. The default Resume message is "Continue. A usage limit cut your last turn short; redo
   the last step if it did not finish." Follow Accounts order from the top. At threshold, make
   the first other signed-in account above it the default and notify once. Skip switched-away
   accounts until recovery. If none qualify, keep the default and report once per episode.
   Restart when idle waits for an interactive Codex CLI or Claude Code turn to finish or hit its
   limit, then stops it (SIGTERM, SIGKILL after 5 s). Reopen it behind the front app in a new
   Terminal window, same folder and new account, with `codex resume <id>` or `claude --resume
   <id>`. Keep original options. If a separate-value option or prompt cannot carry over, leave
   it running and notify the owner. Claude Code without a profile folder uses the default
   `~/.claude` login. Send the resume message only for a limit-cut turn. Never stop mid-turn or
   touch `codex exec` or `claude -p`. After 2 hours without an idle turn, leave it running and
   report it. Other providers change only the default.
8. **Demo controls** appear only in locally launched Preview builds for all owner-used services,
   including Droid. Production and installed builds must neither compile nor render them.

Settings omits "Linked entries," per-account chat libraries, and managed-home topology.
Show account legacy repair only when needed.

Cleanup's searchable account-style picker lists shared homes ("Codex CLI · 3 accounts"), Claude
Code once (it scans profile files, never links). Backup has no picker. The disclosure tree shows real
sizes for AI-tool categories:
active and archived chats by project, pasted and generated images, logs, caches, debug and temp
files, file history, old app versions, shell snapshots, usage samples, and conversation index.
Conversations are shared data, never attributed to the selected account.
Date ranges, including older-than shortcuts, all time, and custom intervals, use file last-write time.
Remove selected conversations whole. Undated old app versions and Claude app VM appear in every
range. The card header reads "N items · <in range> of <total the tool uses>". An empty range
names the total: "Nothing older than 30 days. Codex CLI uses 11.7 GB; choose a shorter range to see it."
Old app versions are checked by default: all Codex standalone and app-server, Claude Code,
and Claude app builds except current, newest Claude app copy, and builds in use.
"Pasted images in old conversations" is unchecked. It replaces each Codex or Claude Code inline
base64 image with a 1x1 PNG, keeping text and chat opening. Skip chats open in running apps or
written within the hour; show saved bytes and trash originals for Restore. Codex "Generated
images" defaults checked. "Claude app VM" is unchecked and protected while its app runs.
Show untouched counts and reasons: "701 items stay untouched: linked by another app."
Preview exact items and bytes for one confirmation. Remove conversations through private
recoverable trash, a journal, restart recovery, and Restore; confirm permanent removal separately.
Trash moves never claim freed space. Preserve compact activity totals before removal; reject
changed or unsafe files and active or unknown writers. Protect auth, settings, account registry
and defaults, backups, Codex databases, and activity ledger. Mark linked or foreign-owned chats
protected; exclude them from removal review without blocking safe files.
Use a native time-range pop-up. Align expanded rows to their nesting level's leading edge.
Give groups clear headings, aligned counts, and brief descriptions; keep totals beside Review.

Backup is one checklist of every tool (size, last backup); Claude Code is one row that includes
each account's profile folder. Checked tools share one owner-picked folder, schedule (off, daily,
weekly), and snapshots to keep; "Back up N tools now" runs them, each in its own subfolder and
history. The first snapshot copies all; later ones copy changes and hard-link unchanged files, so
each stays complete. Build a temporary folder and manifest (path, size, modified time, SHA-256),
then rename. Offer Restore of all or chosen items in place after a safety snapshot or to another
folder. Exclude login files unless the owner includes them. Never delete source data; prune only Switch
snapshots. If the destination is missing, such as an unplugged drive, wait and explain.

Chat History pages messages by time while scrolling, with no older cutoff. Saved filters and
search cover full conversations and page results. Copy shown exports loaded, filtered messages
in order. Use virtual native rows; parse, search, and render off the main thread. Large messages
may be compact but keep original copy text. Align header message count and token total with its subtitle;
omit unreliable totals. A small sidebar spinner replaces the count only during first-page load;
counts say "conversations". Give prompt, response, tool, and other roles distinct fills, shared
leading alignment, and no left borders. Wrap code lines for continuous vertical scrolling. Give
role, model, and date headers their own lines; show responses and code at full height without
clipping or overlap. Group threads by Today, Yesterday, and dates. Rows have full-width one-line
titles; subtitles show a small origin badge (Codex CLI, Codex exec, Codex app, Codex Chrome,
Subagent), then model and time.

## 3. Usage presentation

Generic, Grok Build, and Claude Code accounts use `readProviderUsage`. Cache each last good
snapshot on disk for launch. Refresh every five minutes with four concurrent 60-second checks.
After failure, wait five minutes and keep the last good value as Outdated.
Detail pages show all standard window meters, reset countdowns, OpenUsage pace (blue ahead,
yellow close, red running out, even-pace tick), money, and short detail rows. Menu cards show
the first two windows, all when expanded, or one balance line for money-only providers. Add
Account search lists Codex CLI, Grok Build, and Claude Code first, then others alphabetically.
Local file logins, read off the main actor, show "Signed in on this Mac" after built-ins. Usage context
menus offer Hide, Show all, and Refresh; hidden rows leave that account's detail and menu views.
Command-R refreshes. The status context menu offers Open, Refresh Usage, Settings, Quit.
Claude's account page prices all profiles' local transcripts as an API-equivalent estimate;
Droid sessions use the same panel above the Factory usage key.

Daily charts (30 days or native span) return id, title, unit (USD, tokens, requests, credits, or
currency), and dated points. Draw 72-point bars per series below windows. The header shows the
title and total or hovered or focused day; VoiceOver says "30 days, total $12.40, peak $2.10 on
Oct 3". Claude Code's 30-day cost uses this chart. On 30-day axes, name the first, middle, and
last dates in full; end labels clamp inside the card inset. Menu cards omit charts.
`switch usage --json` adds `charts` (`switch.limits.v1`); CLI and TUI each draw one ▁▂▃▄▅▆▇█ line.
Show real overage ("130% used",
"0% left"), clamping fills. Sub-cent money uses up to four decimals ("$0.0042").

Refresh reads selected saved credentials in disposable private homes, never activating accounts.
The Usage panel shows returned windows and statistics:

- Omit absent plan, credits, spend control, activity statistics, secondary windows, daily activity.
  Keep explicitly returned zero, `false`, `None`, or `Available`; only absence removes rows.
- Codex names `prolite` Pro 100, `pro` Pro 200, `promax` Pro 500, and
  `self_serve_business_prolite` Business Premium. Other ids keep their capitalized text.
- Name Codex windows by duration, not slot: 300 minutes Session, 10 080 Weekly. Shorter first;
  a lone weekly window takes the primary slot, including menu-bar percentage. Model buckets use limit names;
  GPT-5.3-Codex-Spark is "Spark". Use generic pace tick, colors, tooltip.
- Show credits as dollars plus floored credits (4 cents each), such as `$31.84 · 796 credits`.
- After app-server read, call `wham/usage` and `wham/rate-limit-reset-credits` with the private
  copy's access token and account id. Never refresh it; skip expired tokens. Add "Reset credits: N"
  (soonest expiry, all in tooltip), unlisted model buckets, credits if no bucket has them, and
  "Monthly credits" from `individual_limit` (root, `rate_limit`, or `spend_control`). Hide code
  review percent, `remaining_balance`, and reset guard.
- Keep actionable states: "Usage has not been checked," a refresh error, or no windows at all.
- Never manufacture a value from transcripts or combine stale usage with Needs sign-in.

Refresh all saved Codex accounts at launch and every three minutes while running, despite cache
age or menu opening. One cache model updates window and menu bar per completed refresh.
Manual refresh is immediate; failed accounts wait five minutes for automatic retry.

Daily activity is a GitHub-style calendar. Its saved segmented control (Today, Yesterday, Weekly,
Monthly, Yearly; default Yearly) sets range, total tokens, and cell intensity. Account selection
changes display without activating credentials, waiting for reads or aggregation, or showing prior
data. A year of activity stays responsive. One Canvas handles dense grids, exact-day pointer
selection, arrow keys, and per-date accessibility actions on marker bounds. Label weeks from
Sunday. Redraws never reload the Dock icon; indexing uses utility priority.
Selected days show date and exact tokens. Lifetime, Peak day, streak, and Longest turn sit right
of Ordinary usage.

Keep owner-private SQLite `activity/daily.sqlite` apart from expiring quota snapshots.
Authoritative Codex responses set totals per account and day. Newer values replace older, even
lower values and zero; omitted days stay. Local token events set project and day totals on UTC days.
Count cumulative-counter increases, not repeated last-turn counters. Thread IDs remove archived
or copied duplicates; unknown forks or reset records mark totals incomplete. Shared project totals
serve history and cleanup, not selected account statistics. Record daily shared-home provenance
and retain no messages.
Incremental scans, restarts, source deletion, and cache clearing never erase or duplicate totals.
One background monitor coalesces active and archived chat and thread-metadata bursts.
After its first full scan, parse only verified JSONL appends. Replacement, truncation, or unsafe
boundaries force a full parse. Read metadata only on database or WAL changes. A hidden, unchanged
app scans nothing.

Selected-account token statistics sit in Daily activity's fixed-height period-total line.
The tooltip and accessibility value give exact counts; late prices never shift content.
Weekly, Monthly, and Yearly cover rolling 7, 30, and 365 UTC days including today. There is no
account or provider filter or source label. Hide Daily activity until history exists; then keep
explicit zeroes. The TUI uses the same periods and data.

Codex popover rows may add one token summary for the Settings period: Since reset (default), Today,
Yesterday, Weekly, Monthly, or Yearly. Since reset uses the weekly start when the service returns
duration and reset time; otherwise it uses Weekly. Hide a zero token row.

Beside tokens, show an API-equivalent value if the shared Codex config's model has published prices
(LiteLLM public catalog, cached 24 hours). Label it an input-rate equivalent, never billed cost.
Help shows the model and cached-input, input, and output values.

Each account's More menu has **Show in Menubar** with a checkmark and Use Settings default.
It controls the popover row and tray entry. The tray shows the first four enabled accounts with
limits in saved order. A 12-point monochrome glyph precedes each service's percentages; the
first account sets service order. Defaults never reorder. Skip signed-out or uncached accounts,
name them in the tooltip, and use the next enabled account. If none qualify, show the Switch
mark. Disabled usage has no refresh or placeholder; enabling never activates an account.
Choices persist by UUID and apply immediately; main-window usage ignores them. Codex uses the
5-hour limit when present, else weekly; never invent a 5-hour value. For Left, the tray subtracts
clamped used percent from 100. Provider glyphs add no providers or network work.

Drag the hover grip left of the guide line to reorder accounts within a provider. A blue line
marks the landing spot; Move up and Move down remain in the context menu. Save order atomically
in the private app and CLI registry. Reopening keeps order, new accounts append, and deletion
preserves remaining order. Reordering never selects or activates an account or changes credentials.
Stale or foreign IDs do nothing; unchanged drops write nothing.

## 4. Visual system

Follow macOS HIG, the owner's popover mockup, and `docs/design/overview-concept.png`. Keep the
concept's Sequoia 15 style on every macOS version; draw it when the OS supplies glass.
Do not use Liquid Glass. Use light grey content (dark grey in Dark Mode),
white grouped cards with hairline borders (lighter dark fills), Sequoia push buttons, menus, and
search, semantic colors, and the user's accent in both appearances.

**Design gate:** Before shipping UI, lintapple (`packages/mac-gui/ui-lint`) must find zero issues
in light and dark HTML references (Overview and shared-part states) and measured SwiftUI mirrors of every page.

- **Type and color:** Use only five screen and popover roles: Title (Title 2, semibold, 17 pt, one
  focused account name per page); Section (Headline, bold, 13 pt, card and form titles); Body
  (regular, 13 pt, labels, values, buttons, Default); Secondary (Subheadline, 11 pt, secondary
  color, providers, descriptions, resets); Caption (10 pt, badges). No other sizes or weights.
  Give numbers monospaced digits; use monospaced fonts only for paths and IDs. Usage bars are 4 pt
  brand-color capsules, red from 90% used; unknown values have empty grey tracks. For 75 providers,
  take brand colors from official logos,
  else sites or product UI. Adjust only lightness per appearance to reach 3:1 card contrast.
  Black and white brands (Grok, OpenCode Go, Vercel, others) use #8E8E93 light and #98989D dark.
- **Geometry (points):** Use 20 content margins, 12 between cards, radius 10, and inset 16.
  Titles, column headers, rows, and separators share the inset; headers never exceed full-width
  cards. Title rows are 44 tall: Section title left, Secondary count or accent "View … →" right.
  Rows are 36 tall with hairline separators. Push buttons are 28 tall in cards and 22 in tables;
  icon buttons are square. Inner tiles such as Current limits keep 16 at each edge and below,
  12 between tiles, and radius 6.
- **Window:** Use a translucent 220 pt sidebar, 52 pt unified title bar, and empty system toolbar.
  Content stays 1200 pt wide. Open at 900 pt high or less on shorter screens; resize from 800 pt.
  Green zoom fills screen height at that width, without full screen. Traffic lights use the
  system inset and align with "Switch" and the top row.
  Sidebar filled SF Symbols follow section 2: Overview `house.fill`, Accounts `person.2.fill`,
  Settings `gearshape.fill`, Maintenance `wrench.and.screwdriver.fill`, Conversations
  `ellipsis.message.fill`. The top row runs Add, More, then "Search accounts…" at right, lightest
  to heaviest. Search is 300 pt wide, filters all account lists, shows ⌘K, and takes focus with
  Command-K. All cards end at the top bar edge.
- **Messages:** Switch shows results ("Droid opened in Terminal.") in short, silent macOS
  top-right banners, saved in Notification Center and shown while Switch is frontmost. Disabled
  notifications show none. Pages have no message card. Errors use the red bar below the top row
  with Copy and Dismiss. Preview and isolated checks never notify.
- **Overview:** Switch accounts on Accounts. Overview has no focused-account card or table.
  Remember Week or Month and Accounts, Models, or Projects grouping. Six cards show (1) rolling
  tokens, estimated cost, active accounts, and busiest day; (2) a daily grouped-token streamgraph;
  and (3) a one-year all-account Activity heatmap. Only used days show a hand pointer and open a
  dated sheet ("Saturday, October 3"); dragging and empty days do nothing. The sheet shows token, cost, and
  session totals; a stacked cost bar with an
  Account or Model legend in brand and palette colors; and each session's title, tool, start time,
  tokens, and cost. Only Codex sessions link to surviving transcripts in Conversations. Removed
  transcripts are dim and inert with "Transcript removed". Without session data, show totals,
  the split, and centered "No sessions on this Mac for this day. The totals come from the account's
  usage report."
  Done or Escape closes the sheet. Trends (4) shows daily group ridgelines scaled to each peak in
  a fixed-height card, names in a one-line legend below. Continuous charts (Tokens per day,
  Trends) run edge to edge; bar charts, titles, legends, and axis labels keep the inset.
  Tooltips are opaque, draw above legends, and read "Claude Code · account". Share of tokens (5)
  uses a 20 by 10 waffle grid (200 half-percent cells),
  whole-percent labels, and "<1%" for one cell. The grid takes 40% width; after a 24 pt gap,
  legend rows take 60%, span grid and card height, and measure 20 to 28 pt each.
  Maintenance (6) shows recent backups (time, source, size, state) and Open Backup or setup.
  Follow uiarc.dev ridgeline, activity heatmap, waffle, and streamgraph. Use hover values, a
  faint date axis, and one palette. Fold groups past six into "Other". With account
  grouping, a 13 pt tool brand tile precedes each label in legends, tooltips, and the day-sheet
  cost split. Tiles distinguish matching emails. Model and project
  groups have no tile. The Tokens per day legend stays on one line;
  shorten all names with "…" together if needed. Fill when accounts load at launch, without a
  page change. Count Codex, Claude Code, Droid, and Grok Build. Unknown account history (Claude
  Code's shared ~/.claude, Droid, Grok Build) goes to the tool's sole saved account. With zero or
  two or more accounts, show "<Tool> (shared)"; never drop it. Droid history uses
  `~/.factory/sessions/*/<id>.settings.json` totals on its last-change day. Compute local history
  and the activity ledger off the main actor. Explain empty groups in place.
- **Accounts:** The table sits above the selected account card. It shows a 44 pt icon tile, name
  without picker, provider with Active dot or badge, primary window, and Make Default, Open
  <tool>, Copy, and More. Missing usage leaves dotted meters and dashes in the card's right-side
  space. One grey reason ("No Go plan", "Couldn't check usage: <reason>") appears in the card and
  Usage header, without orange text or an empty band (owner pick E4). Signed-out accounts use
  "Sign in again" as the primary action. Unreadable Droid logins show "Allow access to see usage"
  in the usage column; Allow replaces the default marker, and the card shows Allow access. The
  table has no column header or Provider column. Provider headers are 32 pt with a 16 pt brand
  tile, semibold name, and plain secondary count ("×2"). The card header has no account total.
  Indent accounts 24 pt under providers; a thin guide line joins the tile to account elbows like
  Finder. Groups have a 6 pt gap and no zebra fill. Row separators start at the indent and stay
  lighter than card borders. The usage column has a bar and "83% · 6d 19h" (percent then reset),
  without a reset column. Without usage, a reason such as "Sign in to see usage" replaces the bar
  and dashes. The default uses a framed disabled button with system disabled fill and text, like
  Safari's Set Default: "Default" in the table and "Using as default" in the card. Use no green,
  accent color, or check.
- **Conversations, Maintenance, Settings:** They share cards, rows, and buttons.
  Maintenance shows Cleanup then Backup in a 28 pt segmented control with 120 pt segments.
  It aligns left with the cards, uses label-colored icons, and puts Cleanup's source picker at the
  bar's right end.
- **Stability and focus:** The global ui-quality "Owner taste" rules apply: no shift, rings, or
  rims; neutral dark selection; original brand tiles; even insets; still scrolling. Every
  scroll view (pages, sheets, Add Account dialogs, popovers, pickers, text views) hides system
  indicators and draws a thin gutter bar without track or border. It hides at rest, fades in over
  150 ms on scroll or gutter entry, and grows from 4 to 6 pt. Hover or drag widens it to 8 pt and
  brightens it. It fades out over 300 ms, 1 s after scroll or pointer exit. Mouse and trackpad
  scroll anywhere on pages, lists, messages, and gutters. Restore a saved offset once, on entry.
- **Motion:** Fade hover and press; fill bars on appearance and change; roll numbers; fade cards
  without moving on page change; slide segment indicators; spring popover rows open; draw charts
  in. Use 150-350 ms with ease-out or a soft spring. Reduce Motion keeps fades only. Show the
  first page-switch frame without delay; run heavy work off the main actor. Motion runs once per
  page load; content scrolling into view stays still.
- **Menu bar popover:** About 360 pt wide, it omits app name, brand headers, token band, column
  header, session explanation, and Add Account. It fits all rows up to 80% of visible screen
  height; beyond that, its body scrolls above a fixed footer. One or two accounts never clip.
  Hidden or missing limits take no space and are never invented. Its surface is less transparent
  than default material; Dark Mode stays near #262628, not lifted gray. Separators are half-opacity
  hairlines faded at both ends. Inset headers, rows, and footer 12 pt. Rows expand only for
  buttons or hidden lines; idle rows have no hover or press fill. Expanded and focused fills use
  primary color at 0.06 opacity, and hover uses 0.04 in both appearances. Hover extends 4 pt
  sideways and below and 6 pt above the name, without touching the header or shifting rows.
  Text and footer controls keep native contrast and primary label icons. Flat Sequoia buttons
  are 24 pt painted with radius 5 pt and never grow. During expansion, earlier rows stay fixed;
  height and content animate together without dropped frames, even in Low Power Mode. Each
  service header shows a brand tile and name; account usage rows omit both.
  A leading default-checkmark column precedes row text.
  Values without a bar (credits, balance, "Tokens 34M since reset · ≈US$68 API") start at the bar
  column on one line. Windows use full words (Session, Weekly, Monthly); each extra pool (Droid
  Core, a model such as Fable) gets a small heading over its own rows ("Weekly Fable" in the
  window). Show all reported windows, even unknown values; plans and hidden rows may reduce
  them. Align window name, bar, percentage, and reset in fixed columns. Clicking expands all
  windows, model buckets, credits, Switch, and Open <tool>. Accounts needing sign-in show "Sign in
  again to see usage" as a subtitle and Sign in at right, aligned with expanded buttons' bottoms.
  Droid reuses the Accounts access text and action there. Context
  menus offer Switch, Open <tool>, Refresh, and Copy name. The footer puts Open Switch (Command-O)
  left and Refresh, Quit (power), Settings icons right, in order, 6 pt apart. Refresh
  checks enabled accounts in saved order without activating an account or closing the popover.
  Disable it while running; keep its space during progress.
- **Behavior kept:** Clicking paths copies them with brief Copied feedback; Preview never uses
  the real clipboard. Icon actions have accessible names and keyboard focus. Reduce Transparency
  follows the system. Preview data is synthetic.

Before deleting a default, activate an eligible saved fallback: selected other account, previous
selection, most recently used, then first available. Confirmation names it; failed activation
keeps the account. Without a fallback, Delete account stays disabled with its normal label.
Conversations and settings stay.

Background reconciliation never disables UI or republishes unchanged values. Secondary text
names provider (Codex CLI); badges mean action needed. A badge is a grey chip with label-color
text and a 6 pt state-color dot (owner pick B3); its text reaches 4.5:1 in both appearances.

Add Account and Advanced Import use native sheets. Provider search and a single-choice list
(double-click continues) lead to the form or sign-in page. Keep standard Cancel and Continue
buttons and a small step indicator visible at every step.

## 5. Terminal distribution

`ai-manager` opens the terminal UI without arguments; `make tui` is the checkout entry.
Ship the compiled Apple Silicon macOS executable as `@smdl/switch`: npx opens the UI; global
install exposes `switch` and the `ai-manager` alias. The root README covers all three.
The package adds no account logic or Swift build step.

Use **09 Amber Menu** with compact character-cell provider groups, one inverse selected row,
selected account limits, and arrow navigation. Show every action, including confirmed deletion,
in full text after its compact semantic glyph. Let the terminal choose colors; use only bold,
dim, and inverse ANSI without appearance detection. Piped output and `NO_COLOR` are plain. Start
the animated loader with initial refresh; clear it before the menu. Show cached limits; never
invent usage.

Attached terminals use raw input: Up and Down move focus; Right or Enter opens an account;
Enter runs an action; Left or Escape returns. Do not use command-letter navigation. Restore
normal input for paths, launched Codex, and exit. Keep lines at column zero in Terminal, iTerm,
and compatible emulators.

## 6. Verification contract

Use synthetic credentials and isolated homes for tests. Before UI installation, pass the Mac GUI
contract, production and Preview model checks, System, Light, and Dark snapshots, lintapple
(section 4), and full native gate. Core or CLI changes pass both Linux Docker architectures
without privileges or writes. Public GitHub releases may sign ad hoc without Developer ID.
Keep install copy concise, without signing or Gatekeeper warning blocks.

Build, validate, and upload Mac archives on the maintainer's Mac, never GitHub Actions. The README
links the current Switch download; older releases are not Switch. Lead with provider-neutral
switching. Put paths, session behavior, and limits in concise provider notes.

Before installed-app GUI actions, match packaged and `/Applications/Switch.app` executable SHA-256,
embedded and committed revisions, and the running binary inode. Fix stale processes or
checksum mismatches before clicking; record proof in the install receipt.
