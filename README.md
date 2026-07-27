<p align="center">
  <img src="website/assets/icon.svg" width="112" height="112" alt="Subscription Proxy Inator calendar and refresh icon">
</p>

# Subscription Proxy Inator

[![Desktop CI](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/desktop-ci.yml/badge.svg?branch=master)](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/desktop-ci.yml)
[![CodeQL](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/codeql.yml/badge.svg?branch=master)](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/codeql.yml)
[![Documentation](https://img.shields.io/badge/docs-online-0f62fe)](https://surajmandalcell.github.io/subscription-proxy-inator/)
[![Version 2.1.1](https://img.shields.io/badge/version-2.1.1-0f62fe)](CHANGELOG.md)
[![MIT License](https://img.shields.io/badge/license-MIT-525252)](LICENSE)

Subscription Proxy Inator is a desktop AI gateway. It gives local clients one OpenAI-compatible or Anthropic-compatible API.

The gateway connects to configured providers and accounts. It selects an eligible account for each request. It can try another route before output starts.

The application is for one local user. It encrypts provider credentials in the Electron main process. The HTTP server listens on loopback by default.

**[Documentation](https://surajmandalcell.github.io/subscription-proxy-inator/)** · **[Quick start](docs/QUICK_START.md)** · **[Architecture](docs/ARCHITECTURE.md)** · **[Writing standard](docs/WRITING_STANDARD.md)** · **[Security](SECURITY.md)**

## Main functions

- Add multiple accounts to each provider.
- Set priority, weight, health, cooldown, and local limits for each account.
- Use OpenAI, Anthropic, Gemini, Grok, compatible HTTP, command, or trusted module adapters.
- Select priority, round-robin, weighted-random, least-inflight, lowest-latency, lowest-cost, or sticky routing.
- Set one global routing strategy.
- Set an optional strategy for each provider.
- Try another eligible route after a temporary failure.
- Stop route changes after visible text or tool output starts.
- Serve Chat Completions, Responses, Messages, model, token-estimate, and health routes.
- Record request data and route-attempt data in SQLite.
- Edit model aliases and pricing rules.
- Use one sandboxed React renderer on Windows, macOS, and Linux.

## Interface

Version 2.1 uses IBM Plex typefaces and a fixed spacing system. The desktop app and website use the same information hierarchy.

The interface changes its layout at defined widths. It does not reduce important text to fit a small window. Tables can scroll when the available width is small.

The interface uses short transitions to show state changes. The Reduce motion setting removes nonessential motion.

The design takes guidance from IBM 2x Grid and Carbon. This project is not an IBM product.

## Install from source

Requirements:

- Node.js 22 or later
- npm 10.9 or later
- Build tools for Electron and `better-sqlite3`

```bash
git clone https://github.com/surajmandalcell/subscription-proxy-inator.git
cd subscription-proxy-inator
npm ci
npm run check
npm run dev
```

The default local address is `http://127.0.0.1:8081`.

## Configure the gateway

1. Open **Providers**.
2. Add a provider adapter.
3. Add one or more accounts.
4. Save the account credentials.
5. Open **Routing**.
6. Select a global strategy.
7. Add provider overrides when necessary.
8. Open **Models & pricing**.
9. Add aliases or verified prices when necessary.
10. Connect a compatible client.

The main process encrypts credentials when it saves them.

OpenAI-compatible environment:

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8081/v1
export OPENAI_API_KEY=local-proxy-key
```

Anthropic-compatible environment:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8081
export ANTHROPIC_API_KEY=local-proxy-key
```

The local key is optional until you enable it in **Settings**. It is not a provider credential.

## Local routes

| Method | Path | Function |
| --- | --- | --- |
| `GET` | `/health` | Show local process health |
| `GET` | `/v1/models` | List aliases and exact model IDs |
| `POST` | `/v1/chat/completions` | Serve OpenAI Chat Completions |
| `POST` | `/v1/responses` | Serve OpenAI Responses |
| `POST` | `/v1/messages` | Serve Anthropic Messages |
| `POST` | `/v1/messages/count_tokens` | Estimate local input tokens |

Read [Local compatibility API](docs/API.md) for field support and limits.

## Source structure

```text
src/domain          Configuration, protocol, routing, and usage rules
src/application     Use cases and coordination services
src/providers       Provider protocol adapters
src/infrastructure  Storage, vault, HTTP server, and logs
desktop/main        Electron composition and validated IPC handlers
desktop/preload     Context-isolated renderer bridge
desktop/renderer    Responsive desktop interface
website             Public website source
```

The domain layer has no Electron, database, network, provider, or renderer imports. Application services use ports that the bootstrap layer supplies.

## Quality gates

```bash
npm test                 # Run all Node.js tests
npm run test:coverage    # Run coverage gates
npm run verify           # Check the repository and architecture
npm run check:ste        # Check the project STE writing profile
npm run check:links      # Check source documentation links
npm run build:renderer   # Build the React renderer
npm run build:site       # Build the website and documentation
npm run dist:dir         # Build an unpacked desktop application
npm run build            # Run all checks and web builds
```

The tests cover routing, limits, protocols, adapters, streaming, cancellation, encrypted storage, usage, prices, and configuration transactions.

## Documentation

- [Documentation index](docs/INDEX.md)
- [Quick start](docs/QUICK_START.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Configuration](docs/CONFIGURATION.md)
- [Providers](docs/PROVIDERS.md)
- [Routing and failover](docs/ROUTING.md)
- [Usage and pricing](docs/USAGE.md)
- [Security model](docs/SECURITY.md)
- [Interface design system](docs/DESIGN_SYSTEM.md)
- [ASD-STE100 writing profile](docs/WRITING_STANDARD.md)
- [Version 1 migration](docs/MIGRATION_V1.md)
- [Contributing](CONTRIBUTING.md)

## Responsible use

Use only accounts and APIs that you have permission to use. The project does not get credentials or browser sessions.

The project does not resell subscriptions. It does not bypass provider limits. Local account switching does not change provider terms.

Read [Security policy](SECURITY.md) before you connect local automation.

## License

The project uses the MIT License. Read [LICENSE](LICENSE).
