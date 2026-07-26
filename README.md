<p align="center">
  <img src="website/assets/icon.svg" width="112" height="112" alt="Subscription Proxy Inator calendar and refresh icon">
</p>

# Subscription Proxy Inator

[![Desktop CI](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/desktop-ci.yml/badge.svg?branch=master)](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/desktop-ci.yml)
[![CodeQL](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/codeql.yml/badge.svg?branch=master)](https://github.com/surajmandalcell/subscription-proxy-inator/actions/workflows/codeql.yml)
[![Documentation](https://img.shields.io/badge/docs-online-0f62fe)](https://surajmandalcell.github.io/subscription-proxy-inator/)
[![Version 2.1.0](https://img.shields.io/badge/version-2.1.0-0f62fe)](CHANGELOG.md)
[![MIT License](https://img.shields.io/badge/license-MIT-525252)](LICENSE)

A cross-platform desktop gateway that exposes local OpenAI- and Anthropic-compatible routes while routing requests across configured OpenAI, Anthropic, Google Gemini, xAI Grok, compatible HTTP, command-line, and trusted module providers.

The application is designed for one local user. Provider credentials are encrypted in the desktop main process, the HTTP server binds to loopback, and routing uses configured account health, limits, model eligibility, pricing, and load-balancing policy.

**[Documentation](https://surajmandalcell.github.io/subscription-proxy-inator/)** · **[Quick start](docs/QUICK_START.md)** · **[Architecture](docs/ARCHITECTURE.md)** · **[Design system](docs/DESIGN_SYSTEM.md)** · **[Security](SECURITY.md)** · **[Changelog](CHANGELOG.md)**

## Implemented capabilities

- Multiple accounts per provider with independent priority, weight, enabled state, runtime health, cooldown, and local request/token/cost limits.
- Provider adapters for OpenAI, Anthropic, Gemini, Grok, OpenAI-compatible HTTP, Anthropic-compatible HTTP, JSON-lines commands, and trusted local modules.
- Priority, round robin, weighted random, least in-flight, lowest recent latency, lowest estimated cost, and sticky-session routing.
- One global routing strategy, optional provider overrides, and one action that removes every override.
- Failover for eligible rate-limit, overload, timeout, and network failures before client-visible streaming output begins.
- OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, model discovery, token estimation, and health endpoints.
- Native Gemini `generateContent`, streaming, function calling, thought signatures, and Deep Research polling.
- Request and route-attempt accounting for input, output, cache read, cache write, latency, first-token latency, status, and estimated or reported cost.
- Editable model aliases and source-linked pricing rules.
- One sandboxed React renderer shared by macOS, Windows, and Linux.

## Interface

Version 2.1 uses IBM Plex typography, a Carbon-like 4 px token scale with an 8 px major layout rhythm, square information surfaces, explicit boundaries, and consistently sized controls. The desktop renderer and website share the same hierarchy and responsive rules; the system is inspired by IBM's public 2x Grid and Carbon guidance and is not affiliated with or endorsed by IBM.

The desktop renderer is tested at compact, medium, and wide window sizes. At narrower widths, the side navigation becomes an icon rail, multi-column editors collapse, tables retain horizontal scrolling, and action groups wrap with visible spacing instead of merging into one control. Purposeful opacity, color, and short spatial transitions are enabled by default, while application and operating-system reduced-motion preferences remove them.

## Quick start from source

Requirements:

- Node.js 22 or newer
- npm 10.9 or newer
- Native build tools supported by Electron and `better-sqlite3`

```bash
git clone https://github.com/surajmandalcell/subscription-proxy-inator.git
cd subscription-proxy-inator
npm ci
npm run check
npm run dev
```

The local gateway starts at `http://127.0.0.1:8081` by default.

1. Open **Providers** and add a provider adapter.
2. Add one or more accounts. Credentials are encrypted when saved.
3. Open **Routing** and select the global strategy or provider overrides.
4. Configure aliases and verified rates under **Models & pricing** when needed.
5. Point an OpenAI- or Anthropic-compatible client at the local endpoint.

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

The local key is optional until enabled in **Settings**. It is not an upstream provider credential.

## Local endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Unauthenticated local health check |
| `GET` | `/v1/models` | Configured aliases and exact provider model IDs |
| `POST` | `/v1/chat/completions` | OpenAI Chat Completions JSON and SSE |
| `POST` | `/v1/responses` | OpenAI Responses JSON and SSE |
| `POST` | `/v1/messages` | Anthropic Messages JSON and SSE |
| `POST` | `/v1/messages/count_tokens` | Local input-token estimate |

See [API documentation](docs/API.md) for supported fields and compatibility boundaries.

## Architecture

```text
src/domain          Pure configuration, protocol, routing, and usage rules
src/application     Use cases and orchestration services
src/providers       Upstream protocol adapters
src/infrastructure  Persistence, encrypted vault, HTTP server, and logging
desktop/main        Electron composition root and validated IPC handlers
desktop/preload     Finite context-isolated renderer bridge
desktop/renderer    Shared responsive desktop interface
website             Source for the public product and documentation site
```

The domain layer has no Electron, database, network, provider, or renderer dependencies. Application services depend on ports supplied at bootstrap. Infrastructure and presentation remain outside the domain.

## Development and quality gates

```bash
npm test                 # all Node test contracts
npm run test:coverage    # coverage-gated domain/application suite
npm run verify           # repository, DDD, security, JSX, and workflow checks
npm run check:links      # source documentation links
npm run build:renderer   # production React renderer
npm run build:site       # public website and generated documentation
npm run dist:dir         # unpacked Electron application
npm run build            # complete validation and both web builds
```

The contracts cover routing strategies, cooldowns, account limits, protocol conversion, provider adapters, Deep Research polling, streaming boundaries, cancellation, encrypted persistence, usage filters, cost rules, configuration transactions, repository architecture, and the interface design system.

## Documentation

- [Quick start](docs/QUICK_START.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Design system](docs/DESIGN_SYSTEM.md)
- [Configuration reference](docs/CONFIGURATION.md)
- [Providers](docs/PROVIDERS.md)
- [Routing and failover](docs/ROUTING.md)
- [Usage and pricing](docs/USAGE.md)
- [Security model](docs/SECURITY.md)
- [Version 1 migration](docs/MIGRATION_V1.md)
- [Contributing](CONTRIBUTING.md)

## Security and responsible use

Use only accounts and API access you are authorized to use. The project does not acquire credentials, scrape browser sessions, resell subscriptions, or claim to bypass provider limits. Account switching is a local reliability and policy mechanism; it does not make prohibited use permissible.

The server is loopback-only, browser origins are exact allow-list entries, secrets are excluded from renderer snapshots, and logs redact credential-shaped fields. Read [SECURITY.md](SECURITY.md) before connecting local automation.

## License

MIT. See [LICENSE](LICENSE).
