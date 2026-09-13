# Switch

Switch is a native macOS app for managing Codex accounts. It saves each
account credential under `~/.switch/codex`, keeps one live `~/.codex` home for
configuration and chat history, and activates an account before opening Codex.

The normal app and CLI use the same production account manager. The separately
named Preview app uses in-memory sample data for design review.

The repository contains one Swift package with three products:

| Product | Path | Purpose |
| --- | --- | --- |
| `AIManagerCore` | `packages/core` | Shared contracts and account operations |
| `AIManager` | `packages/gui` | Native SwiftUI account window |
| `ai-manager` | `packages/tui` | CLI and interactive terminal interface |

The CLI and normal GUI use the core operations. Preview uses matching synthetic
contracts without filesystem or account side effects.

## Platform support

- The native GUI supports macOS 14 or later.
- `AIManagerCore` and the `ai-manager` terminal interface support macOS and Linux.
- Building requires a compatible Swift toolchain; the macOS GUI build uses Xcode.
- Codex is optional for discovery and offline tests.

The first verified GUI target is Apple Silicon. Intel GUI support needs a
separate verified build. The native GUI does not run on Linux.

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
condition, then opens it. Use Import Account
to explore source selection, both import modes, conflict review, and results.
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

Existing Codex processes keep their cached credentials. **Use for new Codex
sessions** atomically replaces the regular `~/.codex/auth.json` file while
leaving the rest of `~/.codex` unchanged. **Open Codex** performs that activation
when needed and launches the same live home. Saved credentials are regular
private files, never symbolic or hard links.

## Native package

The app bundle uses `packaging/macos/Info.plist` and an empty entitlements
file. It does not request Full Disk Access, Accessibility, Automation, or
network access. User-selected paths use native macOS file APIs.

Local builds use an ad hoc signature. To sign with a maintainer-provided
identity, set `AI_MANAGER_SIGNING_IDENTITY` for the build command. The app
records its source revision and dirty-source state in
`AIManagerSourceRevision` and `AIManagerSourceDirty`.

`scripts/check-release-readiness.sh` reports local package readiness only; it
does not approve public distribution. Public direct distribution remains
blocked until the tag workflow signs with a Developer ID Application identity,
notarizes and staples the app, passes the public readiness and Gatekeeper checks,
and creates the GitHub release.

See [macOS package notes](packaging/macos/README.md) for the file-access
boundary. See [goals.md](goals.md) for the product scope and acceptance
matrix. See [ADR 0003](docs/adr/0003-credential-transactions.md) for the
credential transaction order retained from the gateway implementation.
