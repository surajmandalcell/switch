# AI Manager: native macOS Codex account manager

Status: implementation and native GUI acceptance in progress. Core and CLI validation
pass; Computer access, Git writes, and an existing development signing identity are now
available. The full G1–G6 completion gates remain unmet.
Decision date: 2026-09-11.
Repository baseline: `e7bb55bf2dea7c05072d85481aa5652ab4cdfe16` on `master`.

## 1. The outcome

Build one reliable workflow: import Codex accounts and choose which account Codex uses.
Ship it as a native macOS app. Support Codex only.
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
Use `packages/core` for shared Swift contracts and account operations, `packages/gui`
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
Use by default -> updates auth for future default-home launches
Open account  -> launches using that account's explicit CODEX_HOME
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
- Merge chat libraries and make the merged history discoverable from both account homes.
- Switch the account used by future default-home Codex sessions.
- Provide a usable path to launch an account-specific Codex session.
- Back up, verify, report conflicts, and recover failed mutations.
- Show missing CLI, missing credentials, permission errors, and unsupported data formats.

### Outside v1

- Windows, Linux, mobile, and a browser frontend.
- Claude, Gemini, API routing, provider conversion, or automatic failover.
- A proxy server, background daemon, quota polling, pricing, or a usage dashboard.
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
macOS remains the only platform. Intel support needs a verified build before it is claimed.

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
Do not add provider interfaces, factories, dependency injection frameworks, or a generic migration engine.
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
    auth.json                     account credential
    config.toml -> shared root
    AGENTS.md, rules, skills ... -> shared root
    sessions/ -> shared root      merged user history
    archived_sessions/ -> shared root
    state_*.sqlite                independent indexes of shared history
  backups/<operation-id>/          data needed for rollback
  transactions/<operation-id>.json non-secret recovery journal
  staging/<operation-id>/          unpublished destination

~/.codex/                         default Codex home
  config.toml, rules, skills ...   default shared settings root
  auth.json                       credential for default launches
  sessions/, archived_sessions/   shared transcript library
  state_*.sqlite                  default-home indexes
```

The user can select a different shared root during setup.
Resolve it once and retain the actual URL. Never derive storage names from email strings.
Store credentials in Codex-compatible files with mode `0600`, inside private directories with mode `0700`.
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
After success, show **Use by default** and **Open with this account**.
The import result includes the destination, backup location, and any unresolved items.

### Settings policy

Accounts use one shared settings root unless the user explicitly chooses independent settings in a future scope change.
Full import cannot silently replace the settings used by every existing account.

Compare source settings with the shared root before committing:

- Same bytes: retain the shared file and create the account link.
- Source-only skill or rule: preview an addition to the shared root.
- Conflicting file: show Keep shared or Replace with imported for that file.
- Complex TOML difference: preserve the original and choose the whole file in v1.
- Mixed choices: resolve all required choices before starting the mutation.

Do not invent a partial TOML parser or perform text replacement across unknown config syntax.
If structured editing becomes required, choose a maintained parser based on concrete needs.
Preserve comments and unknown fields when passing through a selected file.

Show that applying imported shared settings affects every linked account.
Redact secret-looking values in previews, including MCP headers and environment values.
Treat hooks, skills, and MCP commands as executable configuration.
Preserving them does not authorize running them during import verification.

Validate links at launch and when the app returns to the foreground.
Some external editors replace a link with a regular file during an atomic save.
Report that divergence and offer a backed-up repair. Do not discard the diverged file.

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

Publish the staged account home before adding its visible registry record.
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
Shared live SQLite files remain outside v1. Keep local indexes and verify Codex can repair discovery from the shared transcripts.
Auth-only import links the existing shared library without importing that source's conversations.
Full import adds the selected source history to that library after duplicate and conflict handling.
Default-home switching then preserves the same chat library for both accounts.
Verify both an existing merged chat and a newly added chat can be discovered from either home.

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

Account-home and default-home credentials can diverge after token refresh.
Track which location was last used and preserve refreshed credentials before switching away.
When two copies diverge without a reliable order, report a conflict or require a fresh Codex sign-in.
Do not overwrite a refreshed credential with an older imported snapshot.

Never implement switching through `codex logout`.
Logout can remove credentials and does not implement a safe local account selection.
If the default auth file is a symlink, inspect its target and avoid writing through it into another account.
Back up and normalize only through a reviewed operation with a clear ownership rule.

### Open with this account

Launch Codex with the selected home through a structured process environment.
This gives the user a working alternative while the default home is busy.
Use the native terminal or a small saved launch artifact, without building a terminal emulator.
The user starts the session deliberately. Do not type into an unrelated live terminal.

Expose **Copy profile path** for hosts such as Super that accept `CODEX_HOME`.
Super's profile selection can reuse the same home without copying its credentials again.
Do not edit another app's live database or claim that its running sessions have changed accounts.

### Verify and sign in

Use the installed Codex command surface rather than implementing OAuth.
Force file-based auth for a deliberate managed-home verification when supported.
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
Integrate a custom draggable titlebar into the panes with macOS window controls. Use
consistent three-point corner radii on custom controls and surfaces, visible restrained
hover feedback, and native translucency with a readable reduced-transparency fallback.
Keep essential actions close to the selected account; shared paths belong in account
details rather than permanent window chrome.

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
- [x] Update app identity and repository URLs to AI Manager and this repository.

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

### G3. Auth-only import and account-specific launch

- [x] Implement private staging, account publication, and registry recovery.
- [x] Link approved shared settings without replacing their content.
- [x] Preserve the original source and verify permissions.
- [x] Handle duplicate-account auth updates without losing refreshed credentials.
- [x] Launch or provide a working native launch path for the imported home.
- [x] Show honest local verification and sign-in states.

Done when the native flow imports a fixture and launches Codex against exactly that destination.
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
- [x] Share merged transcripts across account homes while keeping SQLite files independent.
- [x] Verify both homes discover imported chats and later additions through Codex's resume behavior.
- [x] Rebase recognized copied index paths without rewriting historical content.
- [x] Show all excluded or unsupported categories in the result.
- [x] Verify a supported imported conversation can resume through Codex.

Done when the full import flow preserves selected durable data and passes the migration acceptance matrix.
Saving files without a working discovery and resume path is not sufficient.

### G6. Recovery, accessibility, and installed app

- [x] Exercise rollback and restart recovery from interrupted operations.
- [ ] Verify the redesigned native flow with keyboard navigation and accessibility labels.
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
| CLI verification | Correct explicit home, bounded timeout, no hidden model request |
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

- [OpenAI config and state locations](https://learn.chatgpt.com/docs/config-file/config-advanced): `CODEX_HOME` groups config and local state.
- [OpenAI authentication](https://learn.chatgpt.com/docs/auth): file-based auth, credential storage choices, and token refresh behavior.
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

Remote native CI was dispatched as run `34588863904`, but repository Actions are
disabled (`enabled: false`) and no job started. Repository permissions were not changed.
Local native tests and packaging remain the executed verification evidence.

### Next action

The CLI and history checks pass. Complete and install the revised compact translucent UI.
Live VoiceOver verification is no longer a gate. The core migration and history
evidence is recorded above; do not mark the full G1–G6 goal complete before the remaining gates pass.
Keep the user's prepared homes unchanged; validation uses only the protected test copy.
