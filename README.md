# IIA Directeur

IIA Directeur is a native macOS app for managing Codex accounts. It imports
Codex homes, keeps credentials separate, shares approved settings, preserves
chat history, and opens Codex with a selected account.

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

- `/private/tmp/ai-manager-build/package/IIA Directeur.app`
- `/private/tmp/ai-manager-build/artifacts/ai-manager`

Run the built products directly when needed:

```bash
open "/private/tmp/ai-manager-build/package/IIA Directeur.app"
"/private/tmp/ai-manager-build/artifacts/ai-manager" help
```

The package does not need Node.js, Electron, a local HTTP server, or provider
configuration.

## Try the sample accounts

```bash
AI_MANAGER_GUI_PREVIEW=1 scripts/build-gui-acceptance.sh
open "/private/tmp/ai-manager-build/gui-acceptance/IIA Directeur Preview.app"
```

The Preview app starts with sample accounts. Use Import Account
to explore source selection, both import modes, conflict review, and results.
The demo includes shared settings, chats, activity, errors, and recovery states.
All changes stay in memory and reset on the next launch. No sample credentials
or Codex homes are created. The preview additionally records nonfatal native
window checks under `/private/tmp/ai-manager-build/gui-acceptance/artifacts`.

## Safety boundaries

Use temporary homes and synthetic credentials for automated tests. For
real-format checks, use a protected copy of `~/.codex` outside this repository.
Never mutate the original home, follow copied links back to it, or commit
authentication files, transcripts, settings, or backups.

IIA Directeur does not access the login Keychain. It does not execute imported
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
