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

Owner-private credentials live at `~/.switch/codex/<account-uuid>.json`. Application support holds the registry, usage cache, transactions, backups, and
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

Droid missions keep plan and progress in `~/.factory/missions/<session id>/`; leader and worker
chats are Factory sessions owned by the starting account, so only it can resume them. Accounts lists them under Droid, newest first:
title (mission.md's first heading), "131 of 160 done", owner, and created date; state shows on hover. Switch records the owner
of missions created while it knows the default (`droid-missions.json`); others offer Set owner.
Resume runs `droid --resume <id>` in Terminal in its working directory, after a guarded switch to
a different saved owner. Start here confirms, writes a plan of done and left features,
and runs `droid exec --mission -f <plan> --auto high` on the default. Leaving an owner of
unfinished missions posts one notice. Never edit mission files or call Factory's mission API.

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
  "No Go plan" with a usage reason, not an error or sign-in.
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

Existing-account "Sign in" binds an isolated session to its account ID and must match the saved
identity: a mismatch discards the home and reports both; a match atomically refreshes only that
credential. Only active defaults update live auth, through the same-identity switch path. It never
signals running CLIs; "Add account" stays provider-scoped.

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
addresses, Hide email addresses, Privacy mode, Check provider status, Claude terminals), Auto
switch, Menu bar, Notifications, Data locations, and Reset. Show full email addresses defaults
off ("ada@mail.co.uk" reads "ada@mail").

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
2. **Data locations** shows the Codex and Grok Build homes and vaults (section 1) with Reveal.
3. **Menu bar defaults** has Show account usage on by default; explicit overrides survive changes.
4. **Notifications** offers Almost Out (under 10% left), pace (Cutting It Close, Will Run Out),
   Available again (full window reset), and Sign in again (once per failure episode). All are off
   by default; enabling or first post asks permission. Launch never alerts; count only delivered alerts.
5. **Provider status** is on by default. Poll saved providers' pages at most every five
   minutes. Yellow or red dots mark incidents; failures keep the last good value.
6. **Claude terminals** has Use the selected Claude account in terminals off by default. It adds
   one marked line to `~/.zshrc`, with backup, sourcing Switch's `claude` shell function.
7. **Privacy** masks hidden emails as `a••••@example` (ending with full emails). Privacy mode
   (off) shows each account as a stable fake name (`Jon Doe`, `jon.doe@example.com`) everywhere,
   over both email settings; search and sign-in stay real.
7a. **Auto switch** offers Switch accounts automatically, off by default.
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

Cleanup's searchable app picker lists shared homes and account counts, with Claude Code once
(profile files included, links skipped). Backup has no picker. Show sizes for chats by project,
pasted and generated images, logs, caches, debug/temp files, file history, old builds, shell
snapshots, usage samples, and the conversation index. Chats belong to the shared home.
Combine app, project folders (multi-select), title text, and last-write date filters. Dates offer
7/30/90-day older-than presets, a before-date picker, all time, and intervals. Preview matching
titles, projects, dates, count, and bytes; Review selects only those conversations. Confirm the
exact count and size before trashing whole chats. Undated builds and Claude app VM show in every
range. The files header shows in-range and total bytes; empty ranges name the tool's total.
Check old Codex standalone/app-server, Claude Code, and Claude app builds by default; keep current,
newest Claude app, and in-use builds. Unchecked "Pasted images in old conversations" replaces
Codex/Claude inline base64 images with 1x1 PNGs; text and chat opening stay. Skip open chats and
those written within an hour. Show saved bytes; trash originals for Restore. Check Codex generated
images by default. Leave Claude app VM unchecked; protect it while Claude runs.
Show untouched counts and reasons. Use private recoverable trash, a journal, restart recovery,
and Restore; confirm permanent removal separately. Trash moves free no space. Preserve activity
totals first. Reject changed/unsafe files and active/unknown writers. Protect auth, settings,
registry, defaults, backups, Codex databases, and activity ledger. Exclude linked and foreign-owned
chats from removal review; safe files remain available.
Use a native range pop-up, nested row alignment, group headings, and totals beside Review.

Backup lists each tool's size and last backup; Claude Code includes its account profiles.
Checked tools share one folder, schedule (off, daily, weekly), and retention count, with separate
subfolders and history. Full snapshots copy changes and hard-link unchanged files. Publish a
temporary folder by rename with a manifest (path, bytes, modified time, SHA-256).
Prompt-only mode writes user prompts in time order with timestamps, one Markdown file per
conversation under each project, with title, date, app, and an index. Exclude responses, tools,
login files, and settings. It uses the same folder, schedule, and retention. Restore prompts into
a folder only. Full backups restore all or chosen items in place after a safety snapshot or to
another folder. Login files need opt-in. Never delete sources; prune only Switch snapshots.
Wait and explain when the destination is missing.

Conversations pages messages without a cutoff. Saved search and any role subset cover the full
chat; keep the last role on. Chips stay 24 pt high and fade for 150 ms. Put "Copy" before them;
help says "Copy the visible messages". Export loaded, filtered messages in order. No "Show" or
shown counts; show search matches only. Virtual native rows parse, search, and render off-thread.
Compact large messages but copy original text. Align reliable totals with the subtitle; replace
the sidebar count with a spinner during first load. Roles share a leading edge and neutral fills
without left borders. Prompts have primary selectable text and 10 pt corners. Wrap code; give
role, model, and date a header; show responses and code at full height. Group by Today, Yesterday,
and date. Titles have full-title help and "Copy title" menus; subtitles show origin, model, and
time. All clipped labels, including popovers, Settings, and sheets, have full-text help.

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

Daily charts (30 days or native span) return id, title, unit, and dated points. Draw 72-point bars per series below windows. The header shows the
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

Daily activity is a GitHub-style calendar; a saved period control (Today, Yesterday, Weekly,
Monthly, Yearly; default Yearly) sets range, total, and intensity. Changing account never
activates credentials, waits, or shows prior data. One Canvas draws a year responsively with
exact-day pointer, arrow-key, and per-date accessibility selection; weeks start Sunday. Redraws
never reload the Dock icon; indexing uses utility priority. Selected days show date and exact
tokens. Lifetime, Peak day, streak, and Longest turn sit right of Ordinary usage.

Keep owner-private SQLite `activity/daily.sqlite` apart from expiring quota snapshots.
Authoritative Codex responses set per-account daily totals; newer values replace older ones, even
lower or zero; omitted days stay. Local token events set project and day totals on UTC days.
Count cumulative-counter increases, not repeated last-turn counters. Thread IDs remove archived
or copied duplicates; unknown forks or reset records mark totals incomplete. Shared project totals
serve history and cleanup, not selected account statistics. Record daily shared-home provenance
and retain no messages.
Incremental scans, restarts, source deletion, and cache clearing never erase or duplicate totals.
One background monitor coalesces active and archived chat and thread-metadata bursts.
After its first full scan, parse only verified JSONL appends. Replacement, truncation, or unsafe
boundaries force a full parse. Read metadata only on database or WAL changes. A hidden, unchanged
app scans nothing.

Selected-account token totals sit in Daily activity's fixed-height period line; tooltip and
accessibility give exact counts, and late prices never shift content. Weekly, Monthly, and Yearly
are rolling 7, 30, and 365 UTC days including today, with no filter or source label. Hide Daily
activity until history exists, then keep zeroes. The TUI uses the same periods and data.

Codex popover rows may add one token summary for the Settings period: Since reset (default; the
weekly start when duration and reset time are known, else Weekly), Today, Yesterday, Weekly,
Monthly, or Yearly; hide a zero row. Beside tokens, show an API-equivalent value when the shared
Codex config's model has published prices (LiteLLM catalog, cached 24 hours), labeled an
input-rate equivalent, never billed cost; help shows model, cached-input, input, and output values.

Each account's More menu has checkmarked **Show in Menubar** and Use Settings default. It controls popover and
tray visibility, persists by UUID, and leaves main-window usage unchanged. After service order and
visibility, the tray takes six enabled, verified accounts with cached limits. A 12-point monochrome
glyph precedes each service's percentages. Defaults never reorder. Name signed-out or uncached
accounts in the tooltip; an empty tray shows the Switch mark. Disabled usage has no refresh or
placeholder; enabling never activates an account. Codex uses its 5-hour limit, else weekly.
Left subtracts used percent from 100, stopping at zero. Glyphs add no network work.
Inactive accounts keep their own cached usage when live reads are unavailable.

Drag service headers in the popover or Accounts. Each whole group accepts drops and moves live
with a short animation, disabled by Reduce Motion. Save each move by provider id for both lists
and tray glyphs. New services append; accounts keep saved order. Foreign text does nothing.
Header eye buttons change tray visibility only; popover rows remain. Save visibility by provider id;
account preferences still apply. Hover fades in the right-hand eye in 180 ms. Hidden services keep
a dimmed eye.slash. Symbols replace; Reduce Motion uses fades. Controls never shift rows.

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
  Use monospaced digits for numbers, monospace only for paths and IDs. Usage bars are 4 pt
  brand-color capsules, red from 90% used; unknown values have empty grey tracks. For 75 providers,
  use official logo colors, else sites or product UI. Adjust lightness per appearance for 3:1 card contrast.
  Black and white brands (Grok, OpenCode Go, Vercel, others) use #8E8E93 light and #98989D dark.
- **Geometry (points):** Use margins 20, card gaps 12, radius 10, and inset 16.
  Titles, columns, rows, and separators share the inset; headers stay within cards.
  Title rows are 44 tall: Section title left, Secondary count or accent "View … →" right.
  Rows are 36 tall with hairlines. Push buttons are 28 tall in cards and 22 in tables;
  icon buttons are square. Inner tiles keep 16 at each edge and below,
  12 between tiles, and radius 6.
- **Window:** Use a translucent 220 pt sidebar, 52 pt unified title bar, and empty system toolbar.
  Content stays 1200 pt wide. Open at 900 pt high or less on shorter screens; resize from 800 pt.
  Green zoom fills screen height at that width, without full screen. Traffic lights use the
  system inset and align with "Switch" and the top row.
  Sidebar symbols: Overview `house.fill`, Accounts `person.2.fill`,
  Settings `gearshape.fill`, Maintenance `wrench.and.screwdriver.fill`, Conversations
  `ellipsis.message.fill`. The top row runs Add, More, then a 300 pt ⌘K search; cards end there.
- **Search:** keeps text per window, filters Accounts or Settings (synonyms too), and under 3
  matches adds an end card of the other kind. Other pages: a drop-down.
- **Loading:** Match card and row sizes with shimmer skeletons, static under Reduce Motion. Show empty states after loading.
- **Messages:** Show silent macOS notifications, including while frontmost; none when disabled.
  Pages have no message card. Errors use the red bar below the top row
  with Copy and Dismiss. Preview and isolated checks never notify.
- **Overview:** Switch accounts on Accounts. Overview has no focused-account card or table.
  Remember Week or Month and Accounts, Models, or
  Projects. Six cards show (1) tokens, estimated cost, active accounts, and busiest day;
  (2) daily grouped-token streams; (3) a one-year all-account Activity heatmap. Only used days show a hand pointer and open a
  dated sheet ("Saturday, October 3"); dragging and empty days do nothing. The sheet shows token,
  cost, and session totals; a stacked cost bar with an Account or Model legend in brand and palette colors; and each session's title, tool, start time,
  tokens, and cost. Only Codex sessions link to surviving transcripts in Conversations. Removed
  transcripts are dim and inert with "Transcript removed". Without session data, show totals,
  the split, and centered "No sessions on this Mac for this day. The totals come from the account's
  usage report."
  Done or Escape closes the sheet. Trends (4) shows daily group ridgelines scaled to each peak in
  a fixed-height card, names in a one-line legend below. Continuous charts (Tokens per day,
  Trends) run edge to edge; bar charts, titles, legends, and axis labels keep the inset.
  Opaque tooltips sit above legends and read "Claude Code · account". Share of tokens (5)
  uses a 20 by 10 grid (200 half-percent cells),
  whole-percent labels, and "<1%" for one cell. The grid takes 40%; after a 24 pt gap,
  legend rows take 60%, span grid and card height, and measure 20 to 28 pt each.
  Maintenance (6) shows recent backups (time, source, size, state) and Open Backup or setup.
  Use uiarc.dev chart styles, hover values, a faint date axis, and one palette. Fold groups past six into "Other".
  Account legends, tooltips, and day-sheet cost splits prefix labels with 13 pt tool brand tiles
  to distinguish matching emails. Model and project groups have no tile.
  Keep the Tokens per day legend on one line; shorten all names with "…" together when needed.
  Fill at launch when accounts load. Count Codex, Claude Code, Droid, and Grok Build. Unknown account history (Claude
  Code's shared ~/.claude, Droid, Grok Build) goes to the tool's sole saved account. With zero or
  two or more accounts, show "<Tool> (shared)"; never drop it. Droid history uses
  `~/.factory/sessions/*/<id>.settings.json` totals on its last-change day. Compute local history
  and the activity ledger off the main actor. Explain empty groups in place.
- **Accounts:** The table sits above the selected account card. It shows a 44 pt icon tile, name
  without picker, provider with Active dot or badge, primary window, and Make Default, Open
  <tool>, Copy, and More. Missing usage leaves dotted meters and dashes in the card's right-side
  space. One grey reason ("No Go plan", "Couldn't check usage: <reason>") appears in the card and
  Usage header, without orange text or an empty band. Signed-out accounts use
  "Sign in again" as the primary action. Unreadable Droid logins show "Allow access to see usage"
  in the usage column; Allow replaces the default marker, and the card shows Allow access. The
  table has no column header or Provider column. Provider headers are 32 pt with a 16 pt brand
  tile, semibold name, and plain secondary count ("×2"). The card header has no account total.
  Indent accounts 24 pt under providers; a thin guide line joins the tile to account elbows like
  Finder. Groups have a 6 pt gap and no zebra fill. Row separators start at the indent and stay
  lighter than card borders. The usage column has a bar and "83% · 6d 19h" (percent then reset).
  Without usage, a reason such as "Sign in to see usage" replaces the bar and dashes. The default
  is a framed disabled button like Safari's Set Default: "Default" in the table and "Using as
  default" in the card, with no green, accent color, or check.
- **Conversations, Maintenance, Settings:** Share cards, rows, and buttons.
  Maintenance puts Cleanup then Backup in 28 pt controls with 120 pt segments, aligned with card
  starts. Icons use label colors. Cleanup's source picker sits at the bar's right end.
- **Stability and focus:** The global ui-quality "Owner taste" rules apply: no shift, rings, or
  rims; neutral dark selection; original brand tiles; even insets; still scrolling. Every
  scroll view (pages, sheets, Add Account dialogs, popovers, pickers, text views) hides system
  indicators and draws a thin gutter bar without track or border. It hides at rest, fades in over
  150 ms on scroll or gutter entry, and grows from 4 to 6 pt. Hover or drag widens it to 8 pt and
  brightens it. It fades out over 300 ms, 1 s after scroll or pointer exit. Mouse and trackpad
  scroll anywhere on pages, lists, messages, and gutters. Restore a saved offset once, on entry.
  Pages are eager stacks in an AppKit scroll view below a fixed header; chart hovers pause while
  it scrolls. Accounts rows share one hover and drop target.
- **Motion:** Fade hover and press; fill bars on appearance and change; roll numbers; fade cards
  without moving on page change; slide segment indicators; spring popover rows open; draw charts
  in. Use 150-350 ms with ease-out or a soft spring. Reduce Motion keeps fades only. Show the
  first page-switch frame without delay; run heavy work off the main actor. Motion runs once per
  page load; content scrolling into view stays still.
- **Menu bar popover:** 360 pt wide; omit app name, brand headers, token band, column header,
  session explanation, and Add Account. Above 80% of screen height, scroll rows above the fixed
  footer. One or two accounts never clip. Omit absent or hidden limits; never invent them.
  Use less transparency than default material; Dark Mode stays near #262628. Separators are
  half-opacity hairlines faded at both ends. Headers, rows, and footer have 12 pt insets.
  Expand only for buttons or hidden lines; idle rows have no fill. Expanded and focused fills use
  primary color at 0.06 opacity; hover uses 0.04. Hover extends 4 pt sideways and below and 6 pt
  above names, without touching headers or moving rows. Keep native contrast and primary label
  icons. Flat Sequoia buttons stay 24 pt tall with radius 5 pt. Expansion keeps earlier rows fixed;
  height and content animate together without dropped frames, including Low Power Mode.
  Service headers show a brand tile and name; account rows omit both.
  A default-checkmark column precedes row text. Credits, balance, and tokens with API value start
  at the bar column on one line. Use full window names (Session, Weekly, Monthly); extra pools
  such as Droid Core and Fable have headings above their rows. Show reported windows, including
  unknown values, subject to plan and hidden-row choices. Keep name, bar, percentage, and reset
  columns fixed. Click to expand windows, model buckets, credits, Switch, and Open <tool>.
  Signed-out accounts show "Sign in again to see usage" and Sign in at right, bottom-aligned
  with expanded buttons. Droid uses the Accounts access text and action. Context menus offer
  Switch, Open <tool>, Refresh, and Copy name. Footer: Open Switch (Command-O) left; Refresh,
  Quit (power), Settings right, 6 pt apart. Refresh checks enabled accounts in saved order,
  without activation or dismissal. Disable Refresh during checks; keep its space.
- **Behavior kept:** Clicking paths copies them with brief Copied feedback; Preview never uses
  the real clipboard. Icon actions have accessible names and keyboard focus. Reduce Transparency
  follows the system. Preview data is synthetic.

Before deleting a default, activate an eligible saved fallback: selected other account, previous
selection, most recently used, then first available. Confirmation names it; failed activation
keeps the account. Without a fallback, Delete account stays disabled with its normal label.
Conversations and settings stay.

Background reconciliation never disables UI or republishes unchanged values. Secondary text
names provider (Codex CLI); badges mean action needed. A badge is a grey chip with label-color
text and a 6 pt state-color dot; its text reaches 4.5:1 in both appearances.

Add Account and Advanced Import use native sheets: provider search and a single-choice list
(double-click continues) lead to the form or sign-in page, with Cancel, Continue, and a small step
indicator at every step.

## 5. Terminal distribution

`ai-manager` opens the terminal UI without arguments; `make tui` is the checkout entry.
Ship the compiled Apple Silicon macOS executable as `@smdl/switch`: npx opens the UI; global
install exposes `switch` and the `ai-manager` alias. The root README covers all three.
The package adds no account logic or Swift build step.

Use **09 Amber Menu**: compact provider groups, one inverse selected row, selected account limits.
Every action, including confirmed deletion, shows full text after a compact glyph. Use only bold,
dim, and inverse ANSI, terminal colors, no appearance detection; piped output and `NO_COLOR` are
plain. The animated loader runs during initial refresh and clears before the menu. Show cached
limits; never invent usage. Attached terminals use raw input: Up and Down move; Right or Enter
opens an account; Enter runs an action; Left or Escape returns; no command letters. Restore normal
input for paths, launched Codex, and exit. Keep lines at column zero in common terminals.

## 6. Verification contract

Use synthetic credentials and isolated homes for tests. Before UI installation, pass the Mac GUI
contract, production and Preview model checks, System, Light, and Dark snapshots, lintapple
(section 4), and full native gate. Core or CLI changes pass both Linux Docker architectures
without privileges or writes. Public releases are Developer ID signed and notarized
(`release-macos.sh --xcode`). Keep install copy short, with no Gatekeeper warning blocks.

Build, validate, and upload Mac archives on the maintainer's Mac, never GitHub Actions. The README
links the current Switch download; older releases are not Switch. Lead with provider-neutral
switching. Put paths, session behavior, and limits in concise provider notes.

Before installed-app GUI actions, match packaged and `/Applications/Switch.app` executable SHA-256,
embedded and committed revisions, and the running binary inode. Fix stale processes or
checksum mismatches before clicking; record proof in the install receipt.
