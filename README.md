# AI Manager

AI Manager is a native macOS app for managing Codex accounts. It imports
Codex homes, keeps credentials separate, shares approved settings, preserves
chat history, and opens Codex with a selected account.

Development status: native targets, synthetic contracts, and protected-copy
preservation checks pass. The custom borderless GUI passes isolated auth-only
and full import, switching, local fake verification, and keyboard-focus checks.
Protected-copy history discovery and resume checks pass; unsupported database-only
histories remain in backup and are reported as unresolved. The signed installed app
launches successfully. The compact translucent two-pane UI passes layout and keyboard
checks; hover handlers are source-audited, with pointer-hover automation unavailable.
See [goals.md](goals.md) for recorded limits.

The repository contains one Swift package with three products:

| Product | Path | Purpose |
| --- | --- | --- |
| `AIManagerCore` | `packages/core` | Shared contracts and account operations |
| `AIManager` | `packages/gui` | Native SwiftUI account window |
| `ai-manager` | `packages/tui` | CLI and interactive terminal interface |

The GUI and CLI call the same core operations. The core test target covers
their shared contracts.

## Requirements

- macOS 14 or later
- Xcode with the Swift toolchain
- Codex is optional for discovery and offline tests

The first verified build target is Apple Silicon. Intel support needs a
separate verified build before it is claimed.

## Build and test

Run these commands from the repository root:

```bash
scripts/check-native.sh
scripts/build-native.sh
```

The build uses `/private/tmp/ai-manager-build` as its canonical cache. Set
`AI_MANAGER_BUILD_PATH` to another private path when the host requires it. The
script produces:

- `/private/tmp/ai-manager-build/package/AI Manager.app`
- `/private/tmp/ai-manager-build/artifacts/ai-manager`

Run the built products directly when needed:

```bash
open "/private/tmp/ai-manager-build/package/AI Manager.app"
"/private/tmp/ai-manager-build/artifacts/ai-manager" help
```

The package does not need Node.js, Electron, a local HTTP server, or provider
configuration.

## Safety boundaries

Use temporary homes and synthetic credentials for automated tests. For
real-format checks, use a protected copy of `~/.codex` outside this repository.
Never mutate the original home, follow copied links back to it, or commit
authentication files, transcripts, settings, or backups.

AI Manager does not access the login Keychain. It does not execute imported
hooks, commands, or plugins during discovery or import. It does not send a
model request during offline verification.

Import is a reviewed transaction. The app inspects a source, creates a
backup, stages changes, validates the staged result, publishes the account,
and verifies the result. A failed operation keeps the prior usable state and
shows a recovery action.

Existing Codex processes keep their current credentials. **Use by default**
changes future launches that use the default home. **Open with this account**
launches Codex with an explicit `CODEX_HOME`.

## Native package

The app bundle uses `packaging/macos/Info.plist` and an empty entitlements
file. It does not request Full Disk Access, Accessibility, Automation, or
network access. User-selected paths use native macOS file APIs.

Local builds use an ad hoc signature. To sign with a maintainer-provided
identity, set `AI_MANAGER_SIGNING_IDENTITY` for the build command. The app
records its source revision and dirty-source state in
`AIManagerSourceRevision` and `AIManagerSourceDirty`.

See [macOS package notes](packaging/macos/README.md) for the file-access
boundary. See [goals.md](goals.md) for the product scope and acceptance
matrix. See [ADR 0003](docs/adr/0003-credential-transactions.md) for the
credential transaction order retained from the gateway implementation.
