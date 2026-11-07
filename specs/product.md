# Switch product specification

Behavior: this spec. Work/evidence: ignored `goals.md`/`goals.archive.md`.

Icon: owner's red emergency-stop switch on ivory for Dock/Spotlight/MacPowerToys/window;
original vector for menu-bar template.

## 1. Product model

Switch manages Codex CLI, Grok Build, Droid (Factory), and Claude Code authentication snapshots;
section 1a covers other providers.

Codex uses `~/.codex`. Check identity and digest, then atomically replace only `auth.json` from
saved private credentials. Keep all non-authentication state, including configuration, instructions,
skills, plugins, conversations, and databases. Running processes keep credentials in memory;
new sessions use the selected account.

Private credentials: `~/.switch/codex/<account-uuid>.json`. Application support holds registry,
usage cache, transactions, backups, and recovery metadata. Never store raw authentication in SQLite.

Grok Build uses `~/.grok` or `$GROK_HOME`. Atomically replace only `auth.json`; retain
configuration/rules/plugins/MCP credentials/sessions. Support subscription OAuth (`oidc` and
first-party external OAuth), not `XAI_API_KEY`. Save credentials in
`~/.switch/grok-build/<account-uuid>.json`. Add Account runs `grok login --oauth` in private
temporary `GROK_HOME`. Failed loopback: send a code/full callback URL once to the waiting official
CLI; never save it. Grok hot-reloads auth, so existing processes may switch on their next API call.

Droid/Factory.app share `$FACTORY_HOME_OVERRIDE/.factory`, else `~/.factory`. Auth store:
`auth.v2.loginkeychain`, or `auth.v2.file` plus `auth.v2.key` without keyring. One fixed Keychain
key encrypts all logins. Save outgoing files, honor `auth.v2.write.lock`, and atomically replace
only auth files from private `~/.switch/droid/<account-uuid>/`. Keep sessions/settings/history.
Droid reads on demand; new requests use the selected account. Confirm switching when Factory.app/
droid uses the live home or process home is unknown; default Cancel. Only a usage click may prompt
once for the shared Keychain key; never prompt in background. Decrypt access tokens in memory;
never write the key, decrypted login, or refreshed token. First import existing login without
sign-in. Add Account runs Terminal `/login` with private temporary `FACTORY_HOME_OVERRIDE`, one
Droid login at a time. Existing Factory login supplies the key. While Factory.app works, live
tests use droid in a separate override home, never `~/.factory`.

Bind all ordinary Droid conversations after managed or observed external account changes.
Change only the first header's `organizationId`; preserve IDs, owner, settings, paths, dates,
and every body byte. Read the current organization from one native empty session, then remove it.
Never infer an organization from labels or reuse a prior repair's ID. Keep running-process
confirmation; defer writes while Droid or Factory is active. Persist unfinished work across
restart; retry on activation and refresh after writers stop. Reject unsafe paths and recover interrupted
writes. Report pending, updated, unchanged, skipped, and failed work separately from login success.
Local metadata changes do not transfer cloud missions or running tools.

Droid identities are opaque. Name imports and sign-ins ("Droid 1"); offer Rename… in row and
More menus (1-100 characters, off in Privacy mode). Keep login, default, usage key, and missions
keyed by account ID. Confirm the target name before account-scoped sign-in, even with equal masks.
Run `droid doctor --auth --json` on the login's own home (staging for sign-in, live for import),
with `FACTORY_HOME_OVERRIDE` and matching `FACTORY_DISABLE_KEYRING`. Prefer Factory.app's bundled
droid. Never probe a copy: refresh can spend a rotating token and sign Factory.app out.
Passing `auth.verify` adds a masked email. Changed hints reject re-sign-in and discard staging,
preserving the account. Warn about duplicate masks unless tokens' `sub` claims prove distinct
people (read without a prompt; ignore expiry). Failed or unknown doctor output falls back to
named accounts with a stated limit. Only the active default refreshes live files through guarded
switching; others refresh saved copies. `/api/billing/limits` and
`/api/organization/subscription/usage` use the access token. After expiry, wait for droid to
refresh; Switch never refreshes it. Optional per-account Factory API keys use the existing usage
provider as fallback. The generic Factory API-key provider keeps its own default.
Publish the nonempty write-lock directory by rename. Its 0600 `owner.json` holds a random token
and PID. Honor `.reclaim`; never remove another writer's lock.

Droid mission plans/progress live in `~/.factory/missions/<session id>/`; only the starting
account can resume their leader/worker Factory sessions. List missions under Droid, newest first:
title (mission.md's first heading), "131 of 160 done", owner, created date, and state on hover.
Record new missions' known defaults in `droid-missions.json`; offer Set owner for others.
Resume uses Terminal, the working directory, and `droid --resume <id>`, guarded-switching to a
different saved owner first. Start here confirms, writes done/remaining features to a plan, and
runs `droid exec --mission -f <plan> --auto high` on the default. Post one notice when leaving
unfinished missions' owner. Never edit mission files or call Factory's mission API.

Claude profiles keep stable separate `CLAUDE_CONFIG_DIR` paths and sign-ins. Claude owns
credentials/Keychain entries; Switch never copies/parses them. `~/.switch/claude/active` selects
the Switch/host-app default; opt-in shell integration also selects plain `claude`, else its login
stays. Symlink shared `~/.claude` projects/history.jsonl/settings.json/CLAUDE.md/commands/agents/
skills/plugins and similar items; keep `.claude.json`, `.credentials.json`, and policy caches
per profile. Back up/merge without overwriting before linking. Usage reads a file access token
read-only, else CLI `/usage`, at most every ten minutes/profile. Never spend refresh tokens.
Show an uncached Allow hint when a pending Switch privacy prompt blocks the CLI.

## 1a. Generic providers

Switch adapts OpenUsage and CodexBar usage providers without macOS Keychain or browser
cookie stores. Each `ProviderSpec` uses one of two credential styles:

- **Files**: The official CLI or app owns credential files, shared JSON members, or database
  key and value rows, such as `~/.gemini/oauth_creds.json`, OpenCode auth.json's `opencode-go`,
  or Cursor's `cursorAuth/*`. Switching keeps the newest ten live-byte backups per provider,
  saves outgoing and rotated tokens (including unsaved logins), then replaces the complete login,
  clearing absent optional fields. Other data, conversations, and settings stay. Run official Terminal
  sign-in in a private temporary home; import its login. "Import current
  sign-in" saves the live login. At launch and refresh, Droid and OpenCode Go
  import each distinct unsaved live login once as default. Skip equal Droid masks (unless token subjects differ) and never
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

Credentials: `~/.switch/<provider>/<account-uuid>.json` (0600); index/backups:
application support `provider-accounts/`. Files usage must not spend CLI-held refresh tokens.
Vault-only accounts may refresh/save tokens. Replace refreshed live bytes only if unchanged.

Conversation continuity is an account-switch contract, not a usage-provider claim. Verify the
native authentication change and original history together. Keep local history outside credential
snapshots. Distinguish usage-only selection and local viewing from native resume; never promise
cross-account access to provider-owned cloud history without a supported provider mechanism.

Usage: rate windows (share, reset, duration), money (spend, limit, balance), details, plan, identity.
The first window drives menu-bar percentage; omit missing values. Require HTTPS except loopback,
RFC 1918, and `.local` gateways. Never follow cross-host redirects.

Exclude hooks, QuickJS, browser cookie import, Keychain reads, keepalive, adaptive refresh,
agent sessions, widgets, iCloud, Sparkle, telemetry, local HTTP API, proxy settings, merge-icons,
and providers requiring them.

Codex/Grok defaults match live credentials; Claude's default selects Switch-launched sessions.
Switch/delete defaults stay provider-scoped. The TUI keeps provider groups, order, and default marks.

Existing-account "Sign in" binds an isolated session to its account ID. A mismatched identity
discards the home and reports both identities; a match atomically refreshes only that credential.
Only active defaults update live auth through same-identity switching. Never signal running CLIs.
"Add account" stays provider-scoped.

After restart, sign-in uses auth-only import's staging identity, digest, and transaction checks;
unrelated Codex processes cannot block it. Retire metadata when process ownership ends; cancel
only owned processes. On restart/refresh, delete retired staging only after home-scoped checks
prove no writer. Keep active, unknown, and recovery homes. Retired IDs cannot return pending or re-import.

Full imports, legacy settings repair, and recovery check writers in affected homes and shared
symlink targets. Identify Codex processes by held home-scoped runtime locks, never environment
or credentials. Verified unrelated homes do not block. Missing, inaccessible, or unknown
ownership evidence blocks destructive changes; unlocked stale files are not writers.

## 2. Navigation and Settings

Sidebar/View menu: Overview, Accounts, Settings, Maintenance (cleanup/backup/recovery),
Conversations. Command+, opens Settings. Persist page/tab, per-page account, scroll, filters,
chart period/grouping, cleanup source/range, backup source/destination, conversation selection,
and expanded popover rows. "When Switch opens": Last place (default) or Overview.
Settings order: General (Open at Login, Minimize to menu bar, When Switch opens, Menu shortcut),
Appearance (System/Light/Dark, Usage percentage, Reset times, Time format), Accounts (Show full
email addresses, Hide email addresses, Privacy mode, Check provider status, Claude terminals),
Auto switch, Menu bar, Notifications, Data locations, Reset. Full emails default off:
"ada@mail.co.uk" becomes "ada@mail".

1. **App behavior** includes Open at Login (off by default, macOS login-item service, quiet
   menu-bar launch, approval link to Login Items).
   **Reset times** offers Countdown (default) or Exact time; **Time format** offers Auto, 12-hour,
   or 24-hour. Reset text uses them: "Resets in 2h 5m", "Resets 5:30 PM", or "tomorrow",
   a weekday, or a date beyond today. Clicking toggles the choice everywhere; hover shows the other.
   **Usage percentage**: Left (default, "90% left") or Used ("10% used"); persist text/fill across
   meters, popover, tray, tooltips, and accessibility. Clicking any percentage toggles all.
   **Menu shortcut** records Command, Option, or Control plus a key; Delete clears it. It is off
   by default and toggles the popover from anywhere.
   **Refresh when the menu opens** is off by default.
   **Reset settings** confirms separately. It resets Settings choices, account Menubar and hidden
   rows, and the shortcut; it keeps accounts, sign-ins, placement, and Open at Login.
2. **Data locations** shows the Codex and Grok Build homes and vaults (section 1) with Reveal.
3. **Menu bar defaults** has Show account usage on by default; explicit overrides survive changes.
   **One account per service** (off by default) keeps one tray account per service: the default
   account, else the first shown one. Popover rows stay.
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
Combine app, project folders (multi-select), title text, and last-write date filters, including OpenCode JSON and SQLite sessions. Dates offer
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
chats from removal review; safe files remain available. Before OpenCode SQLite removal, save a database snapshot, then remove only selected sessions in one transaction. Restore selected rows without replacing other sessions.
Use a native range pop-up, nested row alignment, group headings, and totals beside Review.

Backup lists tool sizes and last backups, including Claude profiles. Checked tools share one
folder, schedule (off/daily/weekly), and retention count, with separate subfolders/history.
Full snapshots copy changes, hard-link unchanged files, and publish by temporary-folder rename
with a manifest (path, bytes, modified time, SHA-256). Prompt-only mode includes Copilot/OpenCode:
timestamped user prompts in order, one Markdown file per conversation under each project, with
title, date, app, and index. Exclude responses, tools, login files, and settings; reuse the folder,
schedule, and retention. Restore prompts only to a folder. Restore full backups wholly or partly,
in place after a safety snapshot or elsewhere. Login files and full OpenCode database snapshots
need opt-in. Never delete sources; prune only Switch snapshots. Wait and explain missing destinations.

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

Daily charts (30 days/native span) return id/title/unit/dated points. Draw 72-point bars/series
below windows; header shows title and total or hovered/focused day. VoiceOver: "30 days, total
$12.40, peak $2.10 on Oct 3". Use for Claude's 30-day cost. Show full first/middle/last dates on
30-day axes; clamp end labels inside card insets. No menu-card charts.
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

Daily activity: responsive GitHub-style year calendar in one Canvas; Sunday weeks, exact-day
pointer/arrow-key/accessibility selection. Persist Today/Yesterday/Weekly/Monthly/Yearly (default)
for range/total/intensity. Changing account never activates, waits, or shows prior data. Redraws
never reload Dock icons; index at utility priority. Selected days show date/exact tokens.
Lifetime, Peak day, streak, Longest turn sit right of Ordinary usage.

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

Drag service headers in the popover and Accounts. The group follows the pointer; siblings use a short
spring unless Reduce Motion is on. Save provider order on release for both lists and tray glyphs.
New services append; account order stays. Foreign drags do nothing. VoiceOver offers Move up/down.
Acceptance uses only window-local events.
Header eye buttons change tray visibility only; popover rows remain. Save visibility by provider id;
account preferences still apply. Hover fades in the right-hand eye in 180 ms. Hidden services keep
a dimmed eye.slash. Symbols replace; Reduce Motion uses fades. Controls never shift rows.
Each account row (popover and Accounts) has a smaller eye in its reserved trailing slot that hides
only that account from the tray, saved by account id. It follows the header eye's hover, fade, and
dimmed eye.slash rules; the row context menu and VoiceOver offer Hide from/Show in menu bar.

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
- **Overview:** No focused-account card/table; switching stays on Accounts. Persist Week/Month
  and Accounts/Models/Projects. Six cards:
  1. Tokens, estimated cost, active accounts, busiest day.
  2. Daily grouped-token streams.
  3. One-year all-account Activity heatmap. Used days alone get hand pointers and dated sheets
     ("Saturday, October 3"); ignore drags/empty days. Sheets show token/cost/session totals,
     a stacked cost bar (Account/Model legend, brand/palette colors), and session title/tool/start/
     tokens/cost. Only surviving Codex transcripts link to Conversations. Removed ones are dim,
     inert, labeled "Transcript removed". Without sessions show totals, split, and centered
     "No sessions on this Mac for this day. The totals come from the account's usage report."
     Done/Escape closes.
  4. Trends: daily group ridgelines scaled to each peak, fixed-height card, one-line legend below.
  5. Share of tokens: 20x10 half-percent cells, whole-percent labels ("<1%" for one cell), grid
     40%, gap 24 pt, legend 60%. Legend spans grid/card height with 20-28 pt rows.
  6. Maintenance: recent backup time/source/size/state, Open Backup or setup.
  Tokens per day/Trends run edge to edge; bars, titles, legends, and axis labels keep insets.
  Opaque tooltips above legends say "Claude Code · account". Use uiarc.dev charts, hover values,
  faint date axes, one palette, and "Other" beyond six groups. Prefix account legends/tooltips/
  day-sheet cost splits with 13 pt tool brand tiles; omit tiles for models/projects. Keep Tokens
  per day legends on one line; truncate all names with "…" together. Fill when accounts load.
  Count Codex/Claude Code/Droid/Grok Build. Attribute unknown shared history to a tool's sole
  saved account, else "<Tool> (shared)"; never drop it. Droid uses
  `~/.factory/sessions/*/<id>.settings.json` totals on the last-change day. Compute local history
  and activity off the main actor. Explain empty groups in place.
- **Accounts:** Table above selected-account card. Card: 44 pt icon tile, name without picker,
  provider with Active dot/badge, primary window, Make Default, Open <tool>, Copy, More.
  Missing usage: dotted meters/dashes in the card's right space; one grey reason ("No Go plan",
  "Couldn't check usage: <reason>") in card/Usage header, no orange or empty band. Signed-out
  primary action: "Sign in again". Unreadable Droid: "Allow access to see usage" in usage column,
  Allow instead of default marker, Allow access in card. No table headers/Provider column.
  Provider headers: 32 pt, 16 pt brand tile, semibold name, secondary "×2" count; no card total.
  Accounts indent 24 pt; Finder-like guide line joins tile to elbows. Groups: 6 pt gaps, no zebra
  fill. Separators start at indent, lighter than card borders. Usage: bar and "83% · 6d 19h"
  (percent/reset), or reason ("Sign in to see usage") replacing bar/dashes. Default: framed
  disabled Safari-style button, "Default" in table, "Using as default" in card; no green/accent/check.
- **Conversations, Maintenance, Settings:** Share cards, rows, and buttons.
  Maintenance puts Cleanup then Backup in 28 pt controls with 120 pt segments, aligned with card
  starts. Icons use label colors. Cleanup's source picker sits at the bar's right end.
- **Stability and focus:** Apply global ui-quality "Owner taste": no shift/rings/rims; neutral
  dark selection, original brand tiles, even insets, still scrolling. All scroll views
  (pages/sheets/Add Account/popovers/pickers/text) replace system indicators with trackless,
  borderless gutter bars. Hidden at rest; scroll/gutter entry fades in over 150 ms, 4 to 6 pt.
  Hover/drag brightens and widens to 8 pt. Fade out over 300 ms, 1 s after scroll/pointer exit.
  Mouse/trackpad scroll pages/lists/messages/gutters anywhere. Restore offsets once on entry.
  Pages: eager stacks in AppKit scroll views below fixed headers; pause chart hovers while
  scrolling. Accounts rows share one hover/drop target.
- **Motion:** Fade hover/press; fill bars on appearance/change; roll numbers; fade cards without
  movement on page changes; slide segment indicators; spring popover rows open; draw charts in.
  Use 150-350 ms ease-out/soft spring; Reduce Motion keeps fades only. Show first page-switch
  frame immediately; move heavy work off main actor. Animate once per page load, never on scroll entry.
- **Menu bar popover:** 360 pt wide. Omit app name, brand headers, token band, column header,
  session explanation, Add Account, and absent/hidden limits. Beyond 80% screen height, scroll
  rows above fixed footer; never clip one/two accounts. Reduce default-material transparency;
  Dark near #262628. Half-opacity hairlines fade at both ends. Insets: 12 pt throughout.
  Expand only for buttons/hidden lines. Idle/default/expanded rows have no fill; only checkmark
  marks default. Focus: primary fill 0.06; hover: 0.04, extends 4 pt sides/below and 6 pt above
  names, without touching headers/shifting rows. Keep native contrast/primary-label icons.
  Flat Sequoia buttons: 24 pt high, radius 5. Keep earlier rows fixed during expansion; animate
  height/content together without dropped frames, including Low Power Mode. Service headers
  alone show brand tile/name. Default-checkmark column precedes text. Credits/balance/tokens
  with API value start at bar column, one line. Full window names: Session/Weekly/Monthly;
  extra pools (Droid Core/Fable) get headings. Show reported windows, including unknown values,
  subject to plan/hidden-row choices. Fix name/bar/percentage/reset columns. Click expands
  windows, model buckets, credits, Switch, Open <tool>. Signed-out: "Sign in again to see usage",
  Sign in right/bottom-aligned with expanded buttons. Droid reuses Accounts access text/action.
  Context menu: Switch, Open <tool>, Refresh, Copy name. Footer: Open Switch (Command-O) left;
  Refresh, Quit (power), Settings right, 6 pt gaps. Refresh enabled accounts in saved order without
  activation/dismissal; disable Refresh during checks without changing its space.
- **Behavior kept:** Clicking paths copies them with brief Copied feedback; Preview never uses
  the real clipboard. Icon actions have accessible names and keyboard focus. Reduce Transparency
  follows the system. Preview data is synthetic.

Before deleting a default, activate an eligible saved fallback: selected other account, previous
selection, most recently used, then first available. Confirmation names it; failed activation
keeps the account. Without a fallback, Delete account stays disabled with its normal label.
Conversations and settings stay.

Background reconciliation keeps UI enabled and publishes only changes. Secondary text names
providers (Codex CLI). Action badges: grey chip, label-color text (4.5:1 both appearances),
6 pt state-color dot.

Add Account/Advanced Import use native sheets: provider search, single-choice list (double-click
continues), then form/sign-in. Every step has Cancel, Continue, and a small step indicator.

## 5. Terminal distribution

`ai-manager` opens the terminal UI; `make tui` runs source. Ship Apple Silicon macOS as
`@smdl/switch`: npx opens it; global installs expose `switch` and `ai-manager`.
Document all three. Add no account logic or Swift build step to the package.

Keep CLI and core operations aligned: account naming and order, login code submission,
all-provider usage, Droid continuity reports, conversations, missions, backups, Cleanup, Claude shell
integration, and one-shot automatic account selection. Use the same validation, writer guards, and
recovery checks as the app. Require confirmation for mutations; accept secrets through standard input.
GUI appearance, menu-bar preferences, notifications, and background scheduling remain app settings.
Report versions without opening account stores. Document standalone updates;
app installation must not imply an older PATH command was updated.

Use **09 Amber Menu**: compact provider groups, inverse selection, account limits.
Every action, including confirmed deletion, has full text after a glyph. Use bold,
dim, and inverse ANSI with terminal colors; no appearance detection. Piped output and `NO_COLOR` are
plain. Animate the loader during initial refresh; clear it before the menu. Show cached
limits; never invent usage. Attached terminals use raw input: Up and Down move; Right or Enter
opens an account; Enter runs an action; Left or Escape returns; no command letters. Restore normal
input for paths, launched Codex, and exit. Keep lines at column zero in common terminals.

## 6. Verification contract

Use synthetic credentials and isolated test homes. Before UI installation, pass the Mac GUI
contract, production and Preview model checks, System, Light, and Dark snapshots, lintapple
(section 4), and full native gate. Core or CLI changes pass both Linux Docker architectures
without privileges or writes. Public releases are Developer ID signed and notarized
(`release-macos.sh --xcode`). Keep install copy short, with no Gatekeeper warning blocks.

Build and validate Mac archives locally; upload from the Mac, not Actions.
README uses site styling, real screenshots, short copy, limits, and current downloads.
Cover: Clear center geometry; large hero type, copy open. Keep glyphs, light fill, 6px cutouts, demo/still.
Collapse requirements. One command installs Mac app/CLI or Linux CLI; check hashes.
Site hero: "Keep your local conversations." About links to mandalsuraj.com.

Memory: free main window/pages on close or hide; login launches build no window.
Page hosts receive named environment values, never outer `EnvironmentValues` (its tracker grows
per update). Fail the memory check for a surviving closed window or tracker growth over 1 MB
in 200 updates/page.

Before installed-app GUI actions, match package/install (`/Applications/Switch.app`) SHA-256,
source revisions, and running binary inode. Fix stale processes or hashes before clicking;
record proof in the install receipt.
