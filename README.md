# Switch

Switch is a native macOS app for managing Codex accounts. It saves each
account credential under `~/.switch/codex`, keeps one live `~/.codex` home for
configuration and chat history, and switches credentials for new Codex sessions.

Codex CLI is the only enabled provider. Claude Code, Gemini CLI, and
Antigravity CLI appear as WIP choices; their icons do not imply support.

The app and CLI use the same production account manager. The optional preview
build uses in-memory sample data and is never installed over the production app.

## Accounts

Switch saves the current Codex login automatically when first opened.

1. Choose Add Account and Codex CLI to start browser sign-in.
2. Finish signing in, then return to Switch and choose Check Now.
3. Use Set as Default to select credentials for new sessions.
4. Use Open Codex or Use & Open Codex to launch with the selected account.

Sign-in uses a private temporary home, keeping the current account, settings,
and chats unchanged. Pending sign-ins survive app restarts.

Advanced Import accepts an existing Codex folder or `auth.json`. Choose
account access only, or include settings and chats. Review conflicts before
importing; shared settings and chats do not belong to individual accounts.

Check account files validates the saved credential and checks usage when
possible. Refresh usage also works for newly imported accounts without
making them the default. These checks use the saved JSON in a disposable
private home. Usage checks need Codex CLI and access to its service.

Drag accounts in the sidebar to save their order. Account menus also offer
Move up, Move down, and Delete. Deleting the default account requires an
eligible saved replacement; the confirmation identifies it.

## Menubar

Enable Show in Menubar on an account to display its limits. Settings sets
the default for accounts without an explicit choice. The status item groups
up to four enabled accounts by service, with one glyph and their remaining
quota percentages in saved account order. Unknown limits show a dash.

The popover lists all accounts for switching. Enabled accounts show available
Session and Weekly limits as used percentages with reset times. Its footer
has refresh, the last refresh time, and Open App. Cards expand to fit until
the popover reaches 80% of its display's visible height, then scroll.

The popover uses Ivory in light mode and Espresso in dark mode, with one
native backdrop blur. Reduce Transparency gives it opaque surfaces.

## Chat history and activity

Chat History reads shared active and archived Codex conversations. Messages
load in chronological pages as you scroll, without a permanent cutoff.
Search and the Prompts, Responses, Tools, and Other filters cover the complete
conversation. Filter choices persist across app restarts. Copy shown copies
the loaded filtered messages in order, including original large-message text.
The header shows message counts and reliable recorded token totals when available.

Daily activity starts with a one-year calendar and remembers the selected range.
Choose 7 days, 1 month, or 1 year, then select a day for token and project details.
Switch retains compact daily summaries in its private application-support
`activity/daily.sqlite` database. Removing old conversations or rebuilding
search and quota caches preserves recorded totals.

Account totals come from Codex responses. Project totals come from local
cumulative token events and remain separate from account totals. Incomplete
or reset records retain known values with an incomplete indication. Switch
cannot reconstruct unseen or deleted records that it never indexed.

## Cleanup

Cleanup has disclosure trees for shared active and archived conversations
grouped by project, account usage samples, and the shared conversation index.
Select recent, older-than, all-time, or custom date ranges. Conversation dates
mean last updated; selecting one removes the whole conversation. The shared
index has no record dates and can only be selected with All time.

Review the exact selected paths, cache records, counts, and payload bytes
before confirming. Payload sizes exclude database overhead.

- Conversations move to private recoverable trash. Moving them does not free disk space.
- Restore returns trashed conversations without overwriting existing files.
- Permanent removal needs a separate confirmation. Interrupted moves recover after restart.
- Usage samples and the search index are rebuildable caches; clearing them keeps daily summaries.

Cleanup protects auth, settings, account records, backups, Codex databases,
and the activity ledger. Hard-linked or foreign-owned files appear as protected
entries. Changed files and active or unknown writers block removal.

## Platform support

- The native Mac GUI supports macOS 14 or later.
- `AIManagerCore` and the `ai-manager` terminal interface support macOS and Linux.
- Building requires a compatible Swift toolchain; the Mac GUI build uses Xcode.
- Codex is optional for discovery and offline tests.

Install Codex CLI to sign in, query usage, or launch Codex from Switch.

The first verified Mac GUI target is Apple Silicon. Intel support needs a
separate verified build. The Mac GUI does not run on Linux.

## Build and test

Run these commands from the repository root:

```bash
scripts/check-native.sh
scripts/build-native.sh
scripts/check-release-readiness.sh
```

On Linux, `scripts/check-linux.sh` validates the core library, terminal build,
CLI acceptance flow, and isolated runtime smoke test. CI runs it in the
repository's validation container.

The build uses `/private/tmp/ai-manager-build` as its canonical cache. Set
`AI_MANAGER_BUILD_PATH` to another private path when the host requires it. The
script produces:

- `/private/tmp/ai-manager-build/package/Switch.app`
- `/private/tmp/ai-manager-build/artifacts/ai-manager`

The app embeds that exact CLI as `Contents/Helpers/ai-manager`. **Open Codex**
delegates to the helper so account activation and process start share the same
cross-process lock instead of capturing an earlier credential state.

Run the built products directly when needed:

```bash
open "/private/tmp/ai-manager-build/package/Switch.app"
"/private/tmp/ai-manager-build/artifacts/ai-manager" help
```

The package does not need Node.js, Electron, a local HTTP server, or provider
configuration.

## Try the sample accounts

```bash
scripts/launch-switch.sh --preview
```

This builds an uninstalled `Switch.app` under
`/private/tmp/ai-manager-build/preview` with the `AI_MANAGER_PREVIEW` compiler
condition, then opens it. Use Add Account to explore sign-in, or Advanced Import
to review an existing folder, import scope, conflicts, and results.
The demo includes shared settings, chats, activity, errors, and recovery states.
All changes stay in memory and reset on the next launch. No credentials,
Codex homes, or backups are created. The production target never defines that
compiler condition, and release readiness rejects Preview-only data in its
executable.

## Safety boundaries

Use temporary homes and synthetic credentials for automated tests. For
real-format checks, use a protected copy of `~/.codex` outside this repository.
Never mutate the original home, follow copied links back to it, or commit
authentication files, transcripts, settings, or backups.

Switch does not access the login Keychain. It does not execute imported
hooks, commands, or plugins during discovery or import. It does not send a
model request during offline verification.

Import is a reviewed transaction. The app inspects a source, creates a
backup, stages changes, validates the staged result, publishes the account,
and verifies the result. A failed operation keeps the prior usable state and
shows a recovery action.

Existing Codex processes keep their cached credentials. **Set as Default**
atomically replaces the regular `~/.codex/auth.json` file while
leaving the rest of `~/.codex` unchanged. **Open Codex** performs that activation
when needed and launches the same live home. Saved credentials are regular
private files, never symbolic or hard links.

Click a displayed path to copy it. Settings controls body translucency,
initially 25%, from 0% to 50%. Text and controls stay opaque.

## Native package

The app bundle uses `packaging/macos/Info.plist` and an empty entitlements
file. It does not request Full Disk Access, Accessibility, or Automation
permissions. User-selected paths use native macOS file APIs.

Local builds use an ad hoc signature. To sign with a maintainer-provided
identity, set `AI_MANAGER_SIGNING_IDENTITY` for the build command. The app
records its source revision and dirty-source state in
`AIManagerSourceRevision` and `AIManagerSourceDirty`.

`scripts/check-release-readiness.sh` reports local package readiness only; it
does not approve public distribution. Public direct distribution remains
blocked until the tag workflow signs with a Developer ID Application identity,
notarizes and staples the app, passes the public readiness and Gatekeeper checks,
and creates the GitHub release.

## Repository

The repository contains one Swift package with three products:

| Product | Path | Purpose |
| --- | --- | --- |
| `AIManagerCore` | `packages/core` | Shared account, usage, history, and Cleanup operations |
| `AIManager` | `packages/mac-gui` | Native Mac GUI |
| `ai-manager` | `packages/tui` | CLI and interactive terminal interface |

The app and CLI share account operations. Preview uses synthetic data without
filesystem or account side effects. The earlier Electron gateway is legacy
and is not required to build or run Switch.

See the [product specification](docs/specs/product.md) for current behavior
and [goals.md](goals.md) for milestones and verification. The
[macOS package notes](packaging/macos/README.md) describe packaging and permissions.
[ADR 0003](docs/adr/0003-credential-transactions.md) describes the credential transaction order.
