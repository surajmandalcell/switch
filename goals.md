# Switch: native macOS Codex account manager

Status: local release-candidate gates passed; the exact clean installation is recorded by
the final receipt named in the closeout evidence. The installed app uses the real shared core.
Only an uninstalled compile-time Preview build may use in-memory demo data. Public direct
distribution remains blocked on a Developer ID Application identity and notarization.
Decision date: 2026-09-11.
Design revision: 2026-09-17. The current product contract is
[`docs/specs/product.md`](docs/specs/product.md); this file retains milestone history and
verification evidence.

### Active completion ledger (2026-09-17)

This ledger owns unfinished work in the current continuation. Historical milestone entries
below are evidence of their recorded revisions, not a claim that newer requirements passed.

- [x] Account controls: magnifying-glass check, single-tick Set as Default, double-tick
  Using as default with reapply enabled; surface missing-snapshot usage errors and prevent
  an enabled refresh action from silently losing a concurrent request.
- [x] Align returned summary facts at the right of the authentication/ordinary-usage row.
- [x] Persist the activity range, initially one year; enlarge Daily activity by 20%.
- [ ] Copy displayed paths on click with a brief nonmoving Copied confirmation.
- [ ] Retain durable daily account and project usage summaries independently of source
  conversations and rebuildable caches, with repeated-scan/restart/deletion checks.
- [ ] Configurable content/titlebar translucency, initially 25% with a 0–50% range,
  respecting Reduce Transparency and keeping text and controls fully legible.
- [ ] Close the current native and both Linux architecture gates, then install the exact
  clean signed build and verify the installed revision and stable single-instance launch.

Advanced Cleanup remains explicitly deferred. Public distribution still requires an external
Developer ID Application identity and notarization; local development signing is not that gate.

Account refinement verification: the focused Preview model check passed, including a
nonselected-row account check. Native System/Light/Dark contracts passed, including initial
refresh errors, sign-in presentation, explicit-zero quotas, and credits-only responses.

### Switch product identity refinement (2026-09-13)

The macOS product name is **Switch**. Package the production bundle as `Switch.app`.
Build the in-memory design variant as an uninstalled `Switch.app` in a separate Preview
build directory. Use Switch in window titles, menus, menu-bar actions, errors,
documentation, release archives, and acceptance paths.
Preserve the existing bundle identifiers, `AIManager` Swift targets and executable,
`ai-manager` CLI command, application-support directory, and window autosave key so the
rename keeps installed data, scripts, single-instance behavior, and window placement.
Remove the installed IIA Directeur bundles after the exact signed Switch bundles verify.

### Release-candidate audit requirements (2026-09-12)

The closeout evidence records the full surface and operation inventory, confirmed fixes,
and clean-checkout gates. One passing change or acceptance script alone does not satisfy
these requirements.

- Replace the current Dock, Spotlight, rail, and menu-bar artwork with one clear,
  licensed account-manager mark. It must stay legible at 16, 22, 44, 256, and 1024 pixels.
  The Dock artwork needs restrained macOS depth and edge light without a glossy effect.
- The earlier lighter-graphite direction is superseded. Use the darker neutral macOS palette
  in `docs/specs/product.md`, while preserving the custom Recap Pro geometry, density,
  translucency, and three-point component corners.
  Audit every surface, overlay, hover, selected, pressed, disabled, warning, and error state
  in both themes. Keep normal text at WCAG AA contrast or better.
- Replace scattered animation timings with one restrained motion system. Pointer feedback
  must begin at once, use fill or icon changes that preserve layout, remain interruptible,
  and honor Reduce Motion. Audit navigation, rows, buttons, window controls, theme changes,
  scrollbars, the import wizard, notices, and modal transitions. Idle surfaces stay still.
- Confirm all production GUI actions through `AccountManager` with synthetic credentials and
  temporary roots. Preview remains side-effect free. Tests must not read or write the user's
  Codex homes or login Keychain.
- Support the native GUI on macOS. Support `AIManagerCore` and `ai-manager` on macOS and
  Linux. Add a clean Linux Docker gate for the core tests, CLI build, CLI acceptance flow,
  SQLite, permissions, symlinks, and an isolated runtime smoke test. Do not claim that the
  AppKit GUI runs on Linux.
- Audit tracked and ignored repository residue. Remove obsolete empty legacy directories,
  stale build output, and conflicting active documentation while preserving recovery backups,
  private test copies, Git history, and the one canonical build cache.
- Rebuild, package, and install the exact clean macOS candidate only after both platform
  matrices pass. Verify the installed revision, hashes, signature, launch, duplicate-instance
  behavior, and isolated account flow. Public release remains blocked until Developer ID and
  notarization gates pass.

### Current design-review build

Copy the current Recap Pro v2 Producer UI from
`/Volumes/External1TB/dev/organization/keypath.india/recap-pro` as the visual
source of truth: its 48px rail, 48px titlebar, dense typography, 3px component
corners, panel/list structure, exact light/dark tokens, and interaction styling.
Preserve native custom close/minimize controls and safe window lifecycle. Adapt
the reference to account-management content.

Typography refinement (2026-09-15): use bundled Inter for interface, reading, and display
text, and PT Mono only for paths, identifiers, and measurements. This supersedes the earlier
Geist and Lora typography requirements.

Latest refinement (2026-09-12): the window is fixed at 1120x740, without resize
or maximize. Its custom title region must drag reliably. Light/dark switching
must work repeatedly. Default mouse/keyboard focus shows no outlines; an explicit
accessibility focus-indicator preference may enable them. Use established SF
Symbols instead of hand-drawn icons. Align the page title and subtitle on their
text baseline, increase title-cell horizontal padding, simplify the title
decoration, and make the top-right refresh icon background-free. Disabled primary
buttons must remain legible. Refine the entire import wizard and close/minimize
hover behavior. All scrolling regions use very thin overlay scrollbars, visible
only while their region is hovered or scrolling. These refinements supersede
conflicting reference geometry or earlier resize/focus-outline requirements.

For design review, the compile-time Preview build runs entirely on in-memory mock
accounts, discovery, import/review/results, settings, verification, launch, switching,
and recovery. No real account manager, credential discovery, filesystem mutation,
Terminal/Finder launch, clipboard mutation, or network request is allowed through
Preview actions. Keep all pages and states reachable with sample data. The installed
GUI uses the production core with fail-closed errors.

App identity refinement (2026-09-12): add coordinated Dock and menu-bar icons
using Recap Pro Producer's charcoal tile and off-white mark treatment. Use a
simple manager/account mark from an established licensed glyph, with no hand-drawn
SVG paths. Keep the menu-bar version monochrome and legible at native size.
Use the same mark in the app rail, and package it in both GUI builds. Menu-bar
actions only show the demo window or quit; account operations remain mocked.

Native polish refinement (2026-09-12): finish the light palette across every
surface and state; replace the current robot mark with a simpler licensed-glyph
composition and add a restrained edge highlight to Dock and Spotlight artwork.
Remove the Recovery rail gap, align page titles to the content grid, remove the
extra title-bar control, keep Close visible, and reveal Minimize only on hover.
Add a persistent Minimize to Menu Bar setting with predictable close/minimize/menu
behavior. Apply restrained interruptible micro-interactions, honor reduced
motion, and keep rendering work GPU-friendly. Verify that account switching
changes only authentication while configuration, sessions, history, skills,
and other shared Codex state remain untouched; base this contract on current
official Codex behavior and a broad survey of major account-switching tools.
Automated account tests must use synthetic credentials and isolated temporary
homes. The GUI remains an in-memory demo while its design is under review.
Repository baseline: `e7bb55bf2dea7c05072d85481aa5652ab4cdfe16` on `master`.

Modal and provider refinement (2026-09-12): use one 48-point square control geometry
for the window Close, window Minimize, and import-modal Close buttons. Minimize sits
behind Close at rest and folds out beside it on hover, with an interruptible reduced-motion
fallback and no layout shift. Modal titles and outer content share a 24-point edge;
panel headings and their rows share a 16-point internal edge. The import flow names Codex
as the provider without putting roadmap language in the interface. Persist an explicit
Codex provider identifier in new account data and decode pre-provider registries as Codex
without changing existing account behavior. Keep the core data model open to later providers.

Layout refinement (2026-09-12): the page title and every page body use the same 24-point
leading and trailing edge inside the content pane. The overlaid Minimize control reserves
no layout space. The titlebar is 48 points high, matching the Close and Minimize cells.
Panel-title art keeps the full available width and uses Recap Pro's restrained trailing
concentric-arc pattern without changing title or content geometry.

Import and rail refinement (2026-09-12): keep Close mounted on a stable rail surface and
animate only its red hover tint. Keep Minimize mounted behind it and animate only Minimize's
offset and opacity, so entering Close cannot flash or shift layout. The rail's existing
one-point trailing divider stays continuous through the control row; do not draw a second
line. The import wizard exposes Codex as the selected provider and labels the native chooser
for an explicit Codex home folder or `auth.json`. A chosen source stays unchanged.

Credential-vault refinement (2026-09-13): remove the decorative lower-rail brand mark; it
has no action and is separate from the real macOS menu-bar item. Keep one normal live Codex
home at `~/.codex`. Store each saved Codex authentication record as a private regular file at
`~/.switch/codex/<account-UUID>.json`, with `0700` parent directories and `0600` files. Never
make live `~/.codex/auth.json` a symbolic link or hard link. A switch captures a refreshed
outgoing live credential into its saved record, stages and atomically replaces the live file
with the selected record, verifies identity and digest, then commits registry metadata. A
legacy managed credential must migrate into the vault without deleting its source until the
new file and registry both verify. `~/.codex2` and other named Codex homes are import sources,
not runtime requirements. Settings, sessions, history, skills, plugins, and databases stay in
the shared live home. Opening Codex first activates the selected record and then launches the
normal live home; an already-running Codex process keeps its old in-memory authentication.

Preview and icon refinement (2026-09-13): ship and install only the production `Switch.app`.
The installed executable must contain no demo data, demo paths, mock actions, or Preview entry
point. `scripts/launch-switch.sh --preview` may build and launch an uninstalled `Switch.app`
with the `AI_MANAGER_PREVIEW` compile condition. Keep its bundle identifier and build directory
separate so it cannot replace or lock the production app. Use the user-provided icon #17 balanced
mark for the app icon and its heavier menu-bar mark for the AppKit template. Generate explicit
light and dark app-icon treatments from those supplied paths, preserve their geometry, and test
the final 16, 22, 44, 256, and 1024 pixel outputs. Record the supplied archive digest and asset
provenance without adding the reference board or source exploration images to the app bundle.

Native menu and icon-shape refinement (2026-09-13): install a complete macOS menu bar in
both production and compile-time Preview. The application menu includes About Switch,
Settings with Command+,, Services, Hide, Hide Others, Show All, and Quit. Command+, must
bring the main window forward and navigate its existing content pane to Settings.
File, Edit, View, Window, and Help use native selectors and key equivalents where macOS owns
the behavior; View exposes Accounts, Settings, Chat History, and Recovery without
adding another navigation shell. Keep the fixed-window and custom-window-control contracts.
Replace the current asymmetric icon trace with a clean vector derived from the supplied
reference silhouette: four balanced outer lobes, one upper-right circular cutout, and one
lower-left open-ring cutout. Compare faithful, symmetry-corrected, and tiny-size candidates,
then ship the closest symmetric mark that remains clear at 16, 22, 44, and 256 pixels.

Icon trace review correction (2026-09-13): the earlier hand-fit vector is not accepted as
an accurate copy of the supplied raster. Before replacing the production asset again, keep a
standalone HTML review at `docs/design/switch-icon-trace-preview.html`. It must embed the
supplied image and every candidate locally, place the source and selected vector on the same
coordinates for split and overlay comparison, show actual-size 16, 22, 32, 44, and 64 pixel
samples, and allow the selected SVG to be downloaded. Include a direct Potrace fidelity trace,
three symmetry-strength options whose counters remain pixel-derived, and the rejected previous
build for comparison. The review must make no network requests. Production artwork changes only
after a candidate is selected from this review.

Icon selection (2026-09-13): **Pixel trace** is approved. Use that exact traced silhouette for
the Dock, Spotlight, in-app mark, and menu-bar template. Context-specific padding and color are
allowed; reconstructing, smoothing, widening, or otherwise changing its outline or counters is
not. Retire the previous fourfold hand-fit mark and the menu-bar optical geometry.

Icon composition and import-layout refinement (2026-09-13): keep the approved pixel trace exact,
but scale its Dock and Spotlight treatment to a 520-point foreground box and offset that box to
center the trace by visible mass on the 1024-point canvas. This supersedes the rejected 640-point
composition, whose foreground still occupied 76% of the tile width. Use a neutral near-black tile
whose gradient stops have equal red, green, and blue channels. Light must run from `#292929` to
`#171717`; Dark must run from `#232323` to `#111111`. Reduce the painted edge highlight to a quiet
one-point rim with no more than 0.07 opacity in Light or 0.05 in Dark; the mark remains crisp and
unblurred. The import modal uses a 48-point titlebar with a dedicated 48 by 48 trailing Close
cell that touches the top and trailing modal edges. The step indicator must end before that cell and
never share its layout region. Close changes to red on hover. Modal title and content share the
24-point outer grid; panel rows share the 16-point inner grid; source controls align to their first
text line; and 16-point group spacing separates the provider, source, scope, explanation, and
actions. Use a 780 by 648-point modal at the fixed 1120 by 740 window size so all three standard
source rows remain visible without compressing the section rhythm.

Dock top-sheen refinement (2026-09-13): keep the approved Pixel trace, tile geometry, neutral-black
palette, one-point rim, and lower shading unchanged. Add one shallow white highlight that starts at
the top of the tile and fades completely before its midpoint. Cap it at 0.035 opacity in Light and
0.028 in Dark so the top gains a little depth without returning to the rejected glossy treatment.

Account onboarding, usage, and compact-menu refinement (2026-09-14): replace the normal import-first
experience with one **Add account** flow. On launch, when the registry is empty, recover existing
transactions and adopt a valid regular file-based ChatGPT credential already present in the live
`~/.codex` home. Adoption copies authentication into the private UUID vault, marks that identity as
the default, and leaves the live credential, settings, chats, databases, and links unchanged. It is
idempotent and fails closed on missing, malformed, symbolic-linked, hard-linked, non-private, or
unresolved credentials. An existing nonempty registry is never silently rewritten.

The Add provider catalog appears in the fixed order Codex CLI, Claude Code, Gemini CLI, and
Antigravity CLI. Codex CLI is enabled. The other three rows are visibly disabled and say
`WIP`; they have stable provider identifiers but no behavioral adapters, credential access,
or process actions in this release. Selecting Codex creates a private versioned login session under
the application-support staging root, with an isolated `CODEX_HOME` and file-backed credential
storage. It starts the official Codex browser login without changing the live home. The CLI opens
the default browser itself; Switch keeps its output private and does not add a terminal window. **Check now**
validates the staged regular `auth.json`, identifies the account, and commits it through the existing
auth-only import transaction. Restarting Switch resumes a waiting or interrupted login session.
Cancellation removes only app-owned staging after validation. Never put email addresses in vault or
staging paths; use opaque operation and account UUIDs. Never store raw authentication in SQLite.

Keep the existing source-selection, reimport, settings-and-chat merge, conflict, manifest, storage,
and external-link paths under **Advanced Import**. The normal Add flow exposes none of those choices.
All digest checks, private permissions, containment rules, writer checks, atomic publication,
outgoing-token capture, backups, rollback, and conflict recovery remain mandatory in both paths.

Use the installed Codex app-server account interface for non-secret account details and statistics:
`account/read`, `account/rateLimits/read`, and `account/usage/read`. These calls do not send a model
prompt. Store bounded timestamped account and rate-limit samples in SQLite, never tokens or raw
app-server traffic. Refresh on explicit request and a coalesced cache policy; do not poll while the
app is closed. Missing optional backend fields are omitted and are never inferred from transcript token
counts. Account pages show the returned cached breakdown and retain explicit core empty/error states.
The menu bar reads the same cache and never
starts filesystem enumeration, credential validation, network work, or transcript parsing when it
opens.

Replace the static status-item menu with one transient vertical popover using the existing visual
system. It is 360 points wide and between 192 and `min(536, visible screen height - 96)` points tall.
The status item itself shows the template mark plus the cached primary used percentage, such as
`42%`; it stays icon-only when that value is unavailable, and its tooltip states that the percentage
is used quota. Updating this label never changes the popover width or starts a refresh.
Six 60-point account rows remain visible before the list scrolls; the header, new-account action,
session-boundary note, Open Switch, and Quit remain fixed. Each row shows identity, workspace or
verification, a compact cached quota value when available, and the active check. Clicking a verified
inactive row switches once, keeps the popover open during work, and closes after success. The active
row is a no-op; errors stay copyable. A switch never kills Codex and states that it applies to new
sessions. The provider chooser is reachable from the popover and the main Accounts page.

Account trust and action refinement (2026-09-14): treat only the live `~/.codex/auth.json` as the
automatic first-run account source. Do not infer current accounts from renamed legacy snapshots such
as `auth.json.*`; those files remain explicit Advanced Import sources. **Check account** first validates
the selected UUID vault file, including its identity, digest, ownership, permissions, and regular-file
status. It then uses a disposable private `CODEX_HOME` to ask Codex for account and usage data without
sending a model request. A missing CLI, timeout, launch failure, or optional account-service failure
must keep a valid file `Verified locally`; only a malformed saved credential, an explicit authentication
response, or a returned identity mismatch may set `Needs sign-in`. A successful account read may
replace a provisional display email with the canonical returned email.

Every account row has a right-click menu for Use, Open, Check, Copy auth path, and Delete. The detail
actions expose the same Delete operation beside Copy auth path. Deletion requires a clear destructive
confirmation, removes only the UUID-owned managed home, vault credential, and registry record, leaves
the original import source and shared `~/.codex` data unchanged, and recovers after interruption. The
default account requires an explicit saved replacement before deletion. The CLI exposes the same
transaction as `ai-manager remove` with confirmation and structured output.

Open Codex performs any required account switch inside Switch before opening Terminal, so a known
switch failure stays in the app instead of opening a command file that immediately exits. Opening the
already selected default accepts a refreshed live token when its account identity still matches and
does not require writer detection. The Add Account modal does not reload when Switch regains focus. Its four provider rows use
unchanged official OpenAI, Anthropic, Gemini, and Antigravity artwork with recorded source URLs and
digests; the disabled providers remain inert.

Wizard, switching, and saved-usage refinement (2026-09-14): the ordinary Add Account provider step
is the provider list itself. Remove the introductory heading, explanatory sentence, and redundant
`Providers` panel title; keep the list aligned to the modal content grid and let it use the available
height. Disabled provider badges say `WIP`. All wizard steps keep one stable titlebar, body, notice,
and action geometry so loading, focus changes, validation, errors, and step changes do not move
controls. Instructions describe the selected account as applying to new Codex sessions.

Choosing a default atomically replaces the live credential for new sessions even when existing Codex
processes are running. It never terminates or edits an existing session. Preserve transaction,
identity, digest, backup, and recovery checks, but do not block a user-requested default change merely
because a Codex process exists elsewhere on the machine. Every saved UUID credential can run the
isolated non-model account and rate-limit check without becoming the default. Fresh imports and
inactive accounts expose Refresh usage. `account/read` means signed in whenever it returns a ChatGPT
account object; `requiresOpenaiAuth` describes whether the selected provider needs OpenAI auth and is
not a signed-out signal while that account object exists. A successful current usage snapshot and a
Needs sign-in badge must never be shown together.

Chat filtering refinement (2026-09-14): parse bounded visible transcript entries into Prompts,
Responses, Tools, and Other. Tools includes calls and returned output; Other contains visible
reasoning summaries and supported non-chat events, never encrypted reasoning or raw secret-bearing
records. The reader can enable any combination, applies message search after the role filter, and
persists the selected categories across launches. Copy filtered exports exactly the currently
filtered messages in chronological order with stable role labels and timestamps. Empty filter and
search states remain recoverable without reparsing the transcript.

Menu-bar refinement (2026-09-14): compare ten static directions before implementation and retain the
review sheet under the canonical build artifacts. Select the direction that best supports immediate
account switching and quota scanning. The production popover opens without an appearance animation,
uses a flat surface, three-point corners, sharper internal geometry, bounded screen-aware dimensions,
and stable spacing in empty, loading, error, and populated states.

Contrast and chat-reader refinement (2026-09-14): stop deriving alternating rows from translucent
overlays. Use explicit `listStripe`, `listHover`, and `listSelection` colors; the normal dark stripe is
`#424348` over the `#3B3C40` panel, with `#4A4B50` hover and `#505158` selection. Apply the same ordered
base, stripe, hover, busy, and selection states to every account and conversation list. Dark controls
must remain distinct from every panel in idle, hover, pressed, selected, and disabled states.

Keep conversation rows at 50 points with only the canonical title and project or folder. Redesign the
reader as a hybrid conversation: compact trailing user bubbles and leading open Codex reading blocks
with a two-point role rail. Put each timestamp beside its role, expose copy on hover and keyboard
focus, and shape paragraphs, headings, lists, quotes, dividers, links, and code blocks away from the
main actor. Code uses an independently scrollable monospaced surface and a copy action. Bound and
cache prepared presentation by thread and file signature; preserve the existing virtual tables,
cancellation, full-text search, and raw-message copy behavior.

Mac window-placement and package naming correction (2026-09-13): persist the selected display and
the window's top-left offset within that display's visible frame. Restore both on the next launch,
including displays with negative desktop coordinates and displays whose desktop position changed.
Clamp the fixed window into the saved display's current visible frame. If that display is absent,
center safely on an available display without overwriting the saved external-display preference
until the user moves the window. Replace the generic AppKit frame-autosave-only implementation and
test a secondary-display restore contract with synthetic screen frames. Name the macOS-only UI
module and package `Mac GUI` and `packages/mac-gui`; retain `packages/tui` as the macOS and Linux CLI
plus interactive terminal interface.

Navigation and chat-history refinement (2026-09-13, revised 2026-09-14): order the rail and View
menu as Accounts,
Backup, Chat History, and Settings. Rename the user-facing Recovery page and its copy to
Backup while preserving the existing internal recovery transaction contract. Command+, opens
Settings. Use an established chat-bubble SF Symbol for Chat History at 75% of the standard
rail-glyph size while preserving its 48-point hit target. The history page exposes separate thread
and message search, a virtual thread list,
and readable messages from the shared Codex transcript library without a status badge. Enumerate
only regular JSONL files below `sessions` and `archived_sessions`, never follow symbolic links, and
keep the existing 500,000-entry bound. Stream records instead of loading whole transcript files.
Refresh the incremental file-signature cache after the first load only when coalesced file-system
events arrive, decode only changed files on a bounded set of utility-priority workers, debounce both
searches, load selected-thread messages away from the SwiftUI main actor, and cancel obsolete work.
Main-actor updates contain only prepared view data.
Every actionable warning offers a copy action, and warning groups offer one bulk copy action. Expected
scope exclusions stay visible in the import manifest but do not create warning cards; warnings are
reserved for conditions that need attention, such as an active source or a symbolic-link review.

## 1. The outcome

Build one reliable workflow: import Codex accounts and choose which account Codex uses.
Ship it as a native macOS app. Support Codex only in this release and name Codex where
the user must choose or understand the provider-specific operation.
Use the same settings across accounts by default.
Use a merged chat library so the resume picker can find history from either account.
Offer two import modes: **Auth only** and **Auth, settings, and chats**.
Protect existing credentials, skills, rules, settings, and conversations before any replacement.

The user should finish with a working account, reusable settings, and recoverable history.
A new account row alone does not prove success.

```text
Existing Codex home or auth.json
  -> inspect without changing it
  -> choose import mode
  -> review destination and any conflicts
  -> back up affected data
  -> import and verify
  -> choose account
  -> launch Codex with that account
```

The current request authorizes implementation through G6, including GUI and CLI workflows.
Use `packages/core` for shared Swift contracts and account operations, `packages/mac-gui`
for the native SwiftUI app, and `packages/tui` for the command-line and interactive terminal interface.
Both interfaces must use the same core operations and contract tests.
Use isolated temporary homes with synthetic credentials for automated mutation tests.
The user also authorizes a protected copy of `~/.codex` outside the repository for
real-format validation; never mutate the original or follow copied links back into it.
Do not execute imported hooks or commands, access the login Keychain, or spend model
usage during offline verification. Preserve private test data outside version control.
Implementation delegation uses Sol at normal (medium) effort and Luna for routine tasks.
Do not present the existing Electron gateway as the completed native app.

## 2. Start here in the implementation session

1. Read this file and `AGENTS.md` before changing the repository.
2. Inspect the current branch and working tree. Preserve unrelated work.
3. Complete G1 before implementing account mutations.
4. Build G2 through G5 as working vertical slices.
5. Complete failure recovery and native acceptance before declaring v1 done.
6. Update this file with evidence at each completed milestone.

Use the existing checkout. Branch creation or worktree creation needs the user's explicit request.
Keep commits small and review the complete staged diff before each commit.
Do not push the inherited branch-deletion workflow. G1 removes it first.

## 3. First principles

### Account identity and configuration are different things

An account chooses the identity used for a provider request.
Configuration chooses behavior such as models, instructions, tools, and permissions.
Changing accounts should not reset those choices.

Derivation:

```text
User wants another account
  -> account credential changes
  -> config, rules, skills stay the same
  -> separate credentials + shared settings
```

An email is a display label, not a reliable unique account key.
Use the available account and workspace identity fields together with the authentication mode.
Two workspaces for the same email must not collapse into one account.
Missing identity fields require an explicit unresolved state, not a guessed match.

### A Codex home contains several kinds of data

`CODEX_HOME` normally groups credentials, configuration, transcripts, databases, caches, and runtime files.
Copying the directory without classifying it copies host dependencies and locks too.

Separate data by ownership and meaning:

- Credentials belong to an account and may change when Codex refreshes tokens.
- Settings belong to the user and can be shared intentionally.
- Transcripts record conversations and need preservation.
- Database indexes help Codex find and resume those conversations.
- Runtime locks and caches belong to a process or installation.
- Orca and Super workspace layouts belong to those apps.

### Import is a transaction, not a recursive overwrite

A source may be active, incomplete, linked elsewhere, or on another volume.
A successful copy can still contain broken paths or mismatched database state.

Therefore, import needs a plan, a backup, a staging directory, validation, and a recoverable commit.
The original source stays intact after success.
Source cleanup is not part of v1.

### Local evidence and online authentication are different

Decoding a token can identify a claimed account. It does not validate a token signature or prove server access.
A present credential file does not prove that refresh will succeed.
A copied transcript does not prove that the installed Codex version can resume it.

Use distinct states for **Imported**, **Needs sign-in**, and **Verified with Codex**.
Show the time and method of verification.
Do not send a model request during discovery or silently spend account usage.

### Account switching has a process boundary

Changing a file does not change credentials already held by a running process.
An external client may also use its own `CODEX_HOME`.

```text
Use for new sessions -> atomically activates saved auth in the live home
Open Codex -> activates when needed, then launches the same live CODEX_HOME
Existing process -> continues until stopped or restarted
External custom home -> remains owned by that client
```

The UI must state this boundary beside the switch action.
Do not report that Orca, Super, or every terminal has switched automatically.

## 4. Scope and deliberate exclusions

### Required for v1

- Native macOS account list and account detail.
- Discover the default home, `~/.codex2`, and Orca account homes.
- Let the user select another home or an `auth.json` file.
- Import authentication only.
- Import authentication with settings and chat data.
- Identify duplicate accounts and preserve separate workspaces.
- Reuse shared settings across imported accounts.
- Merge chat libraries and make the merged history discoverable from the shared live home.
- Switch the account used by future Codex sessions in the live home.
- Activate a selected account and launch a new Codex session in that same home.
- Back up, verify, report conflicts, and recover failed mutations.
- Show missing CLI, missing credentials, permission errors, and unsupported data formats.

### Outside v1

- Windows, mobile, a browser frontend, and a Linux GUI. The shared core and terminal
  interface remain supported on Linux.
- Operational Claude Code, Gemini CLI, or Antigravity CLI adapters; their disabled provider-catalog
  rows are in scope. API routing, provider conversion, and automatic failover remain excluded.
- A proxy server, background daemon, pricing, or a cross-provider usage dashboard. Bounded cached
  Codex account, rate-limit, and token-activity snapshots are in scope.
- A chat editor, model client, terminal emulator, or orchestration system.
- Cloud synchronization, encrypted export archives, or a team account service.
- Automatic cross-account live sharing of SQLite databases.
- Importing Orca tabs, layouts, orchestration state, or Super workspace records.
- A new OAuth implementation or silent access to the user's login Keychain.
- An app updater, plugin system, or automatic CLI installation.

Retaining an old feature behind a hidden toggle does not satisfy this scope.
The v1 executable and navigation must contain only the account workflow.

## 5. What exists in this repository

The baseline is named Subscription Proxy Inator in its source and packaging.
It is an Electron and React desktop gateway, not a native Codex account manager.

| Existing area | Current purpose | v1 treatment |
| --- | --- | --- |
| `desktop/main`, `desktop/preload`, `desktop/renderer` | Electron application | Replace with a native app target |
| `src/domain/routing`, `src/domain/protocol` | Routing and protocol conversion | Remove from the v1 product |
| `src/providers`, proxy and usage services | Multiple providers and local HTTP | Remove from the v1 product |
| `src/infrastructure/config-store.js` | Serialized writes and atomic replacement | Reuse the transaction reasoning, not a Node runtime |
| `src/application/provider-configuration-service.js` | Credential change ordering | Read its failure cases before implementing native storage |
| `src/infrastructure/secret-store.js` | Electron storage and encryption fallback | Do not port or invoke on real credentials |
| `tests/` | Gateway contracts | Retire obsolete contracts with their features |
| `docs/adr/0003-credential-transactions.md` | Separate-file commit ordering | Preserve the principle in native import and switching |
| `.github/workflows/desktop-ci.yml` | Cross-platform build and branch deletion | Replace with macOS validation and remove branch deletion |
| `.github/workflows/release.yml` | Cross-platform publication | Replace before any native release |
| `README.md`, `docs/`, `website/` | Gateway documentation | Replace or clearly retire conflicting product claims |

The current CI deletes every non-default remote branch on a push to `master`.
Do not execute that behavior as a side effect of this pivot.
The old development document requires that cleanup. This decision supersedes that requirement.

Git history already preserves the old product. Do not copy it into a permanent legacy application directory.
Preserve license and attribution obligations when reusing existing assets.
Do not migrate the old encrypted gateway vault into Codex accounts.

## 6. Local preparation already completed

This section records workstation preparation, not app functionality.
Do not hardcode these paths or account identities into the product.

- [x] Clone the repository under `/Volumes/External1TB/dev/personal/ai-manager`.
- [x] Back up main and source settings before creating links.
- [x] Preserve shared skill source directories in the private backup.
- [x] Copy the Orca Gmail account home to `~/.codex2`.
- [x] Keep its `auth.json` as a private regular file, separate from the main account.
- [x] Link eight settings entries to the corresponding entries under `~/.codex`.
- [x] Preserve 1,212 session transcript files in the new home.
- [x] Create consistent snapshots of six SQLite databases and check their integrity.
- [x] Rebase 408 indexed transcript paths to the new home and verify the files exist.
- [x] Make the copied standalone CLI release link independent of the Orca source path.
- [ ] Verify an online request or an interactive resumed chat using the new home.
- [ ] Register the new home in Super. This was not part of the preparation request.

```text
~/.codex                         ~/.codex2
  auth.json -> primary account     auth.json -> secondary account
  sessions  -> primary history     sessions  -> copied Gmail history
  databases -> primary state       databases -> independent snapshots
  settings  <--------------------- eight symbolic links
```

The shared entries are `config.toml`, `AGENTS.md`, `agents`, `rules`, `context`, `skills`, `plugins`, and `hooks.json`.
The original Orca home and main home were not edited.
That statement describes the initial copy. The shared-history follow-up below supersedes the separate-history layout.
The global `codex` executable still resolves into the original Orca installation.
The copied CLI under `~/.codex2/packages/standalone/current/bin/codex` reports version `0.154.0`.

The private backup is `~/.codex-profile-backups/20260911-081725`.
Its README explains preserved link targets and restoration boundaries.
Its `verify-codex2.sh` checks local auth separation, links, database integrity, and indexed transcript paths.
Never copy that backup, real auth, real settings, or real transcripts into this repository.

### Shared-history follow-up

The user clarified that both accounts must expose the merged history through `/resume`.
Settings alone were not enough. This is now part of the product requirement.

The follow-up backed up both homes under `~/.codex-profile-backups/20260911-085649-merge` before changing history or indexes.
It compared 2,555 transcript files by thread identity and replay content.
The comparison found 559 byte-identical duplicates and 401 equivalent histories with different serialization.
Four archived continuation segments belong to their original threads and remain intact.
Four cross-home divergent histories were preserved through native Codex forks, labeled `[Gmail alternate]`.

The main library gained 248 previously missing histories and four alternate forks.
Its existing transcript files were preserved.
Both homes now share transcript directories and lightweight history files through symbolic links.
Their SQLite files remain separate, initialized from consistent snapshots of the merged indexes.
Auth and shared configuration were not changed by this follow-up.
The shared config gained three Super project entries during the operation. Those concurrent updates were preserved.

```text
~/.codex  -> account one auth ----+
                               +-> shared sessions and archived sessions
~/.codex2 -> account two auth ---+

Each home -> its own SQLite indexes
Codex     -> scans shared files and repairs local discovery metadata
```

The shared history entries are `sessions`, `archived_sessions`, `history.jsonl`, and `session_index.jsonl`.
Archived conversations stay archived. Empty sessions and background threads retain Codex's normal visibility rules.
Use `codex resume --all` to search across working directories.
The private merge directory contains comparison manifests, original versions, fork lineage, and verification tools.
Hash checks verified all 1,343 original main-home transcripts and all 248 added transcripts against their source bytes.
Native Codex listings matched across both homes: 475 active entries and 92 archived entries at verification time.
Nine native metadata reads passed from each home, and one alternate's full turn history was read successfully.
The actual `codex resume --all` picker opened under `~/.codex2` and was exited without starting a model turn.

## 7. Native implementation shape

Use Swift and SwiftUI, with AppKit where a native file panel or application integration needs it.
Start with one macOS app target and one focused test target.
Use the installed SDK and document the selected deployment target before using newer APIs.
Working default: macOS 14 or later, with Apple Silicon as the first verified build.
The native GUI remains macOS-only. The shared core and terminal interface support macOS
and Linux. Intel GUI support needs a verified build before it is claimed.

Prefer Foundation file APIs, CryptoKit for hashes, and the system SQLite library for database snapshots.
Use a small JSON registry for app metadata. A second app-owned database is unnecessary for a few account records.
Use an actor to serialize app-owned mutations and an OS file lock to coordinate multiple app processes.
That lock does not prevent an external Codex process from writing.

Start with cohesive responsibilities, not a mandatory class hierarchy:

```text
SwiftUI account list and import sheet
  -> account store: display state and operations
  -> file operations: inspect, back up, stage, commit, recover
  -> Codex process helper: locate CLI, validate, launch

Foundation + SQLite + filesystem
```

Split a type only when it has a separate invariant or real caller.
Persist provider identity with every account and source so stored data can distinguish
future providers. Keep Codex behavior cohesive while it is the only implementation;
add a behavioral provider interface and adapter only when a second provider exists.
Do not add factories, dependency injection frameworks, or a generic migration engine.
Tests can inject temporary roots and a process runner at the actual side-effect boundaries.

Use a direct-distribution macOS app as the initial packaging target.
Document entitlements and file-access behavior in the native project.
Do not request Full Disk Access, Accessibility, or Automation merely to read an ordinary selected folder.
If a selected path is denied, explain that failure and let the user choose another path.

## 8. Storage and ownership

Proposed app-owned layout:

```text
~/Library/Application Support/AI Manager/
  accounts.json                   non-secret registry
  accounts/<local-id>/home/
    legacy/full-import data       migration and recovery only; never launched
  backups/<operation-id>/          data needed for rollback
  transactions/<operation-id>.json non-secret recovery journal
  staging/<operation-id>/          unpublished destination

~/.switch/codex/
  <local-id>.json                 canonical saved account credential

~/.codex/                         default Codex home
  config.toml, rules, skills ...   default shared settings root
  auth.json                       regular live copy for new Codex processes
  sessions/, archived_sessions/   shared transcript library
  state_*.sqlite                  shared live indexes
```

The live `~/.codex` home is the only shared root in v1. Never derive storage names from
email strings.
Store credentials in Codex-compatible files with mode `0600`, inside private directories with mode `0700`.
Saved account records use `~/.switch/codex/<local-id>.json`; live `~/.codex/auth.json`
is atomically replaced from a saved record and is never linked to one.
Backups and staging use the same restrictions before any secret bytes are written.

Store only local record IDs, display identity, home URLs, source kind, verification state, and import metadata in the registry.
Keep raw credentials out of logs, errors, clipboard actions, process arguments, analytics, and support exports.
Pass paths and ordinary options through structured process arguments. Do not assemble shell commands from imported text.

The app must work with its own private file storage without consulting the login Keychain.
When a source uses Keychain-only auth, show an unsupported source state and direct the user to Codex's own sign-in flow.
Never run a Keychain probe to discover whether that source has credentials.

## 9. Discovery and account identity

Scan a bounded set of candidate locations after the user opens Import:

1. The default `~/.codex` directory.
2. The known secondary `~/.codex2` directory, if present.
3. Orca's `codex-accounts/*/home` directories under Application Support.
4. A folder or auth file explicitly selected by the user.

Do not crawl the entire home directory, browser profiles, or credential stores.
Super profiles that point to these same homes are not new accounts.
Canonicalize paths and track filesystem identity to avoid duplicate source rows and symlink cycles.

Show identity, source path, detected settings, history presence, and any inspection error.
Never display raw tokens, full configuration contents, or conversation text in the discovery list.
Credential metadata comes from bounded JSON and token parsing without network calls.
Treat decoded token claims as unverified display metadata.

Duplicate behavior:

- Exact account and workspace identity: offer update or merge into the existing account.
- Same email with different workspace identity: keep separate rows with workspace labels.
- Same canonical source path: show one source.
- Same account with different token bytes: do not infer which credential is newer from access-token expiry alone.
- Unknown identity: require verification or keep it unresolved before activation.

Do not merge two different accounts because their settings or transcript files match.
Support the documented file-based ChatGPT auth shape first.
Recognize API-key or unknown auth shapes and report their supported status explicitly.
Broader authentication mechanisms are not required to complete this subscription-account workflow.

## 10. Import contract

The import sheet has two primary choices:

| Choice | Account auth | Source settings | Source history | Result |
| --- | --- | --- | --- | --- |
| Auth only | Import | Leave source settings alone | Leave source chats alone | Account uses the selected shared settings |
| Auth, settings, and chats | Import | Review and reconcile | Copy and validate | Account uses shared settings and preserved history |

Importing does not activate the new account automatically.
After success, show **Use for new Codex sessions** and **Open Codex**.
The import result includes the destination, backup location, and any unresolved items.

### Settings policy

Accounts use one shared settings root unless the user explicitly chooses independent settings in a future scope change.
Full import cannot silently replace the settings used by every existing account.

Compare source settings with the shared root before committing:

- Same bytes: retain the live shared file.
- Source-only skill or rule: preview an addition to the shared root.
- Conflicting file: show Keep shared or Replace with imported for that file.
- Complex TOML difference: preserve the original and choose the whole file in v1.
- Mixed choices: resolve all required choices before starting the mutation.

Do not invent a partial TOML parser or perform text replacement across unknown config syntax.
If structured editing becomes required, choose a maintained parser based on concrete needs.
Preserve comments and unknown fields when passing through a selected file.

Show that applying imported shared settings affects every account launched from the live home.
Redact secret-looking values in previews, including MCP headers and environment values.
Treat hooks, skills, and MCP commands as executable configuration.
Preserving them does not authorize running them during import verification.

Treat a source setting that is itself a symbolic link as external data. Resolve it only after
explicit review, copy the reviewed contents into the live home, and never keep that external
link as part of the runtime account model.

### Data categories for full import

| Category | Examples | Handling |
| --- | --- | --- |
| Account credentials | `auth.json` | Private copy, format validation, separate from shared settings |
| User configuration | `config.toml`, `AGENTS.md`, `agents/`, `rules/`, `context/` | Back up and reconcile with shared settings |
| Skills and hooks | `skills/`, `hooks.json` | Preserve content and link targets, review before execution |
| Plugin configuration | manifests, enabled state, referenced assets | Classify credential-bearing data before sharing |
| Conversations | `sessions/`, `archived_sessions/`, referenced attachments | Preserve bytes and validate references |
| History discovery | `history.jsonl`, `session_index.jsonl`, state databases | Handle according to inspected Codex version |
| History projections | `thread_history_*.sqlite` | Snapshot or rebuild through verified Codex behavior |
| Durable auxiliary state | memories and goal data | Preserve only through a known, tested import path |
| Runtime state | locks, sockets, PID files, queues, temporary files | Exclude from active destination |
| Installation state | packages, model caches, logs, version caches | Exclude from product import, report exclusions |
| Host ownership | `.orca-*`, host-specific launch hooks | Retain in backup when needed, exclude from active destination |
| Unknown files | unclassified source entries | List explicitly and preserve in backup when selected |

The workstation preparation shared its existing `plugins` directory at the user's request.
The product must not assume every future plugin tree contains only shareable settings.
Classify it before offering the same operation to another user.

Full import means every selected durable category is accounted for.
Use **Imported with unresolved items** when a required category cannot be activated.
Do not label a partial import complete because auth worked.

## 11. Backup, staging, commit, and recovery

The backup gate applies before replacing an existing destination or shared setting.
An auth-only import into an empty account still needs private staging and a recoverable registry commit.

```text
Inspect -> Plan -> Back up -> Stage -> Validate -> Commit -> Verify
                        failure -> preserve old state + show recovery
```

### Before copying

1. Resolve source and destination paths and reject containment overlap.
2. Reject symlink loops, special devices, sockets, and path traversal.
3. Calculate required logical space without assuming APFS clone support.
4. Identify live source writers and active destination users.
5. Build a manifest of selected files, links, sizes, and destinations.
6. Verify the backup is readable before any replacement.

Back up skills and rules along with config and auth.
For linked content, preserve both the link and the selected target contents needed for restoration.
Do not chase arbitrary external symlinks without a bounded, reviewed target set.

Use APFS cloning when available, with ordinary copy as the supported fallback.
Place staging on the destination volume so final publication can use a local rename.
Copying from an external disk must not depend on cross-volume rename semantics.

### Consistency

Prefer a source that is not being written during full import.
SQLite's backup API produces a consistent database snapshot, including committed WAL content.
It does not make several databases and transcript files one atomic snapshot.
Check transcript manifests before and after copying and retry or pause when the source changes.
Never claim consistency merely because the `.sqlite` file copied successfully.

Take a bounded retry path for busy databases. Show the blocked source after the limit.
Do not kill the user's Codex processes to complete an import.

### Commit and recovery

Publish the staged saved credential and reviewed account data before adding its visible registry record.
A crash may leave an unreferenced staged home. It must not leave a registry row pointing to missing credentials.
Shared settings changes span multiple files and require explicit journal steps and backups.
An atomic rename of one file is not an atomic transaction across all files.

Record operation phases and non-secret destination identifiers in the recovery journal.
On restart, inspect the journal and actual filesystem state before continuing.
Restore only files whose state still matches the failed operation's expected output.
If a user changed a file afterward, preserve both versions and request a conflict choice.

Cancellation before commit leaves existing destinations untouched.
After commit starts, finish or roll back deterministically before allowing another mutation.
Report backup cleanup failures without converting a successful account import into a missing account.
Never automatically delete the only known-good backup.

## 12. Chat import and duplicate handling

Determine the installed Codex version and source data format before touching copied indexes.
Keep version-specific assumptions near the code that depends on them.
Prefer supported Codex listing, import, or resume mechanisms when they exist and are verified.
Do not assume a generic database rebuild command exists.

For the observed `0.154.0` source, `state_5.sqlite` contains `threads.rollout_path` with absolute file paths.
A raw home copy leaves those paths pointing back into Orca.
The local preparation required rebasing 408 rows to the new home.

Implement any necessary database rewrite only on a private snapshot with a recognized schema.
Use bound SQL values and an exact source-prefix comparison.
Keep working-directory history and historical message content unchanged.
Do not rewrite every path-looking string in a transcript.

Duplicate rules:

- Same thread identity and identical content: store one active copy.
- Strictly extended transcript with matching earlier content: retain the complete extension after validating record boundaries.
- Same identity with divergent content: preserve both and report a conflict.
- Same filename with different identity: treat as a collision, not a duplicate.
- Archived and active copies: preserve archive state and show any conflicting classification.

Do not choose a winner using only file modification time, file size, or filename.
Do not concatenate divergent JSONL files or invent new thread identifiers inside opaque formats.
An unresolved variant may remain in the protected backup until a supported resolution exists.

Test referenced attachments, image paths, archived sessions, history index entries, and missing project directories.
Report source paths that still matter before the user retires the source installation.
A missing working directory is a resume problem, not a reason to delete a transcript.

History must be merged into a shared transcript library while credentials remain separate.
The live home retains its SQLite files and indexes across every account switch.
Auth-only import leaves that shared library unchanged.
Full import adds the selected source history to that library after duplicate and conflict handling.
Switching preserves the same chat library for every account.
Verify both an existing merged chat and a newly added chat can be discovered after switching
the live credential between two accounts.

## 13. Account switching contract

Provide two distinct actions with accurate scope.

### Use by default

This changes authentication used by future launches that use the default Codex home.
It leaves default config, skills, rules, and chats in place.

1. Inspect default-home auth and reconcile its identity with the registry.
2. Check for live writers and unresolved previous operations.
3. Refuse the switch while an identified default-home Codex process is active.
4. If process ownership cannot be established, show that uncertainty instead of asserting safety.
5. Back up the outgoing auth and record the operation phase.
6. Capture the latest outgoing credential before replacing it.
7. Recheck file identity and content immediately before commit.
8. Atomically publish incoming auth with private permissions.
9. Verify the committed identity and record the selected default account.

An app lock does not coordinate third-party writers.
A compare-before-write check alone cannot eliminate every external race.
The first release must establish a documented quiescence requirement and test its enforcement.
Do not implement switching as unconditional `cp` over a live auth file.

Saved and live credentials can diverge after token refresh.
Capture a refreshed live credential into its saved record before switching away.
When two copies diverge without a reliable order, report a conflict or require a fresh Codex sign-in.
Do not overwrite a refreshed credential with an older imported snapshot.

Never implement switching through `codex logout`.
Logout can remove credentials and does not implement a safe local account selection.
Reject a symbolic or hard-linked live auth file. Back up and normalize only through a reviewed
operation with a clear ownership rule.

### Open Codex

Activate the selected saved credential, then launch Codex with the normal live `~/.codex` home
through a structured process environment. Refuse activation while that home may have a writer.
Use the native terminal or a small saved launch artifact, without building a terminal emulator.
The user starts the session deliberately. Do not type into an unrelated live terminal.

Expose the saved auth path for inspection, but do not describe it as a launchable profile home.
Hosts such as Super continue to use the shared live home after IIA Directeur activates an account.
Do not edit another app's live database or claim that its running sessions have changed accounts.

### Verify and sign in

Use the installed Codex command surface rather than implementing OAuth.
Force file-based auth in a disposable verification home when supported.
Ensure verification cannot fall through to the real login Keychain.
`codex login status` proves local credential presence, not successful server access.
An online check must be explicitly initiated and accurately labeled.

Sign-in requires the user's browser, password, passkey, device code, or other account action.
Stop at those interactions and preserve the current working account.

## 14. Native UI

Start with one window, an account list, and an import sheet.
Keep provider selectors and unrelated settings pages out of the product.

Design refinement, 2026-09-11: use a sleek, custom native interface inspired by IBM
Carbon's precise grid, typography, and restrained geometry, with macOS semantic colors
and dynamic light/dark surfaces. Apply this consistently to account, import, review,
progress, and result screens. Preserve native keyboard behavior and accessibility.
The latest refinement prioritizes UI completion first: fully custom window composition
and controls, with no decorative outlines or bordered panels. Use spacing, typography,
and tonal surfaces for hierarchy. Keyboard focus must remain visibly identifiable.

Latest user correction: use a compact, seamless two-pane layout. The translucent sidebar
and the content pane each extend from the top to the bottom of the window. Remove the
shared application header and bottom status bar, and remove repeated account/status copy.
Integrate a custom draggable titlebar into the panes. Use
consistent three-point corner radii on custom controls and surfaces, visible restrained
hover feedback, and native translucency with a readable reduced-transparency fallback.
Keep essential actions close to the selected account; shared paths belong in account
details rather than permanent window chrome.

Titlebar correction: replace the native traffic lights with custom close and minimize
buttons. Do not show a maximize or fullscreen control. Align both buttons and the app
title on one centerline, remove the sidebar account count, and remove the visible right
border at the sidebar edge. Keep all custom control corners at three points. The window
remains resizable, with a default size of 920 by 620 and an upper bound of twice those
dimensions, 1840 by 1240. Preserve the existing minimum size and the translucent panes.

Control-spacing refinement: join close and minimize edge-to-edge in one compact group,
with a larger gap before the title. Verify both buttons operate the owning window.
Use square outer window corners while retaining three-point corners on ordinary custom
controls. Keep the two-pane layout; no new navigation tabs are required.
Provide an explicitly named preview app with sample accounts and the complete existing
import/review/result flow. Reuse the isolated synthetic acceptance fixture so preview
imports, switching, and verification cannot change the user's production accounts.
The user-facing preview must never terminate on a test assertion. Report window-contract
failures as nonfatal diagnostics and keep failed checks visible to the test runner.
Do not relaunch a preview with a known crash while developing window changes.

The sidebar contains the window controls, a compact import action, and account rows.
The content pane contains the selected identity, launch/default actions, and concise
account details. Put verification, paths, shared settings, and recovery information
where they apply; do not repeat them in global header/footer chrome.

Import sheet sequence:

```text
Choose source
  -> Auth only / Auth, settings, and chats
  -> destination + shared-settings conflicts + backup summary
  -> Import
  -> verified result or specific recovery action
```

Make the final import button the confirmation for the concrete reviewed operation.
Do not stack generic confirmation dialogs after every reversible step.
Keep explicit choices for replacing shared data, changing credentials, and resolving divergent history.

Native controls must support keyboard navigation and meaningful accessibility labels.
The user rejected live VoiceOver verification as a delivery gate; do not start VoiceOver
or block this UI work on it. Preserve basic accessibility semantics in the implementation.
Use text as well as color for default account, warnings, and verification state.
Check light and dark appearance, larger text, reduced motion, and a narrow window.
Long paths and identity labels must remain readable and copyable without hiding primary actions.

Do not show a success toast while required files remain unverified.
Progress should use known file counts or bytes. Otherwise, use an indeterminate indicator.
Errors should name the failed action and the next useful action without dumping secrets.

## 15. Milestones and completion gates

### G0. Preparation and specification

- [x] Inspect the repository and identify the current gateway architecture.
- [x] Complete the requested secondary home preparation with backups.
- [x] Write this scope, file policy, acceptance gates, and handoff.
- [x] Record final documentation checks below. Commit this handoff after reviewing its complete staged diff.

### G1. Replace the product entry point

- [x] Remove inherited remote branch deletion before any implementation push.
- [x] Add the native macOS project with one app and one focused test target.
- [x] Choose deployment target, app identity, and one canonical build directory.
- [x] Replace active Electron packaging and multi-platform CI with macOS validation.
- [x] Retire gateway navigation, server startup, and conflicting product instructions.
- [x] Update app identity and repository URLs to IIA Directeur and this repository.

Done when a fresh checkout builds and opens the native account window without starting the old gateway.
The window must not require Node, Electron, a local HTTP server, or provider setup.
Do not publish a release during this milestone.

### G2. Read-only discovery

- [x] Inspect approved home locations without mutation or network access.
- [x] Parse supported auth metadata with bounded input handling.
- [x] Group exact duplicate sources and distinguish account workspaces.
- [x] Show missing auth, denied access, and unsupported formats.
- [x] Prove discovery makes no Keychain calls and writes no source files.

Done when temporary fixtures produce correct account rows and every failure has a usable state.
Use synthetic identity data. Keep real credentials out of fixtures.

### G3. Auth-only import and coordinated launch

- [x] Implement private staging, account publication, and registry recovery.
- [x] Preserve live shared settings unless the reviewed import explicitly replaces them.
- [x] Preserve the original source and verify permissions.
- [x] Handle duplicate-account auth updates without losing refreshed credentials.
- [x] Save the imported credential and provide a coordinated launch through the live home.
- [x] Show honest local verification and sign-in states.

Done when the native flow imports a fixture, atomically activates its saved credential, and
starts Codex against the same live home before another account operation can intervene.
A real-account smoke check requires explicit user participation and must not mutate unrelated auth.

### G4. Default-account switching

- [x] Preserve and reconcile the outgoing default credential.
- [x] Enforce writer checks and the documented quiescence requirement.
- [x] Commit incoming auth atomically and verify the selected identity.
- [x] Recover interruption before and after each transaction boundary.
- [x] Preserve config, rules, skills, and chat data byte-for-byte.
- [x] Handle auth symlinks, external changes, and token refresh conflicts.

Done when switching between two synthetic accounts changes only authorized auth and app metadata.
The old account remains recoverable. Running external sessions are not reported as switched.

### G5. Full import

- [x] Implement the reviewed file classification from section 10.
- [x] Back up source-linked skill and rule content before changing shared settings.
- [x] Resolve settings conflicts before mutation.
- [x] Snapshot supported databases and validate transcript consistency.
- [x] Preserve chat identity, archive state, references, and divergent copies.
- [x] Keep the live transcript library and indexes shared while account credentials change.
- [x] Verify the live home discovers imported chats and later additions after account switches.
- [x] Rebase recognized copied index paths without rewriting historical content.
- [x] Show all excluded or unsupported categories in the result.
- [x] Verify a supported imported conversation can resume through Codex.

Done when the full import flow preserves selected durable data and passes the migration acceptance matrix.
Saving files without a working discovery and resume path is not sufficient.

### G6. Recovery, accessibility, and installed app

- [x] Exercise rollback and restart recovery from interrupted operations.
- [x] Verify the redesigned native flow with keyboard navigation and accessibility labels.
- [x] Test denied paths, disconnected volumes, insufficient space, and corrupt sources.
- [x] Build the final signed app with the permitted existing signing identity.
- [x] Inspect the final artifact's entitlements and embedded source revision.
- [x] Install and verify the exact app only when implementation scope includes local installation.
- [x] Replace legacy user docs with the actual native workflow and its supported limits.
- [x] Run the Ponytail debt inventory and report every remaining marker.

Done when an installed native app completes both import modes and switching with recorded recovery evidence.
Publication and new account permissions remain separate user actions.

## 16. Acceptance matrix

Use focused native tests around data preservation and transaction boundaries.
Do not mirror every method with a test or retain obsolete gateway coverage targets for the new app.

| Scenario | Required observation |
| --- | --- |
| First launch without Codex | Useful empty state and CLI setup guidance |
| Valid auth-only import | Separate private auth, shared settings, source unchanged |
| Full import | Selected settings and history preserved, conflicts accounted for |
| Shared chat library | Both accounts discover the same merged user conversations |
| Later chat addition | Each home discovers it through native scanning without copying a live SQLite database |
| Duplicate account | Existing identity reused, credentials not overwritten blindly |
| Same email, different workspace | Two distinct account records |
| Broken auth or malformed token | No crash, no token output, activation unavailable |
| Keychain-only source | Clear unsupported state, no Keychain access |
| Broken or cyclic symlink | Bounded inspection failure with original data intact |
| Linked skill outside source | Reviewed target content backed up and portable after import |
| Source inside destination | Import rejected before mutation |
| Source changes during copy | Retry or pause, no false complete status |
| Database with committed WAL data | Snapshot contains committed rows and passes integrity checks |
| Unknown database schema | Source preserved, unsupported status, no guessed SQL rewrite |
| Chat index with absolute paths | Every recognized rebased path resolves inside the destination |
| Divergent duplicate transcript | Both copies preserved, conflict remains visible |
| Archived chat and attachment | Archive state and references survive import |
| Shared settings conflict | User choice applied once, other accounts see intended settings |
| Atomic editor breaks config link | Divergence detected, local change preserved before repair |
| Active default Codex writer | Switch waits for a safe user-controlled state |
| Token refreshed since last switch | Latest known credential retained or conflict surfaced |
| Existing auth is a symlink | No accidental write into another profile's credential |
| Crash before publication | Existing account and settings remain usable |
| Crash after home publication | Recovery reconciles home and registry without data loss |
| Crash during settings replacement | Journal restores or completes the documented operation |
| Disk full or volume disconnect | No half-published account, recoverable error |
| Restore after later user edit | New edit preserved, no unconditional rollback overwrite |
| CLI verification | Disposable verification home, bounded timeout, no hidden model request |
| Keyboard and accessibility labels | All actions reachable and states named without relying on color; live VoiceOver testing is outside the user-requested gate |
| Final package | Native macOS binary, intended revision, no gateway process |

At least one deliberate failure must prove each transaction recovery test can detect the original failure mode.
Use temporary roots and fake credentials for all automated mutation tests.
The real login Keychain and other apps' credential stores are outside the test environment.

## 17. Delivery and maintenance rules

Keep `/private/tmp/ai-manager-build` as the canonical build directory, or set
`AI_MANAGER_BUILD_PATH` when the host requires another private path. Do not produce
timestamped build copies for each attempt.
Do not produce timestamped build copies for each attempt.
Backups are user recovery data, not build caches. Do not remove them during normal build cleanup.

Before each milestone commit:

1. Run the smallest checks that prove the changed behavior.
2. Inspect the complete staged diff and check for secrets and unrelated files.
3. Update the milestone checkbox only when its completion gate is met.
4. Record the command, result, and material limit in section 19.
5. Commit owned paths with the configured human identity.

Use the next implementation session's current official Codex docs and installed CLI help for changing interfaces.
Do not treat the observed source database schema as a permanent public API.
If an unsupported format blocks full import, preserve it and report the exact category still missing.

## 18. Evidence and references

These references support the data model and integration boundaries, not a claim that the native app is implemented.

- [OpenAI config and state locations](https://developers.openai.com/codex/config-advanced): `CODEX_HOME` groups config and local state.
- [OpenAI authentication](https://developers.openai.com/codex/auth): file-based auth, credential storage choices, and token refresh behavior.
- [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli): local login status and supported resume commands.
- [Super profiles](https://super.engineering/docs/providers-and-models/#profiles): Codex profiles select a home through `CODEX_HOME`.
- [Super session ownership](https://super.engineering/docs/session-history-and-restore/): app state and provider history are separate.
- [SQLite backup API](https://www.sqlite.org/backup.html): use database snapshots instead of blindly copying active database files.

The native UI choice is a product decision from the user's macOS requirement.
Verify selected SwiftUI and AppKit APIs against the deployment target during G1.

## 19. Handoff evidence and next action

### Preparation evidence

- The source and main auth identify different accounts without printing token contents.
- The new auth is a regular file with mode `0600` inside a `0700` home.
- All eight shared links resolve to the intended main-home entries.
- All six copied databases passed `PRAGMA quick_check` after online snapshots.
- All 408 indexed rollout paths resolve after the destination-prefix update.
- The 1,212 copied session files match source sizes and modification times.
- The copied CLI reports `codex-cli 0.154.0` without using the old release symlink.
- The copied CLI loaded the new home with file-only auth and reported `Logged in using ChatGPT` through `login status`.
- Main rules and config backups were compared, and skill inventories matched after copying.
- No online authentication or live conversation resume was attempted.

### Documentation checkpoint

- `node scripts/check-links.mjs`: 26 Markdown files checked, no broken local links.
- `git diff --check`: passed before staging.
- Private `verify-codex2.sh`: passed auth separation, shared links, database integrity, and indexed transcript checks.
- Main config and source auth still match their pre-change backup copies.
- Ponytail inventory: 0 markers, 0 with no trigger. No implementation shortcuts were added.
- Native app tests and builds were not run because this checkpoint changes documentation only.
- This handoff is one local commit. The inherited destructive CI has not been pushed or executed.

Append later milestone evidence here as work lands.

### Implementation evidence (in progress, 2026-09-11)

- Native Swift package now has `packages/core`, `packages/gui`, and `packages/tui`.
  The GUI and CLI compile; obsolete Electron/gateway entry points and destructive
  branch-deletion CI have been retired. macOS 14 is the deployment baseline.
- Thirteen initial core contracts passed, covering private auth-only import,
  bounded discovery and workspace identity, reviewed full import, divergent and
  colliding transcripts, archived attachments, SQLite WAL snapshots and exact-prefix
  rebasing, safe switching, root isolation, corrupt journals, and injected publication
  failures. Further edge-case and native resume verification remains in progress.
- A private APFS copy of the user's Codex home was made outside this repository.
  Runtime sockets were omitted. All six copied SQLite databases passed `quick_check`.
  The copied main index contained 9,497 threads. No original home mutation was used.
- The real copied auth imported into a separate isolated manager root, retained
  identical bytes, and produced a `0700` home with `0600` auth and no unresolved items.
  The installed Codex CLI recognized its file-based credentials in a neutral temporary
  verification home. This proves local presence only, not online authentication.
- Real-format full-import testing exposed an external skills-link keep-choice defect;
  correction and further full-import validation remain required.
- Debug app packaging passed Mach-O, plist, and signature checks. GUI runtime
  acceptance is pending: the shell-launched bundle encounters Launch Services
  registration failures in this restricted session. Native launch is being checked.
- Git checkpoint creation is blocked: creating `.git/index.lock` returns
  `Operation not permitted`. No commit or push was made. Builds identify dirty source;
  the clean-commit installation gate remains unmet. Process inspection is also denied,
  so live default-home switching must fail closed in this session.
- No online model request, real login Keychain access, or production publication was used.
- Subsequent synthetic coverage reached 24 passing contracts and the canonical release
  CLI acceptance script passed. GUI and CLI compile in release mode with the installed
  toolchain's debug-symbol output disabled; normal build defaults are retained.
- Native Computer approval explicitly rejected AI Manager access. Keyboard/VoiceOver
  verification cannot proceed through that tool in this session. No bypass was attempted.
  No valid code-signing identity is exposed; development packaging uses ad-hoc signing.
- The first large-data import was terminated with exit 137 after 6.9 GB. Recovery removed
  its published files and staging, but an old unjournaled partial copy remained. That
  exact private test file was preserved separately; new transactions now journal temporary
  sibling files and an injected interruption test verifies their recovery.
- A release-mode real-copy test later stopped without an XCTest completion result after
  copying 17 GB. This is a failed acceptance run, not a completed import. Periodic memory
  telemetry and further diagnosis are required before large-data acceptance can pass.
- Real source inspection found 1,583 paginated and 7,914 legacy index records. Paginated
  database preservation, valid relocated index paths, and native read verification are
  explicit remaining gates; preserving transcript bytes alone does not satisfy them.
- Synthetic coverage subsequently reached 28 passing contracts, with the protected-copy
  integration test disabled unless its explicit private paths are supplied. Incremental
  journal records now avoid rewriting the full touched-file inventory for every file.
- The measured full-copy rerun still ended without XCTest completion. Its first sample
  reported 9,613,344,768 bytes peak resident memory. Large-data acceptance remains failed;
  parsing and recovery memory are under investigation before another attempt.
- The copied source has 7,894 legacy index rows whose rollout files are already missing;
  none have projected items or turns. Three paginated rows have missing rollouts but valid
  projected items and turns. Import must retain these database-only histories and report
  the pre-existing orphan metadata separately.
- A native Codex app-server baseline listed and read a short paginated history in two
  credential-free neutral homes, then discovered a later synthetic history in both.
  This validates the installed CLI behavior, not the unfinished product import.
- G2 core discovery acceptance passed through temporary-fixture contracts and CLI
  discovery checks. Source inspection is bounded, credentials are not displayed, and
  workspace identities remain distinct. Native GUI runtime acceptance remains in G6.
- The subsequent baseline passed 30 synthetic contracts, including the bounded metadata
  parser and directory settings merge that retains shared-only and source-only files.
  Refreshed-credential, linked-setting repair, and orphan-index changes are a later batch
  and require their own validation before these results can cover the final source.
- Five linked-settings contracts passed: review-bound repair preserves the displaced
  local entry, launch refuses divergence, active writers prevent repair, broken relative
  links remain backed up, and interrupted publication restores the original local edit.
  GUI and CLI builds and CLI acceptance passed; native GUI interaction remains unverified.
- The protected-copy planning-only release test passed in 11.609 seconds over 11,936
  manifest entries, with peak resident memory of 146,997,248 bytes. It performed no import
  or recovery. Full-import memory still needs a completed measured run.
- Three focused switching contracts passed. Selecting the current account preserves its
  refreshed default credential; independently changed credential copies cause a conflict;
  the incoming identity is checked again before publication.
- The combined synthetic suite passed 39 tests, with two explicitly opt-in private-copy
  checks skipped. Separate-database SQLite tests cover WAL snapshots, orphan exclusion,
  retained-path mapping, complete paginated projections, and unchanged source databases.
- The protected full-import preservation run passed in 249.526 seconds: all 1,604 source
  transcripts were accounted for and source auth was unchanged. Its shared library already
  contained the transcripts, so this proves the merge/reimport case. A fresh empty-root run
  and native product-index validation remain separate gates. Peak RSS was 1,716,879,360
  bytes; the last pre-oracle sample was 865,501,184 bytes.
- The fresh empty-destination release run then passed in 181.242 seconds. It imported
  1,600 transcripts, accounted for all 1,604 source files, preserved four divergent copies
  in backup, and left source auth unchanged. Peak resident memory was 894,844,928 bytes
  through import and the completed accounting check.
- Actual product index preflight passed: 1,603 state rows, 1,600 valid rollout paths,
  three valid database-only paginated histories, zero missing legacy references, and
  zero escaping references. The original orphan metadata remains in database backups.
- Final canonical release packaging passed with `scripts/build-native.sh` and the
  `AI_MANAGER_DEBUG_INFO_FORMAT=none` environment override. Both products are native
  arm64 Mach-O binaries. The app's
  signature verifies, entitlements are empty, deployment target is macOS 14, and no test
  environment is embedded. Source revision is `a75c4f4d7638` with dirty-source state true.
  `bash packages/tui/Tests/acceptance.sh /private/tmp/ai-manager-build/artifacts/ai-manager`
  passed against the packaged CLI.
- An explicit-index native history check passed with the installed Codex app-server.
  After neutral index preparation, both credential-free homes listed identical sets of
  1,603 conversation IDs, read one ordinary history and all three database-only histories
  with turns, and discovered a later synthetic addition. This proves RPC readability after
  preparation, not unchanged product-index compatibility or natural discovery. Preflight
  ran before neutral index preparation. The verifier supports bounded `--read-id` checks
  while retaining complete listings.
- Real-copy unresolved items remain visible: four divergent transcripts in protected
  backup; 14 external setting links kept shared without following their targets; a missing
  shared skills target under that choice; and one retained transcript with original-path
  context. Unknown, runtime, installation, and unsupported auxiliary files are reported
  as exclusions. SQLite sidecars are included by snapshots, and lightweight indexes are
  left for native discovery to rebuild. Valid database-only histories are retained.
- Final Ponytail inventory: zero markers and zero missing triggers. Whitespace checks
  pass. Obsolete task build caches were removed; the canonical cache and private recovery
  data remain separate. Git checkpoint and installed GUI gates are still unmet.
- Two final registry-commit interruption contracts passed. Recovery completes the already
  registered import or switch instead of rolling back a committed identity. These checks
  changed tests only; the packaged production binaries remain current.
- Final combined suite: 43 tests total, 41 executed, two opt-in private-copy tests skipped,
  zero failures. Both opt-in checks passed separately as recorded above. The temporary
  final test cache was removed after verification; the canonical release artifacts remain.
- Continuation audit added the packaged CLI acceptance command to native CI and release
  validation. Release creation now follows passing core tests, packaging, and CLI checks.
  Changes to the native check and history verifier scripts trigger PR validation.
  Both workflow files pass YAML parsing; remote CI and publication were not executed.
- Three additional filesystem-failure contracts passed in the canonical cache. Native
  `chmod(000)` and `open` verified denied access (`EACCES`); removal of a reviewed temporary
  source simulated volume loss; injected `ENOSPC` after a journaled settings publication
  verified disk-full recovery. Prior account/default bytes remain intact, no partial
  account is published, and recovery removes partial shared changes. Disconnection and
  disk-full checks are simulations, not physical volume removal or filesystem exhaustion.
  No production code changed; the packaged app and CLI remain current.

Status before access recovery: fresh import and large-copy preservation passed.
The neutral native history checks passed, subject to the verification limitations below.
GUI launch and local installation acceptance were pending; packaging used ad-hoc signing.

The restricted-session audit reported no valid signing identity and denied Git,
installation, and Computer access. Those restrictions blocked the goal at that time;
the later access recovery below supersedes that status. Core tests alone do not complete
the GUI, accessibility, signed installation, or checkpoint gates.

### Reported launch crash follow-up

The user reported a launch crash and requested Computer control. A renewed native
Computer request for the exact packaged app was rejected with `Computer Use was not
approved to use AI Manager`. App discovery works; it lists no running AI Manager or
crash-report app. No alternative GUI driver or indirect launch was used to bypass this.

The four available AIManager crash reports are from 10:04–10:06 and identify binary UUID
`6FE2E615-34C0-3692-9571-38C007AC80D9`. They abort in Launch Services `_RegisterApplication`
during AppKit initialization, with Codex as parent and Super as responsible process,
before account-manager initialization. The final 11:32 artifact has a different UUID,
`64BED7ED-D2D9-32B5-8C6B-73101B6FE79B`, and passes executable, plist, and signature checks.
No newer matching crash report was found. These reports establish the old launch-context
failure, not a reproduced crash of the final artifact. A source fix is not yet justified;
native approval is required to reproduce the reported failure on the current app.

### Access recovery and UI refinement

The user requested another Computer attempt after session permissions changed. Native
Computer successfully opened and inspected the current release bundle without a crash.
The earlier GUI rejection and filesystem restrictions no longer block this session.
Git and `/Applications` writes are available, and an existing personal Apple Development
identity is available for local signing. No new permission or credential was created.
The initial window exposed a narrow sidebar and hidden import action; its layout was
corrected and compiled. The user's subsequent Carbon-inspired custom macOS design
request now governs the remaining UI work and acceptance.

### Final verification audit

- The combined synthetic suite passed 46 tests total: 44 executed, two opt-in private-copy
  checks skipped, zero failures. The private-copy checks retain their separately recorded
  passing evidence.
- Retirement is committed and pushed as `7acd0a6`; core storage and contracts are committed
  as `451fca8`, and CLI/TUI workflows as `0a3e27f`. No release tag was created.
- The earlier native history verifier rebuilt both neutral indexes and inserted the later
  history into both. That evidence proves local RPC readability after explicit index
  preparation; it does not prove unchanged product-index compatibility or natural later
  discovery. Its path preflight also remapped prefixes. These G5 gates remain open until
  strict account-home path validation, unchanged snapshot reads, and native discovery
  without SQL insertion pass. The preservation and transaction contract results remain valid.
- A separate non-shipped GUI acceptance app will inject an inactive writer check only for
  newly generated synthetic temporary homes. Production retains its conservative writer
  check. Successful harness workflows and the production refusal path are distinct evidence.
- The corrected strict preflight passes for all 1,603 product rows, but unchanged native
  listing returns 610 and omits 993 paginated rows. A blank-index scanner did not discover
  a later synthetic transcript. These are open G5 findings requiring classification and
  diagnosis, not passing acceptance. No online model turn or production data mutation ran.
  Read-only history diagnosis resumed after the isolated GUI workflows passed.

### Custom UI acceptance

- The native window now uses custom flat account rows, actions, import choices, and
  status surfaces with macOS colors. There are no decorative outlines. Keyboard focus
  uses a tonal fill and a three-point leading bar; the native rectangular ring is suppressed.
- Native Computer verified the dark empty window at 920 pixels and the light populated
  window at exactly 720 pixels. The common account email stays on one line, actions use
  two columns at the narrow size, and account selection remains synchronized with focus.
- A separate non-shipped acceptance app uses fresh synthetic private homes and an injected
  inactive writer check. Auth-only import, full import with reviewed settings conflicts
  and a divergent transcript backup, default switching, and local fake verification pass.
  Production retains its conservative active/unknown-writer refusal.
- A directory-link alias regression found through the GUI is fixed in `3f3e9cb`.
  Canonical path components accept equivalent `/tmp` and `/private/tmp` directory links
  while rejecting wrong and dangling links. All six focused settings tests pass, and the
  repeated full-import GUI flow no longer offers a false repair action.
- Final targeted header and keyboard-focus QA passes for acceptance binary UUID
  `291CC533-30C6-333E-BE0C-768D5454BB55`; its strict signature check passes. Screenshots
  are retained under `/private/tmp/ai-manager-build/gui-acceptance/artifacts/`.
- Accessibility-tree inspection and keyboard navigation were exercised; actual VoiceOver
  speech/navigation remains untested. Terminal handoff was not driven because it may
  foreground Terminal, which the focus-preservation rule disallows. The CLI exact launch
  contract passes separately.
- A subsequent native file-picker check reproduced a directory-hint URL mismatch. Fix
  `a0f13c7` compares standardized source paths. Choosing the second source folder selected
  its account; choosing the first source's `auth.json` selected the first account. Both
  corrected selections were verified through fresh native accessibility states.
- No original Codex home, login Keychain, imported hook, or online model request was
  touched. Ponytail inventory: zero markers and zero missing triggers.

### Native history diagnosis

- The earlier `610/1,603` listing result used the wrong expected subset. Listing all
  source kinds returns 610; its 993 omitted paginated rows comprise 981 subagent,
  nine automation, and three user/CLI records. The native interactive-only listing
  returns 341 conversations. These distinct filters must not share one expected count.
- Three database-only paginated histories fail native reads from unchanged product
  snapshots. A metadata-only anchor probe made them readable but still could not resume
  them. The importer must preserve their original databases in backup and report them as
  unresolved; it must not fabricate transcript turns. Ordinary imported transcript
  native read and resume pass without a turn, and a later faithful fixture containing `session_meta` plus an
  `event_msg.user_message` was independently discovered and indexed from two blank homes
  without SQL insertion.

- Correction `ac18d29` excludes unsupported database-only rows from the active index,
  preserves the source state and projection snapshots in backup, and reports their count
  and backup path as unresolved. The regression verifies intact source/backup rows and
  usable active transcript-backed rows. The combined suite passes: 48 total tests,
  46 executed and two protected-copy opt-ins skipped.
- The corrected native verifier passes synthetic listing, reading, and resuming in both
  homes plus later shared discovery, without SQL insertion or an online model request.
  It rejects the previous protected-copy import for exactly three dangling active rows.
  A fresh protected-copy import remains pending to verify the corrected 1,600-row output.
- Current Ponytail inventory: one marker, zero missing triggers. The conservative writer
  check blocks mutation when any Codex process is present because home ownership is
  unknown. Replace it with home-specific detection when Codex provides a reliable lock
  or probe; do not weaken the safety check to bypass this limit.

### Final protected-copy acceptance

- A freshly rebuilt release test at `c08af240a7d7` passes in 175.226 seconds. All 1,604
  source transcripts are accounted for; 1,600 are imported and divergent variants remain
  in backup. The source auth digest is unchanged. Peak memory is 605,421,568 bytes.
  An earlier run used a stale test binary and was rejected by strict preflight; it is
  not counted as acceptance.
- Strict preflight passes all 1,600 active rows with zero missing, escaping, or unmapped
  paths. Protected backups retain the original 9,497 state rows, 377,070 projection items,
  and 3,759 turns, including the three unsupported database-only histories.
- Unchanged database copies in two neutral homes list the same 341 interactive threads.
  The remaining 1,259 active records are background or noninteractive histories. One
  existing paginated interactive conversation passes native read, resume, and turn loading
  in both homes. A later shared transcript is independently discovered and indexed by
  both homes, without SQL insertion or an online model request. Large native responses
  require a 64 MiB response bound and a 60-second startup/request bound for this dataset.
- Current packaged CLI acceptance passes. All large transfers are finished. The signed
  release at `c08af240a7d7` has dirty-source false, an Apple Development signature, empty
  entitlements, and native arm64 app and CLI executables. Strict signature validation passes.

### Installed application acceptance

- `/Applications/AI Manager.app` was installed from clean revision `613600e47739`.
  Its embedded revision and dirty-source false value match the build; strict signature
  and empty-entitlement checks pass. The running process identifies that exact installed
  executable. Native Computer confirms a successful launch and custom dark empty state.
- The installed app created only its private `manager.lock`; no production import or
  switch ran and no original Codex home was changed. Positive import/switch GUI evidence
  comes from the isolated acceptance harness. Production mutations retain the conservative
  live-Codex writer check described in the Ponytail inventory.
- `/Users/surajmandal/.local/bin/ai-manager` resolves in the shell and matches the verified
  packaged CLI. Help and status against a fresh isolated empty root pass.
- Documentation-only checkpoints require regenerating the installed bundle's revision
  metadata through the normal signed build before handoff. Functional checks above remain
  evidence for the unchanged implementation.

The user subsequently rejected the shared header/footer composition and the live VoiceOver
gate. The new compact translucent two-pane design in section 14 supersedes the old visual
acceptance. Preserve the passing core/history evidence; verify the new UI's hover, keyboard,
three-point corners, custom titlebar, light/dark appearance, and installed artifact.

### Compact translucent UI acceptance

- The revised native window uses full-height material panes, integrated window controls,
  and a draggable custom composition. It has no shared header, status bar, decorative
  outlines, numbered headings, duplicate empty-state copy, or repeated imported badge.
- Identity and primary actions stay at the top. Long paths and settings metadata are
  collapsed under Account details; warnings and recovery actions remain available.
  Custom rectangular surfaces share a three-point radius. Hover handlers provide 150 ms
  tonal feedback, with reduced-motion support and a reduced-transparency fallback.
- Native Computer verifies light appearance at 720 by 532 outer pixels and dark appearance
  at 920 by 620. The narrow height reflects the production 500-point content minimum.
  Both panes reach the top and bottom; account details expand/collapse; arrow navigation
  updates both selection and accessibility identity; keyboard focus uses a tone and bar.
  Source selection, import review, and result screens pass the visual/interaction matrix.
- Hover is source-audited, not exercised by native automation: the documented driver has
  no pointer-move operation, and dragging the window background is not an acceptable
  substitute. No undocumented driver, focus change, or VoiceOver launch was used.
- Screenshots are retained in `/private/tmp/ai-manager-build/gui-acceptance/artifacts/`
  with the `redesign-` prefix. The final affected debug build passes. Harness files and
  core behavior are unchanged. Ponytail inventory remains one marker with a defined
  upgrade trigger and zero missing triggers.
- The signed redesign was installed from clean revision `086ea3ef4da5`. The installed
  bundle reports that revision and dirty-source false; strict signature and empty
  entitlement checks pass. Native Computer launched the exact `/Applications/AI Manager.app`
  executable and confirmed the full-height translucent composition without header/footer.
  The installed CLI hash still matches the unchanged verified package. The app remains
  open for the user. The normal signed build refreshes revision metadata after this
  documentation-only checkpoint; no functional test rerun is needed for that metadata.

Remote native CI was dispatched as run `34588863904`, but repository Actions are
disabled (`enabled: false`) and no job started. Repository permissions were not changed.
Local native tests and packaging remain the executed verification evidence.

### Custom window controls

- Custom close and minimize buttons replace the native traffic lights. Both controls
  and the title share a centered row. The account count and separate sidebar material
  edge are removed. The window uses one translucent background with a sidebar tint.
- SwiftUI owns the resize bounds in both production and acceptance scenes. A live
  AppKit read confirms the outer maximum is 1840 by 1240, all native window buttons
  are hidden, zoom is disabled, and fullscreen is disabled. The hidden titlebar adds
  32 points to the content height on the verified host.
- The rebuilt acceptance app passes its retained window contract after native launch.
  It checks the resize cap, resizable/fullscreen flags, and hidden native controls.
- Native Computer lists apps but reports `cgWindowNotFound` for Chrome and both
  AI Manager apps after recovery attempts. AppKit confirms the acceptance window exists.
  Fresh screenshots, close/minimize clicks, and drag interactions remain unverified;
  no app was activated or moved to bypass the focus rule.
- The custom-control build was signed and installed from clean revision `221a60b0b595`.
  The installed bundle reports that revision and dirty-source false; strict signature
  and empty-entitlement checks pass. Native Computer's exact-path launch started the
  installed executable, which stayed running despite the bridge's window-targeting error.
  The installed CLI hash is unchanged. The final documentation checkpoint requires only
  the normal signed rebuild/install to refresh source-revision metadata.
- Ponytail inventory remains one marker with zero missing triggers:
  `packages/core/Sources/AIManagerCore/AccountManager.swift:398` blocks mutations when
  any Codex process is present. Replace that conservative check when Codex exposes
  a reliable home-specific lock or probe. This UI change adds no marker.

### Square window and sample preview

- Close and minimize now touch within one control group, with a 20-point gap before
  the title. The outer window is square; ordinary custom controls retain three-point
  corners. Native Computer confirms the resulting light layout at 720 by 500.
- A shared AppKit window controller hosts the SwiftUI interface in production and the
  preview. Its borderless window explicitly supports key and main status. The hosted
  layout owns the 720 by 500 minimum and 1840 by 1240 maximum, replacing the earlier
  hidden-titlebar height adjustment. The default remains 920 by 620.
- The preview crash was a test assertion after a borderless window lost key-window
  eligibility. Window checks now write nonfatal pass/failure receipts, and fixture
  startup errors show a failure view. A failed check is still a test failure.
  The corrected window passes the key and size contract; native close and minimize
  notification receipts confirm both custom actions.
- `AI_MANAGER_GUI_PREVIEW=1 scripts/build-gui-acceptance.sh` produces a distinct
  AI Manager Preview app with two sample accounts. Each launch uses fresh private
  synthetic homes. The production account registry and original Codex homes stay separate.
  The preview uses the same account, import, review, and result views as production.
- Native Computer passes light/narrow and dark/default layouts, account selection,
  source selection, full import review with Keep shared, and the import result. Window
  receipts pass after seeding, account changes, and import-state changes. Screenshots
  remain under `/private/tmp/ai-manager-build/gui-acceptance/artifacts/` with the
  `preview-` prefix. No new crash occurred in these final builds.
- Both `/Applications/AI Manager.app` and `/Applications/AI Manager Preview.app` were
  installed from clean revision `10b1c9c50e78`. Embedded revisions, dirty-source false,
  strict development signatures, empty entitlements, and executable hashes match their
  build artifacts. Native Computer launched both exact installed paths. The production
  empty window closed through its custom control; the seeded preview remains open and
  its installed window contract passes. The CLI hash is unchanged. The final documentation
  checkpoint requires only a normal rebuild/install to refresh revision metadata.
- The preview now has native Quit, Import, Close, and Minimize menu commands. Native
  Computer confirms Command-I opens import, Escape dismisses it, and Command-Q exits
  the preview process. Its nonfatal contract also checks that the Quit command exists.
- Ponytail inventory is unchanged: one conservative writer-check marker at
  `packages/core/Sources/AIManagerCore/AccountManager.swift:398`, with the reliable
  home-specific lock/probe upgrade trigger and zero missing triggers.

### Recap Pro design-review revision (2026-09-12)

The GUI now uses the current Producer shell and component styling: a 48px
navigation rail, 56px titlebar, bundled Geist and Geist Mono, 2px component
corners, exact light/dark palette, compact panels, and offset-arc title cells.
Accounts, shared settings, history, recovery, and import source/review/result
pages use the same design. A Demo menu exposes sample, empty, and issue states.
The small animated logo field is rendered natively; it approximates the
reference WebGPU effect rather than sharing that renderer.

Both GUI entry points now construct only the in-memory demo model. Source
discovery, imports, conflict decisions, verification, switching, launch, copy,
Finder, repair, and recovery actions have no real account side effects. Separate
imports retain distinct identities; reimport updates the matching demo account.
Pending mock actions are cancelled by a demo reset. The preview writes only
nonfatal window acceptance receipts in the canonical build artifacts directory.
The CLI and core retain their real behavior and conservative writer protection.

Validation: the native suite ran 48 tests with two existing gated skips and no
failures. The new `scripts/check-gui-demo.sh` passes its multi-source import,
conflict, switching, verification, recovery, stale-action, and no-file-write
checks, and runs in the normal native check command. The preview's live window
contract passes bounds, native style, key/main capability, menu, and Geist font
checks. Native Computer exercised both import modes through results (full: three
files/248 chats; auth-only: one file/zero chats), account selection, verification,
default switching, empty/issues states, settings, history, and recovery. Screenshot
inspection confirms mock Open/Copy notices, and both reference light/dark palettes
after fixing AppKit appearance propagation. The import panel is now a custom 2px
overlay; full import and Escape dismissal also pass at 720x500. Native close and
minimize event receipts pass. Pointer-hover automation remains unavailable; its
shared hover region and delayed minimize dismissal are source-reviewed. CLI
acceptance passes. Both `/Applications/AI Manager.app` and
`/Applications/AI Manager Preview.app` were installed from clean `dc93a2be6c40`,
with strict development signatures, empty entitlements, and matching build/
installed executable hashes. Native Computer verified the exact installed normal
app's custom import panel, modal keyboard focus, and Escape dismissal; the exact
installed preview's window/font receipt also passes. This documentation checkpoint
requires only the normal rebuild/install to refresh embedded revision metadata.

Ponytail inventory: one unchanged marker in
`packages/core/Sources/AIManagerCore/AccountManager.swift:398`; all Codex
processes block real mutations until Codex exposes a reliable home-scoped lock
or probe. Zero missing triggers, no new marker from this redesign.

### Fixed-window interaction refinement (2026-09-12)

The design-review window is fixed at 1120x740. The custom title drag region is
separate from buttons, and the close/minimize group has a full hit area without
covering the title. Refresh and theme controls have explicit rectangular hit
areas. Theme selection updates the owning window appearance. Focus effects are
off by default, with a Keyboard focus indicators option in the Demo menu.

SF Symbols replace hand-drawn icons. The page title and subtitle share a text
baseline, title cells have wider padding and quieter decoration, refresh has no
background, and disabled primary buttons retain readable text. The import panel
uses labeled steps, a compact fixed layout, scrolling content, and a Done action.
Closing it invalidates pending mock import work. Refresh preserves account and
default selections and reports its last refresh time.

All eight scrolling regions, including the account list, use an owned native
scroll view with a three-point overlay thumb. It responds to section hover,
trackpad scrolling, and mouse wheels, then hides after leaving the section.
It keeps the SwiftUI environment across the native host boundary. This replaced
an unsuccessful attempt to customize SwiftUI's internal scroll view, which
overrode the requested overlay style on the verified host.

The native suite passes 48 tests with two existing gated skips and no failures;
the mock model check passes. The live preview contract passes fixed frame and
content bounds, key/main eligibility, fonts, SF Symbols, default focus policy,
actual title hit testing, scroll configuration, nonempty document layout, and
absence of a scrollbar gutter. Failed checks remain nonfatal and include view
hierarchy diagnostics. Contract helpers are compiled only into the preview.
`scripts/check-gui-scroll.sh` also passes: an 80-row hidden-window fixture checks
overflow, the three-point native thumb, no gutter, reachable bottom, and scroll
position retained after layout. It never presents a window or takes focus, and
reports failures with an exit code rather than a crash. It runs in the standard
native check command.

New pointer/visual acceptance remains pending: macOS became locked during this
verification session (`IOConsoleLocked=Yes`), and native Computer returns
`cgWindowNotFound` for both the preview and Chrome. No alternate GUI driver or
unlock attempt was used. Repeated pointer theme toggles, dragging, control hover,
scrollbar fade, and the revised wizard must be exercised after unlocking; the
runtime contracts do not substitute for those checks.

Ponytail inventory is unchanged: one marker at
`packages/core/Sources/AIManagerCore/AccountManager.swift:398`, zero missing
triggers. Real mutations remain blocked by any live Codex process until Codex
provides a reliable home-specific writer lock or probe. GUI actions remain mocked.

### App identity refinement (2026-09-12)

The Dock tile follows Recap Pro Producer's charcoal and warm-white treatment.
The mark combines Lucide's existing robot and slider geometry, with a filled
head and eye cutouts. Its license and reproducible PNG/ICNS generator are included.
Both GUI bundles use the same Dock icon, monochrome menu-bar template at 1x/2x,
and rail mark. The menu offers Show AI Manager and Quit; account actions remain
in-memory mocks.

The native build and hidden-window scrolling check pass. The launched preview's
nonfatal contract passes asset loading, template flags, 22-point tray size,
22/44-pixel representations, and the retained menu-bar item, alongside existing
window checks. Dock and native-size tray exports were visually inspected.
Live Dock/menu interaction remains pending while macOS is locked; native Computer
returns `cgWindowNotFound`. The existing pointer checks above remain pending too.

Debt audit: one unchanged marker at
`packages/core/Sources/AIManagerCore/AccountManager.swift:398`; any Codex process
blocks real mutations until reliable home-scoped writer detection is available.
One marker, zero missing triggers; no icon-related shortcuts were added.

### Native polish and account-switch research acceptance (2026-09-12)

- The light palette now resolves across every nested native scroll host, and the dark
  palette remains consistent. Installed light and dark snapshots show aligned title/body
  boundaries, a continuous Recovery rail, one background-free refresh action, a visible
  Close control, and Minimize revealed by the shared control hover region. Custom surfaces
  use three-point corners. Single-title panel art spans the full available header width.
  Focus outlines remain off until the explicit keyboard-focus preference is enabled.
- The fixed window uses AppKit frame autosave, retaining its last display and origin across
  launches while reapplying the required 1120 by 740 content size. Acceptance checks both
  the fixed bounds and the configured autosave identity.
- Buttons, rows, rail navigation, page changes, import steps, modal presentation, and
  scrollbar visibility use short interruptible transitions that honor Reduce Motion.
  The always-running decorative timeline was removed. The installed release measured
  0.00% median CPU and 0.11% average CPU across 30 one-second idle samples, with a 2.20%
  launch peak.
- Settings contains a persistent Minimize to Menu Bar switch. The titlebar control and
  Command-M use the same behavior helper; acceptance covers both preference branches with
  a disposable UserDefaults suite. The menu-bar item remains available to reopen the app.
- Dock and Spotlight artwork use the exact Apache-2.0 Material Symbols Rounded
  `switch_account` path on the Recap Pro charcoal tile, with a restrained top-left edge
  highlight. The tray and rail reuse the same monochrome mark. Generated 16, 22, 44, 256,
  and 1024-pixel assets were inspected and rebuilt deterministically.
- [`docs/account-switching-research.md`](docs/account-switching-research.md) records the
  official Codex storage/process contract, ten open-source switchers, and four broader
  products. Eight of ten inspected tools use auth-only replacement. AI Manager therefore
  swaps the complete file-backed auth record while keeping config, instructions, skills,
  hooks, sessions, history, indexes, and databases shared. Existing Codex processes still
  require reload/restart, and Keychain or higher-priority environment auth must fail closed.
- Account identity now requires auth mode, `chatgpt_user_id`, and
  `chatgpt_account_id`. Interrupted switch recovery preserves refreshed outgoing auth and
  leaves non-auth files unchanged. The 50-test native suite passes with no failures; its
  two opt-in copy tests also pass separately on isolated synthetic homes, accounting for
  every transcript and preserving the source auth digest. Packaged and installed CLI
  acceptance passes on temporary synthetic homes.
- `/Applications/AI Manager.app`, `/Applications/AI Manager Preview.app`, and
  `/Users/surajmandal/.local/bin/ai-manager` match their verified artifacts. The signed
  implementation build at `be11e21fdae5` records dirty-source false, empty entitlements,
  and passes strict signature validation. This documentation-only checkpoint requires a
  final normal rebuild/install so the embedded revision matches its resulting commit.
- Orca orchestration completed 25 Sol-high dispatches and released every worker. Native
  Computer still reports `Sky Computer Use native pipe startup failed` after the documented
  service recovery, so pointer movement could not be driven. AppKit title hit testing,
  installed-window receipts, internal snapshots, and source-level hover checks provide the
  available evidence without using an alternate GUI driver.
- Ponytail debt: one unchanged marker at
  `packages/core/Sources/AIManagerCore/AccountManager.swift:398`, zero missing triggers.
  It conservatively blocks mutations when any Codex process is present; replace it when
  Codex exposes a reliable home-scoped lock or probe.

### Next action (production functionality, deferred after design review)

The user approved production wiring on 2026-09-12. The normal app must discover, import,
verify, switch, launch, repair, and recover through `AccountManager`; the Preview app must
remain synthetic and side-effect free. Validate the normal GUI model against isolated
synthetic homes before installing it. Keep the user's prepared homes unchanged during
automated validation.

### IIA Directeur production refinement (2026-09-12)

The macOS app's display name is **IIA Directeur**. Preserve the existing bundle identifier,
application-support location, frame-autosave name, and `ai-manager` CLI command so the
rename does not strand preferences or managed data.

The 48-point rail keeps Close centered in its own square. Minimize is a square floating
control that appears beside it on hover or keyboard focus and never changes Close's
position. Settings rows span the panel: labels align at the leading content edge and
switches align at the trailing edge. Neither row may collapse to its intrinsic width.

Recovery must show interrupted core operations and distinct, legible examples for a regular
conversation snapshot, an incremental snapshot, a custom-location backup, and a disconnected
external-drive backup. A disconnected drive offers explicit actions to wait for reconnection
or choose another destination; demo actions stay in memory. These examples explain recovery
policy and do not imply a background backup engine that is outside v1.

Public release readiness requires the production GUI synthetic-account flow, full native
contracts, clean packaging, and distribution signing/notarization evidence. An Apple
Development-signed local build alone is not a public distribution release.

### IIA Directeur production acceptance (2026-09-12)

- The normal app constructs `AccountViewModel` with `ManagerPaths.environment()` and an
  `AccountManager`. Discovery, both import modes, conflict review, default switching,
  local verification, account launch preparation, linked-setting repair, Finder/clipboard
  actions, refresh, and interrupted-operation recovery use the shared core again. Preview
  keeps the explicit in-memory initializer. Production rejects demo resets and demo errors.
- A new synthetic GUI-model acceptance imports a resolved account, preserves its source
  credential and shared configuration, switches the default auth, verifies through a
  synthetic Codex executable, refreshes, recovers, and reads the managed shared-history
  count. The normal native suite passes 50 core tests with the two protected-copy gates
  skipped, plus the production model, mock model, and native scroll checks. CLI acceptance
  also passes. Automated runs touched only temporary synthetic homes.
- Settings labels now fill and align to the leading edge while their switches align to the
  trailing edge. Close stays centered in the 48-point rail. The former 24-point Minimize
  control was superseded by the modal-and-provider refinement below. Preview renders show
  no startup outline. Dark Settings, light
  Settings, and Recovery render receipts pass the native fixed-window, title-drag, focus,
  scrollbar, and asset contracts.
- Preview Recovery shows separate regular-conversation, incremental, custom-location, and
  disconnected-external-drive examples, including Wait for drive and Back up elsewhere.
  Production shows only real recovery journals and policy because v1 has no background
  backup scheduler. Production History now reads actual transcript totals and index state;
  Settings no longer labels absent entries as linked.
- The app display name, menu commands, status-item text, bundle filenames, build scripts,
  CI paths, and documentation are renamed to **IIA Directeur**. The bundle identifier,
  application-support root, frame-autosave key, executable target, and `ai-manager` CLI name
  remain stable so existing data and preferences continue to resolve.
- The clean `d35bab54b31e` local candidate and installed app/CLI passed strict signature,
  empty-entitlements, embedded-revision, clean-source, and SHA-256 equality checks. The old
  named apps were moved to `/private/tmp/iia-directeur-install-backup-20260912-1137` before
  `/Applications/IIA Directeur.app`, `/Applications/IIA Directeur Preview.app`, and the CLI
  were installed. The exact installed production path launches without a new crash.
- Identity builds now sign both GUI and CLI with hardened runtime and secure timestamps.
  The tag workflow imports a Developer ID identity, notarizes the combined app/CLI archive,
  staples the app, checks Gatekeeper, and publishes only after every gate succeeds. This Mac
  has Apple Development and Apple Distribution identities but no Developer ID Application
  identity; `scripts/check-release-readiness.sh --public` therefore fails closed as intended.
  Public distribution is not ready until that identity and the repository notary secrets
  are supplied and the workflow returns `PUBLIC_RELEASE_READY`.
- Native Computer remains unavailable with `Sky Computer Use native pipe startup failed`
  after current-tool discovery, module import, service-signature inspection, and retry. The
  accepted per-window renders came from the preview's own nonfatal AppKit receipt path; no
  alternate GUI driver was used.
- Ponytail debt remains one existing marker at
  `packages/core/Sources/AIManagerCore/AccountManager.swift:411`: all Codex processes block
  mutations until Codex exposes a reliable home-scoped writer lock or probe. Zero missing
  triggers and no new shortcuts were introduced.

### Modal and provider acceptance (2026-09-12)

- Window Close, window Minimize, and modal Close now use the same 48-point square geometry
  and 15-point SF Symbol scale. Minimize rests behind Close and animates one full control
  width beside it on pointer hover; Close never moves. A delayed hide keeps the control open
  while the pointer crosses between them, and reduced motion removes the animation.
- The import shell uses a 24-point outer edge. Panel headings, source rows, import-scope
  choices, conflicts, manifest rows, and result rows use a 16-point internal edge. Light and
  Dark Aqua import-source renders pass the fixed-window, drag-region, scrollbar, asset, and
  geometry contract with three configured overlay scroll regions.
- The import flow names Codex only where it identifies the source or operation. Page subtitles
  and helper text contain no provider-roadmap language.
- `ProviderID` is an open stored identifier. New discoveries and accounts record `codex`;
  old registries without the field decode as Codex. The internal concrete
  `CodexProviderAdapter` owns Codex discovery, credential parsing, identity matching, and
  unsupported-provider rejection. `AccountManager` remains the public operation interface;
  no speculative provider protocol, factory, or selector was added.
- The native suite passes 52 tests with two authorized-private-copy tests skipped, plus the
  production model, mock model, scrollbar, dark/light modal, local release, and CLI gates.
  The exact clean signed `/Applications/IIA Directeur.app`, Preview app, and installed CLI
  match their packaged hashes and launch without a new crash. Automated account operations
  used temporary homes and synthetic credentials only.

### Typography and interaction refinement (2026-09-12)

The primary interface must describe the task available now. Remove roadmap language such as
"more providers planned" from page subtitles and import guidance. The import flow may state
that it imports a Codex account where that identifies the required input or operation.

Use the same real Geist variable font faces as Recap Pro, with deliberate weights for titles,
labels, body copy, and metadata. Do not synthesize every weight from a regular-only face.
Interactive controls must respond immediately to pointer entry, press, selection, busy, and
disabled states through short, interruptible transitions that honor Reduce Motion. Hover
feedback must clarify the hit target without dimming the entire interface.

Window Close and Minimize remain 48-point edge-to-edge squares. Minimize has sharp corners,
slides from behind Close without bounce, and retracts quickly after the pointer leaves the
combined control region. Static panels and decorative surfaces do not animate.

### Typography and interaction acceptance (2026-09-12)

- The app uses the named Regular, Medium, and SemiBold instances in its bundled Geist and
  Geist Mono variable fonts. Page titles follow Recap Pro's 22-point, tight-tracked treatment;
  subtitles are 13 points, and wizard source metadata no longer falls below 10 points.
- Accounts now says "Import, verify, and switch accounts." The wizard gives the direct
  instruction "Choose a Codex profile to import." No shipped GUI, core, or TUI source contains
  provider-roadmap language or conversation-attachment labels.
- Minimize is a sharp 48-point amber-tinted square. It moves one control width from behind
  Close in 80 milliseconds without opacity or bounce and has a 70-millisecond seam grace.
  Close remains fixed and visible. Both controls retain their full square hit areas.
- Rail cells, account rows, the account importer, source rows, scope choices, modal Close,
  refresh, normal/primary/danger buttons, and error dismissal have explicit pointer states.
  Selection, busy, and disabled changes use 100-millisecond transitions, and Reduce Motion
  removes movement. Disabled children inherit the wizard's busy state.
- Light Accounts, light History, dark Settings, dark Recovery, and the light import
  wizard were rendered and inspected at the fixed 1120 by 740 window size. The modal contract
  passes with three configured overlay scroll views and a working title drag target.
- The native suite passes 52 tests with two private-copy gates skipped and no failures. The
  mock GUI model, production GUI model, thin-scrollbar fixture, Swift package build, and diff
  checks pass using the canonical build cache and synthetic account homes.

### Single-instance launch contract (2026-09-12)

Only one process for each IIA Directeur application bundle may run in a user session. Acquire
an atomic process-held lock before constructing the GUI model or reading account state. A
second direct executable launch must notify and activate the existing process, then exit
successfully. The lock must release automatically when the owner exits or crashes.

Declare the native Launch Services multiple-instance prohibition in every built app bundle.
Production and Preview have distinct bundle identifiers, so one of each may run together;
neither bundle may run two copies. Verify the lock boundary and the exact packaged executable
with temporary synthetic homes before installation.

### Single-instance acceptance (2026-09-12)

- Production and Preview acquire a per-user kernel lock keyed by bundle identifier before
  their application delegate and account model are created. The retained descriptor releases
  the lock on normal exit and process crashes without stale-lock recovery.
- A duplicate sends a bundle-specific distributed activation notification, activates the
  existing macOS application, and exits with success. The resident delegate restores and
  presents its existing window when it receives that request.
- The standalone process check proves a concurrent child cannot acquire the owner's lock and
  a successor can acquire it after owner release. The packaged Preview test proves a second
  executable exits while the original PID remains alive.
- Every generated app inherits `LSMultipleInstancesProhibited`; the preview window contract
  and local release-readiness gate verify the packaged value. The full native suite passes 52
  tests with the two private-copy gates skipped, plus the model, scrollbar, and instance checks.

### Release-candidate closeout evidence (2026-09-12)

- The current macOS suite passes 79 tests with zero failures and two authorized-copy tests
  skipped in the normal run. The production and mock GUI-model checks, System/Light/Dark
  window contracts, thin-scrollbar check, and fresh-path single-instance check also pass.
  System appearance now clears an earlier fixed window appearance so later macOS changes
  propagate. Production renders a loading state until account discovery finishes.
- Close is the only visible resting window control. Minimize stays mounted behind Close and
  changes only offset and opacity while the pointer is within the control region. Close keeps
  one stable rail fill and changes only a translucent red tint, which prevents the prior bright
  flash. Neither control participates in title layout. The fold-out lasts 80 milliseconds,
  reduced motion removes it, and a short seam grace joins the edge-to-edge controls.
- The same tracked source snapshot passed `scripts/check-linux.sh` as an unprivileged user
  in read-only ARM64 and AMD64 Linux containers. Each architecture passed all 79 tests,
  release ELF and SQLite linkage, CLI discovery/import/verification/launch/recovery,
  isolated status, 0700 application-support permissions, and a 0600 process lock. No test
  container or temporary home remains. The two tagged validation images are retained as
  reproducibility caches.
- Recovery now compares canonical path components instead of Foundation URL directory-hint
  identity. This fixes the Linux/macOS difference without weakening containment checks.
  The CLI recovery fixture contains a valid account identity, canonical account directory,
  and matching protected-backup fingerprint; direct and interactive recovery pass on both
  Linux architectures.
- The authorized 26 GB protected Codex-home copy passed both opt-in tests against the
  committed core. All 1,604 source transcripts were accounted for: 1,257 imported and the
  rest explicitly retained or protected with reported reasons. Source auth remained
  byte-identical. Planning covered 11,936 entries and one conflict. Both tests finished in
  339.975 seconds with 558,645,248 bytes peak RSS. The 23 GB disposable result was removed;
  small telemetry remains under `/private/tmp/ai-manager-validation/evidence-a459`.
- Release readiness now rejects dirty, stale-revision, invalid-plist, wrong-identity,
  missing-arm64, or invalid-signature artifacts with explicit errors. Public mode also
  requires Developer ID Application signatures, hardened runtime, timestamps, a stapled
  notarization ticket, and Gatekeeper acceptance. CI-created certificate and notary-key
  files use a private umask. A `MAJOR.MINOR.PATCH` version is required at build time.
- `/private/tmp/iia-directeur-vm-fixture.tar.gz` is a private VM fixture derived from the
  protected root Codex config. It preserves the non-secret model, reasoning, personality,
  service-tier, feature, and memory settings; it omits connections, authorization headers,
  hook trust, project paths, real credentials, real transcripts, databases, caches, and
  sockets. Its synthetic two-account validation passes in the read-only ARM64 container,
  and its extracted SHA-256 manifest verifies. No login Keychain access occurs.
- The exact clean app, Preview app, and CLI installed after this documentation checkpoint
  are recorded in `/private/tmp/ai-manager-build/final-install-receipt.json`. The receipt is
  the final source revision, package/installed hashes, signatures, launch check, duplicate-
  instance check, and local/public readiness result; it must exist and pass before handoff.
  Native Computer remains unavailable in this tool session, so hover inspection uses the
  window geometry contract and current AppKit render receipts rather than another GUI driver.
- Public direct distribution remains blocked until a Developer ID Application identity and
  repository notarization credentials are supplied. The local release candidate must not be
  described as a notarized public release.

### Page alignment acceptance (2026-09-12)

- The page title and all four page bodies now use the same 24-point leading and trailing
  inset. The removed control-clearance inset no longer reserves Minimize space in layout.
- The titlebar is 48 points high, exactly matching the Close and Minimize cells. Minimize
  remains a floating overlay and does not move the title or page content when it appears.
- Panel headers use Recap Pro's trailing 200 by 40-point concentric-arc art. The native
  Canvas is static, ignores input, and leaves header and content geometry unchanged.
- `scripts/check-native.sh` passes all 79 core tests with two authorized-copy tests skipped,
  both view-model checks, system/light/dark window contracts, single-instance behavior, and
  thin-scrollbar behavior. The installed contract passes at 1120 by 740 points.
- Native Computer is registered, but this Orca host exposes neither the required native-pipe
  connection nor Launch Services bridge. The installed contract and launch receipts are the
  available runtime evidence; no alternate desktop driver was used.

### Import folder and rail acceptance (2026-09-12)

- The import modal now starts with a provider choice. Codex is the only available choice; the
  stored provider ID remains part of every source and account record for later provider support.
- The native chooser opens at the user's home, shows hidden folders such as `.codex`, and accepts
  either a chosen Codex home or its `auth.json`. The selected home is highlighted after discovery.
- The Close surface stops before the rail's existing trailing pixel. The same one-point divider
  now stays visible from the window top to bottom without another overlapping line.
- The current `~/.codex2` structure was inspected without reading credential, settings, transcript,
  or database contents. It already keeps separate auth and SQLite state while linking settings and
  transcript paths to `~/.codex`, which matches the managed-home contract.
- The full native gate passes 79 core tests with two authorized-copy tests skipped, both GUI model
  checks, System/Light/Dark window contracts, single-instance behavior, and thin scrollbars. A hidden
  native light render confirms the final 780 by 600 import layout. Native Computer reached the current
  plugin but its native-pipe startup failed; no alternate desktop driver was used.

### Saved credential and coordinated launch acceptance (2026-09-13)

- Standard production paths now use one live `~/.codex` home and private saved credentials at
  `~/.switch/codex/<account-UUID>.json`. The saved files and live `auth.json` are private regular
  files. Switching never creates a symbolic or hard link and leaves settings, skills, sessions,
  history, and databases in the live home unchanged.
- Import migrates legacy managed credentials into the saved-auth vault without removing the
  source until the vault file and registry both verify. Reviewed destination, backup, shared-home,
  and credential paths are revalidated inside the transaction. Recovery preserves an externally
  changed live or saved credential as a conflict instead of overwriting it.
- GUI and TUI opening use the same coordinated core operation. A cross-process lock covers writer
  validation, outgoing refresh capture, selected credential publication, and successful Codex
  process start. The production app embeds the exact verified CLI at
  `Contents/Helpers/ai-manager`; its terminal launch file delegates to `ai-manager open` and does
  not capture a stale `CODEX_HOME`.
- The macOS gate discovered 88 core contracts: 86 executed and passed, and the two explicit
  protected-copy tests remained opt-in. Production and demo model checks, System/Light/Dark window
  contracts, the custom overlay scrollbar, single-instance behavior, and the fixed-window contract
  also passed. Dark and light account renders confirm the 48-point titlebar, aligned 24-point page
  edges, hidden resting Minimize control, full-width title pattern, and removal of the dead rail mark.
- The exact committed core/TUI tree at `b5ac8ab` passed in read-only `linux/arm64` and
  `linux/amd64` containers. Each architecture executed 86 passing core tests, skipped only the two
  protected-copy opt-ins, and passed CLI discovery, auth-only and full import, activation and open,
  direct and interactive recovery, SQLite linkage, isolated runtime, and private permission checks.
  The documentation checkpoint does not change shipping code.
- The account-switching decision was refreshed against official Codex commit
  `7efa9d96fb34c3cafe108a3c870bfc33e5635772` and current open-source switchers. Codex uses
  `CODEX_HOME/auth.json`, writes file auth with `0600`, and caches auth in running managers. The
  regular-live-file design avoids saved-account corruption through `codex login` or logout.
- Local signing and installation can use the configured Apple Development identity. No Developer
  ID Application identity or notarization credential profile is available, so public readiness
  remains fail-closed and this candidate must not be presented as a notarized public release.

### Switch rename acceptance (2026-09-13)

- The production bundle is `Switch.app`, the design build is an uninstalled `Switch.app` under
  the canonical Preview build directory, and all
  user-facing app, menu, status-item, error, documentation, CI, and release archive names use
  Switch. The bundle identifiers, internal Swift targets, `ai-manager` command, application data
  root, and window autosave key stay unchanged so the rename preserves existing data and window
  placement.
- The native gate discovers 88 core contracts: 86 pass and the two protected-copy checks remain
  explicit opt-ins. Production and demo model checks, System/Light/Dark window contracts, thin
  overlay scrollbars, single-instance behavior, and the fixed-window contract pass.
- The signed production and uninstalled Preview bundles pass strict signature checks. The
  production installation matches its build manifest, and the Preview build passes the System,
  Light, and Dark window contracts with isolated homes. The installed CLI matches the bundled helper and passes
  an isolated status smoke test.
- The prior installed IIA Directeur and Switch Preview bundles are preserved in the canonical
  rollback directory and removed from Applications after the production and uninstalled Preview
  builds verify. The final exact revision,
  hashes, paths, signatures, and readiness state are stored in
  `/private/tmp/ai-manager-build/final-install-receipt.json`.
- Local release readiness passes. Public readiness stops because this Mac has no Developer ID
  Application identity, so the app is not notarized and is not ready for public distribution.

### Preview isolation and supplied icon acceptance (2026-09-13)

- `scripts/launch-switch.sh --preview` builds `/private/tmp/ai-manager-build/preview/Switch.app`
  with `AI_MANAGER_PREVIEW` and opens that uninstalled bundle. It keeps the Preview bundle
  identifier separate from production. There is no installed Preview application.
- Production compilation excludes `Scenario`, all in-memory sample records and paths, mock action
  branches, mock delays, recovery examples, and Preview controls. Both the production model test
  and release-readiness gate inspect the executable and reject stable Preview-only strings and
  symbol names. The
  signed production executable at the icon checkpoint contains none of those strings.
- Icon archive `switch_icon17_asset_pack.zip` has SHA-256
  `f8c74c8bd12e3c76296c80f1f7d3b33508aee700b8cf658e8fdc37697dc93570`.
  Its balanced path is the Dock and rail mark; its heavier menu-bar path supplies the native
  template. Generated light and dark Dock PNGs are 1024 by 1024 with alpha, menu-bar assets are
  22 and 44 pixels, the rail export is 256 by 256, and the ICNS expands to all ten expected slots.
  The app changes its Dock treatment when its selected appearance changes; AppKit tints the
  menu-bar template for the active system appearance.
- `scripts/check-native.sh` passes 86 executed core contracts with zero failures and two explicit
  protected-copy skips, both GUI model checks, System/Light/Dark window contracts, the fixed-window
  and single-instance contracts, and native thin-scrollbar behavior. The clean signed release at
  code checkpoint `51b6846` passes local readiness and strict signature checks.

### Native menus and symmetric mark acceptance (2026-09-13)

- Production and compile-time Preview now install the same AppKit menu structure: Switch, File,
  Edit, View, Window, and Help. The application menu contains the standard About panel, Settings,
  Services, Hide, Hide Others, Show All, and Quit commands. The fixed window exposes no Zoom or
  maximize command.
- Command+, presents the existing main window and changes its content route to Settings.
  Command+1 through Command+4 select Accounts, Settings, Chat History, and Recovery. The
  GUI contract dispatches these real menu items and verifies both window presentation and every
  resulting page route, rather than checking menu labels alone.
- The supplied reference PNG has SHA-256
  `1fba71d24c2f6488f6fca711befb35b08523c924a9a08b0aae064686007c5b2e`. The approved production
  vector is the direct Pixel trace from the HTML review. Its source-canvas binary edge mismatch
  is 516 pixels, or 0.0871%. The earlier fourfold hand-fit mark is removed.
- Dock and Spotlight keep explicit light and dark graphite treatments around the same mark. The
  menu-bar and rail assets scale the identical trace without changing its counters. The generated
  Dock PNGs are 1024 by 1024, the rail export is 256 by 256, every PNG has alpha, and the ICNS
  expands to all ten standard macOS slots.
- `scripts/check-native.sh` passes 88 discovered core contracts: 86 execute without failure and
  the two authorized private-copy tests remain opt-in. Both GUI models, System/Light/Dark menu and
  window contracts, thin overlay scrollbars, and single-instance behavior pass at code checkpoints
  `feec7f3` and `c496190`.

### Raster trace review acceptance (2026-09-13)

- `docs/design/switch-icon-trace-preview.html` is a standalone 791 KB comparison artifact. It
  embeds the 733-by-808 supplied PNG, the prior rejected app vector, one direct pixel trace, and
  three symmetry-strength traces without external URLs or runtime requests.
- The direct candidate was produced locally with Potrace 1.16 at a 45% luminance threshold,
  alpha max 1.0, no speck removal, and no curve optimization. Its binary edge mismatch is 516 of
  592,264 source-canvas pixels, or 0.0871%.
- The balanced candidates reconstruct the outer silhouette from the untouched upper-right
  quadrant with 24, 40, and 64 Fourier harmonics. The upper circular counter and lower open-ring
  counter are preserved from source pixels, including the solid inner disc and its opening into
  the body.
- The artifact provides split, overlay, vector, and source modes; light and dark presentation;
  exact-size 16, 22, 32, 44, and 64 pixel samples; and an SVG download for every candidate.
  Headless Chrome renders of the default dark split view and light balanced vector view pass at
  1440 by 900. Pixel trace was subsequently selected for production.

### Approved Pixel trace deployment acceptance (2026-09-13)

- `SwitchMarkPixelTrace.svg` is the only production silhouette source. Its SHA-256 is
  `bdeec18e308f1587716dbd4f5b0b9adf73ed4fe8bfeed3a8953e08cc8843f252`. The prior
  `SwitchMarkBalanced` source and raster are removed. Dock, Spotlight, rail, and menu-bar assets
  use the approved geometry; only placement, scale, and color vary by context.
- `scripts/check-icon-assets.sh` locks the approved SVG hash, rejects deprecated geometry,
  validates every SVG, proves the rail and menu-bar wrappers render the same trace, regenerates
  and byte-compares all tracked PNGs, and rebuilds and byte-compares the ten-slot ICNS. It runs
  as part of the native gate and passes.
- The full native gate passes 88 discovered core contracts: 86 execute without failure and the
  two protected-copy checks remain explicit opt-ins. Production and Preview model checks,
  System/Light/Dark window contracts, the fixed-window contract, thin overlay scrollbars, and
  single-instance behavior also pass.
- Icon code checkpoint `ac7c905b99ca` is signed with the configured Apple Development identity
  and passes local release readiness. The final clean package built after this documentation
  checkpoint is recorded in `/private/tmp/ai-manager-build/final-install-receipt.json`.
  `/Applications/Switch.app` and `~/.local/bin/ai-manager` match that package; the bundled helper
  and installed CLI are identical. The installed app launches, rejects a duplicate instance, and
  contains the exact committed SVG and ICNS. The isolated installed CLI status smoke passes. The
  pre-Pixel-trace installation is preserved at
  `/private/tmp/ai-manager-build/rollback/20260913T052250Z`.
- Native Computer remained unavailable at its read-only app-state step with
  `Sky Computer Use native pipe startup failed`; process, package, signature, resource, contract,
  and isolated runtime checks supply the completed installation evidence.

### Icon composition and import-layout acceptance (2026-09-13, Dock treatment superseded)

- The 640-point Dock treatment at x 183, y 199 was rejected after installation because the mark
  still occupied 76% of the tile width, the blue graphite remained too light, and the two-point
  edge lift remained too bright. The import-layout results below remain accepted. The replacement
  Dock treatment is recorded in Revised Dock composition acceptance.
- The import titlebar and Close cell are both 48 points high. Close owns the trailing 48-point
  region, touches the modal's top and trailing edges, and fills with system red on hover. The step
  indicator is fixed-size with a reserved 16-point gap before Close. It cannot enter the close-cell
  layout region.
- Source, scope, explanation, and action groups use a 16-point vertical rhythm. Modal content and
  title start on the same 24-point edge. Source rows use the 16-point panel edge, 64-point minimum
  height, and top-align the checkbox and status badge with the first text line. The 780 by 648-point
  modal keeps the standard three-source state visible at the fixed 1120 by 740 window size.
- Native Light and Dark import renders were inspected at full resolution. They show all three
  source rows, aligned controls, uninterrupted section gaps, a flush close cell, and a stepper that
  ends before Close. `scripts/check-native.sh` passes 88 discovered core contracts: 86 execute with
  zero failures and two protected-copy checks remain explicit opt-ins. Both GUI models,
  System/Light/Dark contracts, single-instance behavior, thin scrollbars, and deterministic icon
  regeneration pass.
- The exact committed core and CLI passed `scripts/check-linux.sh` in read-only unprivileged
  `linux/arm64` and `linux/amd64` containers. Each architecture executed the same 86 core contracts,
  skipped only the two protected-copy opt-ins, and passed CLI discovery, import, switching,
  recovery, SQLite, permissions, symlink, and isolated-runtime acceptance. Code checkpoints
  `7eb400e` and `cedd8a1` pass their scoped contracts; the final signed installation and exact
  revision are recorded after this documentation checkpoint.

### Navigation and chat-history acceptance (2026-09-13, revised 2026-09-14)

- The rail and View menu now use the same order: Accounts, Backup, Chat History, and
  Settings. Command+1 through Command+4 follow that order, Command+, opens Settings,
  Backup uses the archive-box symbol, and Chat History uses the native two-bubble conversation
  symbol. Recovery remains the internal operation and data-contract name so existing journals,
  commands, and repair behavior stay compatible.
- Chat History indexes the current Codex `sessions` and `archived_sessions` trees and loads the
  selected transcript into a separate readable message pane. Production contains no sample
  conversations; the three example threads remain behind `AI_MANAGER_PREVIEW`.
- The left thread pane and right message pane each own a search field. Thread search covers title,
  preview, working directory, and thread ID. Message search covers the already loaded user and
  Codex messages without reading the transcript again. Each field has its own count, empty state,
  clear action, 120 ms debounce, and cancellation of obsolete work. The former green-dot status and
  `Live` label are removed.
- `ChatHistoryIndex` is an actor. It streams JSONL records, caches each regular file by size and
  modification date, reparses only changed files, and runs changed-file work in a utility-priority
  task group capped at six workers. Selected-thread detail parsing runs in a cancellable detached
  user-initiated task. The main actor receives prepared snapshots and search results only. The
  750 ms visible-page poll is superseded: one initial scan and coalesced file-system change events
  trigger refreshes. No timer scans an unchanged library. Unchanged results and repeated nil errors
  do not publish view-model changes, so the selected transcript and scroll position remain stable.
  Lazy detail loading and bounded message and character counts prevent transcript work from
  blocking UI input. Both panes use native virtual tables with overlay scrollbars; the 1,717-thread
  stress fixture realizes 15 table rows at the captured viewport instead of 1,717 SwiftUI rows.
- Prepared thread summaries and file signatures persist in a versioned private cache under the
  Switch application-support root. A later launch reuses entries whose path, size, and modification
  date still match, so it does not reread unchanged transcript bodies. The cache uses `0700` parent
  directories and a `0600` regular file, contains no authentication or full message list, and falls
  back to a fresh scan if validation or decoding fails.
- Transcript discovery does not follow symbolic links and retains the 500,000-entry traversal
  ceiling. Summary scans bypass oversized non-visible tool-output records before JSON decoding;
  visible records are bounded at 4 MiB and the existing JSONL hard ceiling remains 64 MiB. Tests
  cover current and legacy records, duplicate-user suppression, incremental reparsing, malformed
  records, symlink refusal, and a 5 MiB tool-output record followed by visible chat.

### Chat-history naming and reading-comfort acceptance (2026-09-14)

- Thread rows use Codex's persisted thread name or title from `state_5.sqlite` when it is meaningful.
  Explicit user names have first priority. Injected `AGENTS.md`, global instruction,
  `environment_context`, and similar bootstrap payloads never become a visible title. Older homes
  without usable database metadata fall back to the first meaningful user request and then a calm
  project-based label.
- Database metadata is read with a read-only SQLite connection off the main actor and overlaid on
  cached summaries without rereading unchanged transcript bodies. Existing version-1 private
  caches migrate in place so the title repair does not trigger a multi-gigabyte rescan. A changed
  database name, title, preview, working directory, recency, or archive flag refreshes the library
  revision and selected detail while preserving the transcript cache.
- The thread list presents only the canonical title and its project or folder. It omits preview
  excerpts, timestamps, archive labels, and per-row message counts. Restrained alternating row
  surfaces separate adjacent conversations without adding borders or card shapes; hover and
  selection remain visually dominant. The reader presents one title and one compact context line,
  shows a result count only for an active message search, and removes the separate raw-ID/byte-count
  metadata card.
- Messages share one neutral reading surface with a bounded text measure, 13-point Geist body,
  generous line spacing, and restrained role labels. Full-width blue and gray message cards are
  removed. Long instruction-heavy conversations remain selectable, virtualized, and visually calm
  in both Light and Dark appearances.
- [x] Prove canonical SQLite naming, instruction-payload filtering, version-1 cache migration, and
  metadata-only refresh with synthetic homes.
- [x] Capture and inspect the 1,717-thread stress page in Light and Dark appearances, then rerun the
  complete native and two-architecture Linux gates before installing the exact committed build.
- Synthetic contracts prove explicit-name precedence, database-title fallback, bootstrap-context
  removal from titles and visible messages, zero-reparse database renaming, and in-place migration
  of a private version-1 summary cache to version 2. Markdown shaping for selected messages runs in
  a cancellable detached task before the main actor publishes the detail.
- Full-resolution Light and Dark stress renders at
  `/private/tmp/switch-chat-redesign-review.dlmF6s/light/artifacts/window.png` and
  `/private/tmp/switch-chat-redesign-review.dlmF6s/dark/artifacts/window.png` were inspected at
  1120 by 740. Both show the neutral selected row, one-line conversation summaries, single reader
  context line, bounded message measure, and card-free reading surface.
- `scripts/check-native.sh` passed the 97-test core inventory with zero failures and only the two
  authorized private-copy skips. Production and Preview model checks, Pixel icon, System/Light/Dark
  window contracts, single-instance behavior, overlay scrollbars, and virtual history tables pass.
  Read-only unprivileged `linux/arm64` and `linux/amd64` containers passed the same 97-test inventory
  and complete release CLI acceptance.
- The clean release candidate from `ab0181b6c4ce` passed local release readiness and is installed at
  `/Applications/Switch.app`; its main executable SHA-256 is
  `523fd0744e1a8b10fe39ef45e73c373f4af82157357642ab5587156902eb5d3c`. The matching CLI is installed
  at `~/.local/bin/ai-manager` with SHA-256
  `f0a3f339b3c836a81a52707f4102e6a00b4be11758fc5cdb809933812fb26e31`. Both hashes match the built
  artifacts, strict signature checks pass, a double launch leaves one process, and the installed
  app remains alive after startup.
- `scripts/check-native.sh` discovered 94 core contracts: 92 executed without failure and the two
  authorized private-copy tests remained explicit opt-ins. Production and Preview model checks,
  System/Light/Dark window contracts, the Pixel-trace icon, fixed-window geometry, thin overlay
  scrollbars, single-instance behavior, two-search presence, and bounded virtual-row realization
  passed. Final dark and light 1120 by 740 stress renders are stored at
  `/private/tmp/switch-chat-history-review.zg6w20/artifacts/window.png` and
  `/private/tmp/switch-chat-history-light.XSvvJ0/artifacts/window.png` and were inspected at full
  resolution.
- The same source passed `scripts/check-linux.sh` as user 10001 from a read-only repository mount
  in `linux/arm64` and `linux/amd64` containers. Each architecture discovered 94 tests, executed 92
  without failure, skipped only the two protected-copy opt-ins, and passed the release CLI,
  discovery, import, activation, backup, SQLite, symlink, permission, and isolated-home checks.
- The final thread rail uses compact 50-point rows with only the canonical title and the last
  project or folder component. Preview excerpts, relative times, archive markers, and message
  totals are absent. Zero row spacing creates a continuous table, and a 42% blend of the secondary
  panel color gives alternate rows a restrained stripe beneath the stronger hover and selection
  states.
- Full-resolution Light and Dark 1,717-thread renders at
  `/private/tmp/switch-striped-review.Bpe52E/light/artifacts/window.png` and
  `/private/tmp/switch-striped-review.Bpe52E/dark/artifacts/window.png` were inspected at 1120 by
  740. Both show two-line rows, uninterrupted zebra striping, distinct hover and selection layers,
  and the unchanged bounded reading pane. `scripts/check-native.sh` passed all 97 discovered tests
  with zero failures and the two authorized private-copy skips, plus both model checks, the Pixel
  icon, every appearance contract, single-instance behavior, overlay scrollbars, and bounded table
  realization.
- The clean release from `44216d0b2925` passed local release readiness and is installed at
  `/Applications/Switch.app`. The app executable SHA-256 is
  `88aa2ae6bc036efa5bf72e0f778c12bcec29e93747b1c4a692ca2ca815cc2c28`; the installed CLI SHA-256
  is `e305d1045a52ede984912eac0078b0ee3ff4a068fc6c8e4161cb768d1430eb03`. Both match the built
  artifacts, strict signature checks pass, a double launch leaves exactly one process, and the
  prior app is retained at `/private/tmp/Switch.previous.20260914133956.app`.

### Warning controls and rail-scale acceptance (2026-09-13, revised 2026-09-14)

- The Chat History rail glyph is 12.75 points, exactly 75% of the standard 17-point rail glyph,
  while its selection surface and hit target remain 48 by 48 points. The native menu contract locks
  the ratio. A full-resolution dark render at
  `/private/tmp/switch-chat-icon-review.RWkqBe/artifacts/window.png` confirms that the smaller glyph
  remains optically centered with the other rail controls.
- Auth-only planning previously promoted every intentionally excluded top-level entry into a
  warning even though the manifest already explained it. Those expected scope exclusions now stay
  in the manifest without producing warning cards. Import warnings are reserved for actionable
  symbolic-link review and active-source conditions. The focused contract proves that a large
  excluded package tree produces one manifest entry and zero warnings.
- Error bars, shared-setting repair items, pending backup operations, Chat History scan notices,
  hidden-message notices, import warning lists, and unresolved import results expose copy actions.
  Warning groups have one bulk action that copies a numbered plain-text list and changes briefly to
  a success state. Preview and isolated production checks prove that test builds never change the
  workstation clipboard.
- The read-only live-history diagnosis found 1,687 transcripts totaling 19,290,875,312 bytes. No
  transcript file failed indexing; one transcript contained eight oversized or malformed records.
  The history warning now describes skipped files and records accurately and copies that diagnostic
  without exposing transcript content.
- `scripts/check-native.sh` discovered 94 tests, executed 92 without failure, and skipped only the
  two explicit protected-copy opt-ins. Production and Preview model checks, System/Light/Dark
  contracts, deterministic icon output, fixed-window behavior, thin scrollbars, and single-instance
  behavior passed. Read-only unprivileged `linux/arm64` and `linux/amd64` containers each produced
  the same 92 passes and two opt-in skips, then passed the complete CLI acceptance.

### Revised Dock composition acceptance (2026-09-13)

- The approved Pixel trace remains byte-identical at SHA-256
  `bdeec18e308f1587716dbd4f5b0b9adf73ed4fe8bfeed3a8953e08cc8843f252`.
  Its 520-point foreground box is placed at x 245, y 258. It occupies 61.9% of the 840-point tile
  width and leaves at least 140 points between the nominal mark box and every tile edge.
- The first cool graphite revision was rejected because it still read blue. Every final gradient
  stop is neutral grayscale. Light uses `#292929`, `#202020`, and `#171717`; Dark uses `#232323`,
  `#191919`, and `#111111`. The one-point edge lift peaks at 0.07 opacity in Light and 0.05 in
  Dark. Lower shading peaks at 0.12 and 0.16. The 1024-point comparison at
  `/private/tmp/ai-manager-build/icon-black-composition-review.png` shows the cool installed tile
  and final neutral-black tile side by side.
- Deterministic asset regeneration passes. Light PNG SHA-256 is
  `d49d80f779c7dda9a9e19f9c25c0ab7e7f412a74f2af5bea76d65bedadba0c6d`, Dark PNG SHA-256 is
  `e064402cf24f3e1e23118d29c0d684a8460e8f56a21945bd12b777a83b62ecdc`, and ICNS SHA-256 is
  `36086cccf70734c201da27287414d54c3ceb9ace00362619fbba30291b019940`.
- `scripts/check-native.sh` discovered 92 tests, executed 90 without failure, and skipped only the
  two explicit protected-copy opt-ins. Production and Preview model checks, System/Light/Dark
  window contracts, deterministic icon output, fixed-window behavior, thin scrollbars, and
  single-instance behavior pass. The exact signed installation is recorded after this checkpoint.

### Mac window placement, package, and terminal acceptance (2026-09-13)

- The Mac GUI stores the selected display identity and the fixed window's top-left offset inside
  that display's visible frame. It restores negative desktop coordinates, follows a saved display
  after macOS rearranges the desktop, and clamps the 1120 by 740 window into the current visible
  frame. If the saved display is disconnected, the app centers on an available display without
  replacing the external-display preference until the user moves the window.
- The migration recognizes the workstation's legacy AppKit record for `Gigabyte M32U` at
  `{-732, 1460}` even though the old record stored a 2130-point usable height and the current
  display reports 2160 points. Synthetic contracts cover negative coordinates, rearrangement,
  clamping, missing displays, unrelated legacy frames, and a UserDefaults encode/decode round trip.
  This supersedes the earlier frame-autosave-only acceptance claim.
- The macOS-only package is now `packages/mac-gui`, and its Swift target is `AIManagerMacGUI`.
  Mac-only build and acceptance scripts use `mac-gui` names. The shipping product remains
  `AIManager` inside `Switch.app`, so the executable, bundle identity, user data, and installed
  command stay compatible.
- `packages/tui` remains the macOS and Linux terminal implementation. It provides the
  `ai-manager` command set and a prompt-driven `ai-manager interactive` flow backed by
  `AIManagerCore`; it is not a full-screen two-dimensional terminal interface. The macOS binary
  built and its discovery and interactive review ran until the active Codex process correctly
  blocked mutation because writer ownership was unknown.
- `scripts/check-native.sh` passed all 92 discovered tests with 90 executions and two authorized
  private-copy skips. Both Mac GUI models, the Pixel-trace icon, System/Light/Dark window and menu
  contracts, single-instance behavior, and thin scrollbars passed after the rename. Read-only,
  unprivileged `linux/arm64` and `linux/amd64` containers each passed the same test inventory plus
  the complete release CLI discovery, import, activation, open, recovery, SQLite, symlink,
  permission, and isolated-home acceptance flow.

### Dock top sheen acceptance (2026-09-13)

- Light and Dark icons now add one top-biased white gradient above the unchanged neutral-black
  tile. It peaks at 0.035 opacity in Light and 0.028 in Dark, drops to roughly one-third strength
  after the top quarter, and reaches zero at 46% of the tile height. The approved Pixel trace
  remains byte-identical at SHA-256
  `bdeec18e308f1587716dbd4f5b0b9adf73ed4fe8bfeed3a8953e08cc8843f252`.
- Deterministic regeneration and byte comparison pass. Light PNG SHA-256 is
  `5f01281668ccc46b78101463c3156d5e0b4ebfe7cbf27704de98ae395a6e5cd8`, Dark PNG SHA-256 is
  `6007c40e4a27eff5e64c516836a4d3c5ba606e0a37bc44c147df55557afbe122`, and ICNS SHA-256 is
  `8c405363493be0767e6b1177585b115ad7dd6c48ff60e551bedea6ac442aa475`.
- The 1024-point before/after Light and Dark comparison at
  `/private/tmp/ai-manager-build/icon-top-sheen-review.png` was inspected at full resolution. The
  top lift is visible without changing the dark center or lower shading. The Impeccable detector
  returned no findings, and the exact-source native gate passed all Mac GUI and icon contracts.

### Transactional onboarding, statistics, and workstation migration (2026-09-14)

- First launch now adopts a valid regular live `~/.codex/auth.json` into an opaque UUID credential
  vault without changing the live file. Add Account starts Codex browser sign-in in a private,
  app-owned `CODEX_HOME`; Check Now imports the completed identity, Cancel removes only that
  session, and both operations resume safely after an app restart. A newly added account is saved
  without replacing an existing default until the user chooses Use for New Sessions.
- The provider catalog is ready for additional adapters. Codex CLI is enabled; Claude Code,
  Gemini CLI, and Antigravity CLI are present as WIP. Advanced Import remains
  available for an existing Codex folder or `auth.json` while the ordinary path stays focused on
  Add Account.
- Account usage uses Codex app-server account APIs from a disposable private home containing a
  copy of the selected credential. The transport never reads from or writes to the live home,
  releases the mutation lock while waiting, rejects stale results after a concurrent account
  change, never copies token rotation back, and removes its temporary home on success or failure.
  Bounded private SQLite caching keeps the menu-bar popover instant and retains rate-limit data if
  the optional activity endpoint is unavailable.
- The Mac account page presents returned limit windows and statistics while omitting optional
  fields that the backend did not return. Explicit zero and false values remain visible. Usage
  and switch failures have copy actions. The fixed-width
  menu-bar popover shows six virtualized account rows at most, cached quota detail, Add Account,
  and direct account switching without starting a network request when it opens.
- The terminal interface exposes the same provider order and Add, Check, Cancel, status-resume,
  Advanced Import, switch, open, and recovery operations. Human and JSON output carry stable
  session commands without credential content. First-run status adopts the current login and
  lists unfinished login sessions without changing the existing top-level status fields.
- The complete native gate discovers 149 core contracts and passes 147 with zero failures; the two
  protected-copy integrations remain opt-in in the ordinary gate and previously passed separately
  against an authorized minimal private copy of the workstation home. Production and Preview
  models, official provider assets, the Pixel icon, System/Light/Dark window contracts, fixed
  geometry, single-instance behavior, menu commands, and thin overlay scrollbars pass. Read-only
  unprivileged `linux/arm64` and `linux/amd64` containers pass the release build, core suite, and
  full CLI acceptance.
- The earlier workstation migration claim that `me@surajmandal.in` was a valid third account is
  superseded. That unconfirmed label came from the legacy `~/.codex/auth.json.me.switch` snapshot,
  not a live Codex account check. Its Switch registry record, UUID vault file, and app-owned managed
  home were deleted through the recoverable account-removal transaction. The source snapshot stays
  private and unchanged. Switch now contains `me@mandalsuraj.com` as the default and
  `surajmandalcell@gmail.com` as the second saved account; status reports no pending recovery or
  login session. Shared config, chats, and the live credential remain unchanged in `~/.codex`.
- A real non-model account check reports an explicit Codex sign-in requirement for the current
  `me@mandalsuraj.com` credential. The Gmail credential passes all local format, identity, digest,
  ownership, permission, and regular-file checks; when Codex's optional account service is
  unavailable it remains `Verified locally`. Opening the current account through Switch with
  `--version` exits successfully with Codex CLI 0.155.0-alpha.3.9 and leaves the live credential
  digest unchanged.
- The earlier rule that blocked switching whenever any Codex process existed is superseded. A chosen
  default applies to new sessions immediately without terminating existing Codex processes.
  The exact clean signed installation and hashes are recorded outside the repository in
  `/private/tmp/ai-manager-build/final-install-receipt.json`.

### New-session switching, reader filters, and compact menu acceptance (2026-09-14)

- Selecting an account now publishes its saved credential for new Codex sessions without inspecting
  or terminating existing Codex processes. The transaction, credential digests, rollback journal,
  and recovery checks remain mandatory. A returned account whose ID matches the saved credential is
  authenticated even when the app-server also reports that a different open session needs auth.
- Every saved Codex credential can be checked from a disposable private home and refresh its own
  cached usage without becoming the default. Fresh Add Account and Advanced Import results expose
  the same refresh action. A credential classified as needing sign-in cannot show a stale quota.
- Add Account has no introductory copy block or redundant Providers heading. Unsupported rows say
  WIP. The three steps share one stable 480-point canvas and a reserved progress/error region;
  step changes no longer use opacity, offset, or geometry transitions. Advanced Import retains its
  648-point data-review canvas and the same stable progress/error region.
- Chat History parses prompts, responses, function/custom/shell/web tool calls and results, plus
  visible reasoning summaries into four filterable categories. Raw or encrypted reasoning remains
  excluded. The filter mask persists, is applied before text search, and Copy shown exports exactly
  the displayed chronological rows with stable category labels and ISO timestamps. Parsing remains
  detached, cancellable, record-bounded, message-bounded, and cache-versioned.
- Ten separate flat menu-bar directions and a combined review sheet are under
  `/private/tmp/ai-manager-build/menu-design-options/`. The selected native ledger became a
  384-point, three-pixel-corner popover with no presentation animation, six virtualized rows at
  most, zebra separation, 5-hour and weekly columns, direct switching, per-account usage refresh,
  refresh-all, Add Account, Open Switch, Quit, and copyable row errors. The actual SwiftUI render is
  emitted as `menu-bar.png` by the Mac GUI acceptance harness.
- Clean commit `7748bac` passed `scripts/check-native.sh`: 152 contracts were discovered, 150
  executed successfully, and only the two explicit authorized-private-copy integrations were
  skipped. Pixel icon generation, Preview and production models, System/Light/Dark GUI contracts,
  compact wizard pixels, menu pixels, native scrolling, and single-instance behavior passed.
  Read-only unprivileged `linux/arm64` and `linux/amd64` Docker containers then passed the same
  152-contract inventory, release build, and full CLI/TUI acceptance from that commit.

### Dark surfaces, conditional usage, and Settings acceptance (2026-09-14)

- Dark mode now uses the neutral palette in `docs/specs/product.md`: rail `#141517`, canvas and
  menu chrome `#18191B`, panel `#202124`, raised stripe `#27282B`, secondary raised surface
  `#2F3034`, hover `#303238`, and selection `#393C43`. Semantic colors were raised for readable
  contrast against those darker surfaces.
- The menu popover passes its effective dark appearance through every native virtual row. Its
  account, quota, state, and trailing-action slots share one fixed grid; missing quotas remain
  blank while explicit zero remains visible. The conversation-list heading likewise reserves
  centered count, warning, and status slots on one 40-point row.
- Optional usage values render only when returned. Missing plan, credits, spend control,
  secondary windows, summary statistics, and incomplete daily rows take no UI space. Explicit
  zero and false values remain visible, while the unchecked, refresh-error, and no-rate-limit
  states remain actionable.
- The Settings page now contains App behavior and Data locations for the live Codex home and saved
  account vault. The obsolete Shared Settings name and Linked entries inventory are gone from the
  current interface. Legacy link repair remains an account-specific compatibility path only when
  an existing migrated record needs action.
- `scripts/check-native.sh` passed 152 discovered core contracts: 150 executed with zero failures
  and the two authorized-private-copy integrations remained explicit opt-ins. Preview and
  production models, Pixel artwork, System/Light/Dark window and menu contracts, single-instance
  behavior, native scrolling, and focused presentation contracts passed. Dark Accounts, Settings,
  Chat History, and menu renders were inspected under `/private/tmp/switch-dark-final.kBpUq7` and
  `/private/tmp/switch-dark-review.8NJ9nS`.

### Menu-bar scope and account preferences (2026-09-14)

- The menu popover is for switching and viewing limits. Remove its brand/count/refresh header,
  column header, session explanation, Add Account action, and Quit action. Use compact account
  cards with a dedicated Switch control; expand only usage-enabled cards with separate Weekly
  and 5 hour progress rows. Keep an updated timestamp and Open App action in the 48-point footer.
  The popover stays 384 points wide and scrolls at a 440-point maximum height.
- Usage display starts off. Each account has a Show usage in menu bar toggle and can return to
  the Settings default using Use default. Explicit per-account choices persist by account ID;
  changing the default affects only accounts without an override.
- The same preference controls row limits and the active tray percentage. Hidden usage has no
  placeholder or refresh action; all accounts remain available for switching. This preference
  does not alter account-page usage, saved credentials, or the live Codex home.
- Verification: `scripts/check-native.sh` passed 152 discovered core contracts (150 executed,
  two explicit private-copy opt-ins skipped), production/Preview model checks, icon contracts,
  System/Light/Dark window and menu contracts, single-instance behavior, and native scrolling.
  Preference checks cover inheritance, explicit overrides, Use default, reopening the preference
  store, and hiding cached limits and the active tray percentage.

### Menu-card, wizard, and typography acceptance (2026-09-15)

- The menu popover is a 384-point account-card list with a 440-point height cap. Usage-enabled
  accounts expose separate Weekly and 5 hour bars, eligible accounts have a dedicated Switch
  control, and the footer contains only the last update time and Open App. The removed header,
  columns, refresh, session note, Add Account, and Quit controls have no remaining popover actions.
- Account rows and identity badges use provider names such as Codex CLI instead of repeating
  verification copy. Action-needed states remain separate. Add Account and Advanced Import use
  full-height titlebar steps, balanced 16-point content/action spacing, and panel-aligned checkboxes.
- Inter, Lora, and PT Mono replace Geist for interface, display, and technical text respectively.
  Production and Preview bundles include the exact font files and their OFL licenses.
- `scripts/check-native.sh` passes all 153 discovered core contracts: 151 execute successfully and
  the two protected-copy integrations remain explicit opt-ins. Production and Preview model checks,
  Pixel icon assets, System/Light/Dark window and menu contracts, single-instance behavior, and
  native overlay scrolling pass. The final dark menu, Add Account, Advanced Import, Accounts, and
  settled light modal renders were inspected at full resolution in the canonical build cache.
- The Ponytail debt audit finds two existing safety deferrals in `AccountManager.swift`, each with
  an explicit upgrade trigger; this work adds no marker and leaves no marker without a trigger.

### Cleanup, activity calendar, and compact-control refinement (2026-09-15)

- Remove Lora. Inter owns all interface, reading, and display text; PT Mono remains limited to
  technical values.
- Center 28-point step tabs against the modal title instead of stretching them to 48 points.
- Match Active, Switch, and Sign in as compact ghost controls. Show the newest cache refresh time
  at the footer's left edge even when an account hides its usage.
- Replace the Daily activity date table with a selectable activity calendar for 7 days, 1 month,
  and 1 year. Selecting a day reveals its exact token count.
- The basic Cleanup page was implemented and verified during this checkpoint, but the deferred
  Cleanup specification below supersedes it as an acceptance target.
- Verification (2026-09-15): all 154 native tests pass with only the two explicit protected-copy
  fixture skips. Pixel-trace icon, mock/production view-model, system/light/dark GUI, single-instance,
  and native-scroll contracts pass. Visual inspection covered Accounts, Add Account, Cleanup, the
  menu popover, and activity-cell selection with its exact token count.

### Deferred advanced Cleanup (2026-09-15)

- Pause Cleanup development. The existing basic page is a frozen prototype, not a finished or
  release-accepted Cleanup experience. Resume only after an explicit user request.
- Replace the flat cache actions with a disclosure tree grouped by provider, account, and cache
  type. Keep shared indexes in their own branch and leave room for future providers.
- Add Chrome-style time ranges: last hour, last 24 hours, last 7 days, last 4 weeks, and all time.
  Add a custom start/end interval for cache records that carry timestamps.
- Calculate the selected item count and estimated reclaimed size without blocking the UI. Show the
  exact tree selection and time range in a final review before clearing, plus a completion receipt.
- Keep accounts, saved auth, settings, and source conversations outside Cleanup. Any future action
  that can remove durable user data requires a separate explicit design and confirmation flow.
- No implementation work is authorized for this deferred milestone yet.

### Tray usage and Cleanup icon refinement (2026-09-15)

- Only advanced Cleanup development is deferred. Continue the remaining accepted product work.
- Replace the Cleanup rail's destructive trash symbol with the native eraser symbol. Keep trash
  only on actions that remove data.
- Show cached account usage in the menu bar by default. Keep the global and per-account controls
  so a user can opt out without affecting usage in the main window.
- Match the accepted menu reference with compact bordered cards. Put each quota name over its
  percentage, the progress bar in the center, and the reset time at the right. Keep equal compact
  Active, Switch, and Sign in controls, a subtle dark gradient, the refresh time at bottom left,
  and Open App at bottom right. Do not restore the removed header or Add Account action.
- Verify the fresh preference default, explicit opt-out, stable card geometry, native Cleanup
  symbol, dark and light snapshots, and the installed tray percentage.
- Verification: the fresh-default regression failed against the old code and passed after the
  shared preference fix. System, Light, and Dark GUI contracts pass. Dark and Light menu renders
  show both quota rows, equal compact actions, the footer timestamp, and Open App.

### Quieter interface and inverse Dock artwork (2026-09-17)

- Invert the Dock and Spotlight treatment to a dark approved pixel-trace glyph on a light
  neutral tile. Preserve the trace, padding, placement, and restrained top sheen in both themes.
- Continue the accepted account, menu, chat, and native-app work. Only advanced Cleanup
  implementation remains deferred.
- Icon verification: regenerated both PNG treatments and the Spotlight ICNS, inspected both
  full-size renders, and passed the locked pixel-trace and generated-asset contract.
- Make Close hover brighter red and Minimize hover brighter yellow, preserving the floating
  square controls and continuous sidebar divider.
- Reduce visual clutter: place status badges and a tooltip menu-usage icon in Identity's
  header; remove the separate usage-display row; keep Use/Open labeled and make Check, Copy,
  and Refresh quiet icons. Retain preference inheritance, reset, accessible state, and guards.
- Halve decorative pattern opacity and reduce header tint by section importance. Keep Inter
  for prose and PT Mono for technical data rather than forcing fonts or dimming essential text.
- UI verification: System, Light, and Dark contracts pass. Accounts, Add Account, and menu
  renders were inspected; identity content keeps its left alignment after removing the badges
  from the body. Preference inheritance and reset still use the existing UUID-based contract.
- The full gate reproduced the synthetic noisy-server test's one-second pipeline startup
  race. Generate its oversized JSON with shell-builtin printf rather than spawning head/tr;
  retain the same timeout and byte limits. The focused regression and full native gate pass:
  154 discovered, 152 passed, two protected-copy opt-ins skipped, plus production/Preview
  models, locked icon assets, three appearance contracts, single-instance, and native scrolling.

### Resumed login and protected-copy audit (2026-09-14)

- The completion audit reproduced a CLI failure after process restart: Check Now rejected a
  completed private login when an unrelated Codex process existed. Two new regression tests
  failed with `writerStateUnknown` before the fix and all 14 onboarding tests passed afterward.
- Completed unowned logins now import through the existing identity/digest transaction and retire
  their private session metadata. Cancellation also retires an unowned session. Both retain the
  staging home because its process may still be using it. Retired IDs cannot be reused and do not
  reappear as pending. Owned processes retain the existing stop-and-clean-up behavior.
- The installed CLI acceptance exposed this defect instead of proving the entire Mac mutation
  flow. The corrected CLI explicitly passes resumed login and cancellation on this Mac; its
  later full-import stage still reports a writer-ownership skip. Full import remains covered by
  isolated production-model, core, protected-copy, and Linux tests without weakening its guard.
- Both opt-in integrations passed against the existing protected 26 GB Codex-home copy in
  318.697 seconds. All 1,604 transcripts were accounted for, 1,257 imported, and source auth stayed
  byte-identical. Peak RSS was 628,916,224 bytes. Logs remain in
  `/private/tmp/ai-manager-validation/current-core-test.log` and `evidence-current-core/`.
  The disposable imported output was removed; the original protected source remains untouched.
- The full native gate passed 153 discovered core contracts: 151 executed successfully and the
  two separately verified protected-copy tests remained opt-in. Production and Preview models,
  System/Light/Dark native contracts, icon assets, scrolling, and single-instance checks passed.
- Read-only, unprivileged ARM64 and AMD64 Docker containers passed the same 153-contract inventory,
  release CLI build, and complete CLI acceptance, including resumed login, cancellation, full
  import, switching, launch, and recovery. Their tested core and CLI sources match this checkpoint;
  logs are `/private/tmp/ai-manager-build/linux-{arm64,amd64}-current.log`.
- Two safety deferrals remain in `AccountManager.swift`: legacy mutation checks need a reliable
  home-scoped Codex lock/probe; automatic cleanup of unowned login homes needs durable proof that
  their process exited. Neither trigger is available. There are no markers without a trigger.
