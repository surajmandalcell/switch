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

Installing the app does not update a separate CLI in your shell. After building, install the
matching command and its `switch` alias with:

```bash
bash scripts/install-cli.sh "${AI_MANAGER_BUILD_PATH:-/private/tmp/ai-manager-build}/artifacts/ai-manager"
"$HOME/.local/bin/ai-manager" --version
command -v ai-manager switch
```

The installer replaces `ai-manager` atomically in `~/.local/bin` and refuses to overwrite an
unrelated `switch` there. Put this directory before older command directories in `PATH`.
It never changes `/usr/local/bin/switch`. Pass a second argument to choose another bin directory.
On Linux, pass the executable produced by `swift build --configuration release --product ai-manager`.

Run the terminal interface from the repository root with `make tui`. The npm
package is assembled and checked locally with:

```bash
npm test
npm pack
```

`npm pack` builds the release CLI into the package; packed installs do not
need Swift or Xcode.
Keep the version in `package.json` and `packages/tui/Sources/AIManagerTUI/BuildInfo.swift` equal.
Package preparation and the installed-package check reject a version mismatch.
Complete the CLI publication and installation rule in `AGENTS.md` with each app update.

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
Pass `--background` to the app executable to start in the menu bar without opening the main window.

`scripts/check-release-readiness.sh` checks local package readiness.

The first Switch version must be newer than the repository's legacy
`v2.1.2` tag. To publish an ad hoc signed release from a clean, pushed commit:

```bash
scripts/release-macos.sh --adhoc v3.6.2
```

The script marks the release as Latest and uploads its ZIP and checksum. It uses
no Apple signing identity or notarization key.

For a trusted download, run the release on a Mac with a **Developer ID Application**
identity and an App Store Connect notary API key. Keep the `.p8` file outside
this repository. Set `AI_MANAGER_SIGNING_IDENTITY`,
`AI_MANAGER_NOTARY_KEY_PATH`, and `AI_MANAGER_NOTARY_KEY_ID` in your shell. Set
`AI_MANAGER_NOTARY_ISSUER_ID` for a team API key; omit it for an individual key.
Or save Apple ID credentials with `xcrun notarytool store-credentials <profile>`
and set `AI_MANAGER_NOTARY_PROFILE` to that profile name instead of the key settings.
Then commit and push the source and run a notarized version, for example:

```bash
scripts/release-macos.sh --notarized v3.0.1
```

`--xcode` signs and notarizes through the Apple ID signed in to Xcode, with no
local Developer ID certificate or notary key. Set `AI_MANAGER_SIGNING_IDENTITY`
to a development identity and set `AI_MANAGER_TEAM_ID`. Example:
`scripts/release-macos.sh --xcode v3.8.1`. A copy of the development-signed app
stays in `$AI_MANAGER_BUILD_PATH/local/Switch.app` for local install.

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

## Install script

`install.sh` downloads pinned release archives and checks their SHA-256 values.
macOS also checks the developer signature and notarization before installing
the app into `~/Applications`. Both systems install the CLI under
`${XDG_DATA_HOME:-~/.local/share}/switch/cli/<version>` and link commands in
`~/.local/bin`. Linux runtime libraries stay beside the executable.
The installer does not need sudo, change shell profiles, or touch account data.
Run `bash scripts/check-installer.sh` for isolated installation and failure checks.
It currently installs the public Mac app 3.8.2 and CLI 3.9.1. Publish both
`Switch-cli-v<version>-darwin-arm64.tar.gz` and
`Switch-cli-v<version>-linux-x86_64.tar.gz`, plus `checksums.txt`, under the
`cli-v<version>` release. Keep the app ZIP and its checksum under `v<version>`.
Update the script's pinned versions only after publishing matching assets.

## README cover

Compare cover options before exporting: `node packages/website/cover-lab.cjs --serve`.
It serves a local preview at `http://127.0.0.1:8847` for up to eight hours.
The generated HTML is self-contained; favorites, ratings, and notes stay in the browser.
Choose a design in the lab before replacing the public README cover.

The cover records the website's menu bar demo inside a light poster with its heading. On the
rendering host, run `node packages/website/export-cover.cjs --gif` from the
repository root to create the GIF and static reduced-motion fallback.
Only the area outside the cover's 6px corners is transparent. Its padding keeps the light background.
It uses the existing Playwright installation under `packages/mac-gui/ui-lint`;
set `PLAYWRIGHT_MODULE` or `CHROME_PATH` to use another installed renderer.
GIF export also needs FFmpeg and Gifsicle. Set `GIFSICLE_PATH` for a custom executable path.
Temporary recordings are removed after export. ImageMagick builds the social preview below.
Run `sh packages/website/build-assets.sh` to refresh the website assets,
including the social preview. Check the README in light and dark mode at
desktop and phone widths after replacing images.

## Sources of truth

| Product | Path | Role |
| --- | --- | --- |
| `AIManagerCore` | `packages/core` | Account, usage, history, and Cleanup operations |
| `AIManager` | `packages/mac-gui` | Native Mac app |
| `ai-manager` | `packages/tui` | CLI and terminal interface |

The app and CLI share the core account manager. The earlier Electron gateway
is legacy and is not needed to build or run Switch. See the
[product specification](../specs/product.md), local ignored goal ledgers,
[macOS packaging notes](../packaging/macos/README.md), and
[credential transaction decision](adr/0003-credential-transactions.md).
