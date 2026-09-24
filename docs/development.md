# Building Switch

Switch is a native Swift package. The Mac app requires macOS 14 or later and
Xcode. Apple Silicon is the verified GUI target; an Intel GUI build still needs
verification. The core library and CLI also run on Linux.

## Build and check

From the repository root:

```bash
scripts/check-native.sh
scripts/build-native.sh
scripts/check-release-readiness.sh
```

The build writes `Switch.app` to
`/private/tmp/ai-manager-build/package/Switch.app` and the CLI to
`/private/tmp/ai-manager-build/artifacts/ai-manager`. Set
`AI_MANAGER_BUILD_PATH` to use another private cache location. To run them:

```bash
open "/private/tmp/ai-manager-build/package/Switch.app"
"/private/tmp/ai-manager-build/artifacts/ai-manager" help
```

The app embeds that CLI at `Contents/Helpers/ai-manager`. Provider Open actions
use the helper so account activation and process launch share one lock.

Run the terminal interface from the repository root with `make tui`. The npm
package is assembled and checked locally with:

```bash
npm test
npm pack
```

`npm pack` builds the release CLI into the package; packed installs do not
need Swift or Xcode.

On Linux, `scripts/check-linux.sh` checks the core, CLI, and isolated
acceptance flow. The Swift package needs no Node.js, Electron, local server, or
provider configuration. Codex CLI and Grok Build are optional for discovery and
offline tests. Install the provider CLI for its live sign-in and launch flow;
Codex CLI is also required for live usage checks.

## Preview with sample accounts

```bash
scripts/launch-switch.sh --preview
```

This builds an uninstalled Preview app under
`/private/tmp/ai-manager-build/preview`. Its accounts, usage, chats, and
recovery states are synthetic and reset on launch. Add Account and Advanced
Import can be explored without saving credentials or changing a provider home.
The production build excludes Preview data, and release readiness checks for
that boundary.

## Credentials and shared data

Switch saves owner-private, regular credential files under
`~/.switch/codex/<account-uuid>.json` and
`~/.switch/grok-build/<account-uuid>.json`. Account identifiers are UUIDs, not
email addresses. `~/.codex` and `~/.grok` remain the live provider homes.

**Set as Default** atomically replaces only `~/.codex/auth.json` after
identity and digest checks. Config, instructions, skills, plugins,
conversations, and databases remain in place. Existing Codex processes keep
their cached credentials. New sessions use the selected account. **Open Codex**
activates its account before launching the shared home.

For Grok Build, **Set as Default** atomically replaces only
`~/.grok/auth.json` with a validated OAuth subscription session. It does not
store or convert `XAI_API_KEY`. The official CLI reloads the auth file before
its next API call. **Open Grok Build** activates the account and launches the
official `grok` executable with `GROK_HOME=~/.grok`.

Switch reviews imports, creates a backup, stages and validates changes, then
publishes the account. A failed operation keeps the prior usable state and
shows recovery. It does not execute imported hooks, commands, or plugins
during discovery or import. Offline checks do not send a model request.

Use temporary homes and synthetic credentials for automated tests. For
real-format checks, use a protected copy of `~/.codex` outside this repository.
Never mutate the original home, follow copied links back to it, or commit
auth, transcripts, private settings, or backups. Switch does not inspect the
login Keychain.

## Packaging and release

The app uses `packaging/macos/Info.plist` and empty entitlements. It requests
no Full Disk Access, Accessibility, or Automation permission. User-selected
paths use native macOS file APIs.

Local builds use an ad hoc signature. Maintainers can set
`AI_MANAGER_SIGNING_IDENTITY` to use an existing signing identity. The app
records its Git revision and dirty-source state in `AIManagerSourceRevision`
and `AIManagerSourceDirty`.

`scripts/check-release-readiness.sh` checks local package readiness.

The first Switch version must be newer than the repository's legacy
`v2.1.2` tag. To publish an ad hoc signed release from a clean, pushed commit:

```bash
scripts/release-macos.sh --adhoc v3.2.1
```

The script marks the release as Latest and uploads its ZIP and checksum. It uses
no Apple signing identity or notarization key.

For a trusted download, run the release on a Mac with a **Developer ID Application**
identity and an App Store Connect notary API key. Keep the `.p8` file outside
this repository. Set `AI_MANAGER_SIGNING_IDENTITY`,
`AI_MANAGER_NOTARY_KEY_PATH`, and `AI_MANAGER_NOTARY_KEY_ID` in your shell. Set
`AI_MANAGER_NOTARY_ISSUER_ID` for a team API key; omit it for an individual key.
Then commit and push the source and run a notarized version, for example:

```bash
scripts/release-macos.sh --notarized v3.0.1
```

For this trusted path, the script checks the clean, pushed commit, runs native
and CLI checks, builds the versioned app, notarizes and staples it, and checks
Gatekeeper. It writes
`release/Switch-v3.0.1-mac-arm64.zip` and `release/checksums-v3.0.1.txt`,
checks the archived app, then creates the tag and uploads both files to a
GitHub Release from this Mac. It downloads the uploaded ZIP and compares it
with the local file before publishing the draft. The tag-triggered release
workflow has been removed; native CI remains for source checks. If the upload
fails, keep the files in `release/` and resume from the created tag after
checking the draft release.

## Sources of truth

| Product | Path | Role |
| --- | --- | --- |
| `AIManagerCore` | `packages/core` | Account, usage, history, and Cleanup operations |
| `AIManager` | `packages/mac-gui` | Native Mac app |
| `ai-manager` | `packages/tui` | CLI and terminal interface |

The app and CLI share the core account manager. The earlier Electron gateway
is legacy and is not needed to build or run Switch. See the
[product specification](specs/product.md), local ignored goal ledgers,
[macOS packaging notes](../packaging/macos/README.md), and
[credential transaction decision](adr/0003-credential-transactions.md).
