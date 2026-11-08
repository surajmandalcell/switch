<p align="center">
  <picture>
    <source media="(prefers-reduced-motion: reduce)" srcset="docs/screenshots/cover-monument.png">
    <img src="docs/screenshots/cover-monument.gif" alt="Switch. Coding accounts and usage, right in your menu bar. A demo shows account switching." width="100%">
  </picture>
</p>

# Switch

Account switching and usage for AI coding tools. Native on macOS, with a terminal interface for macOS and Linux.

**[Download for Mac](https://github.com/surajmandalcell/switch/releases/latest)** · [Website](https://switch.mandalsuraj.com) · [Terminal](#use-switch-in-the-terminal) · [Build from source](docs/development.md#build-and-check)

## Get started

```sh
curl -fsSL https://raw.githubusercontent.com/surajmandalcell/switch/master/install.sh | sh
```

Installs the Mac app and CLI, or the Linux CLI. Run it again to update.

1. Open Switch, or run `~/.local/bin/switch` in a terminal.
2. Choose **Add Account** and follow the sign-in steps for your tool.
3. Check usage and choose the account you want to use.

<details>
<summary>Requirements and install locations</summary>

macOS 14+ on Apple Silicon; Linux x86_64 with glibc 2.38+. Install each coding tool separately.

The Mac app goes in `~/Applications`; terminal commands go in `~/.local/bin`. The installer needs no administrator access and keeps your account data in place.

</details>

## Usage at a glance

See account limits and reset times in the menu bar. The Overview page shows daily tokens, activity, account trends, and estimated API costs.

![Overview with daily tokens and an activity calendar](docs/screenshots/overview-dark.png)

| Account trends | Light appearance |
| :---: | :---: |
| ![Account trends and share of tokens](docs/screenshots/overview-insights.png) | ![Overview in light mode](docs/screenshots/overview-light.png) |

| Menu bar in dark mode | Menu bar in light mode |
| :---: | :---: |
| ![Account limits and reset times in dark mode](docs/screenshots/menubar-dark.png) | ![Account limits and reset times in light mode](docs/screenshots/menubar-light.png) |

Manage saved accounts by tool, check usage without switching, and set a default for each tool.

![Accounts grouped by tool with usage and default controls](docs/screenshots/accounts-dark.png)

<sub>App screenshots show real usage with email addresses hidden. Menu bar screenshots use Preview sample data.</sub>

## Accounts and access

Switch changes the selected tool's login while preserving its local settings and workspace data. It saves the outgoing login and backs up replaced data. Each tool has its own default account.

| Tool or provider | What selecting an account does |
| --- | --- |
| Codex CLI | Replaces its auth file. Running sessions may need to reopen to use the new account. |
| Grok Build | Replaces its auth file, which the CLI reloads before its next API call. |
| Claude Code | Uses a separate account profile with shared local conversations and settings. The default applies to launches through Switch; optional terminal integration also covers plain `claude` commands. |
| Droid / Factory | Replaces auth files and updates eligible local conversation headers for the selected organization. Original session IDs and message bodies remain intact. Active writers defer this step until a safe retry. |
| File-backed integrations, including Gemini CLI, Cursor, Kimi Code, and Kiro | Change only the selected tool's supported auth files or entries. Support differs by client; Cursor editor switching does not switch Cursor CLI. Quit the affected app before switching. |
| API-key and session providers | Save credentials and check usage. Selecting a default does not generally change a coding tool's login. |

Local history and cloud access are separate. Droid cloud missions stay with their owner. Codex account rules can restrict which conversations a different account can resume. Other tools can also require the original account for cloud history or attachments.

See [conversation continuity and tool limits](specs/conversation-continuity.md) for the detailed support table. The [website](https://switch.mandalsuraj.com) lists providers; the terminal's provider list reflects your installed version.

## Use Switch in the terminal

Run without a global install:

```bash
npx --yes @smdl/switch
```

Or install and update globally:

```bash
npm install --global @smdl/switch@latest
switch
```

The terminal uses the same account store and switching engine as the Mac app. Use arrow keys to move, Enter to select, and Escape to go back. `ai-manager` is also available as an alias.

```bash
switch --version
switch providers
switch usage --json
switch guard --provider codex --min-remaining 10
switch help
```

The npm package supports Apple Silicon Macs only. The shared core and CLI also run on Linux when [built from source](docs/development.md#build-and-check). Run `make tui` from a source checkout to start the terminal interface.

## History, backups, and privacy

Search local conversations and review token use by account, model, or project. Preview Cleanup changes before moving conversations and caches to recoverable trash. Back up chats and settings to a folder or drive, or export your prompts as Markdown.

Hide email addresses or use Privacy mode for stable account aliases. Switch does not read the macOS Keychain or browser cookie stores. Providers that need a browser session accept a pasted session instead.

## Documentation and credits

[Build and check](docs/development.md#build-and-check) · [Product specification](specs/product.md) · [Security policy](SECURITY.md) · [Release notes](docs/release-notes.md)

Usage integrations include work adapted from [OpenUsage](https://github.com/robinebers/openusage) and [CodexBar](https://github.com/steipete/CodexBar).

Switch is released under the [MIT license](LICENSE).
