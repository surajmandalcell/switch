# Subscription Proxy Inator

A cross-platform desktop gateway that presents one local OpenAI- and Anthropic-compatible API while routing requests across your own OpenAI, Anthropic, Google Gemini, xAI Grok, compatible HTTP, command-line, and trusted module providers.

The application is designed for one local user. Credentials stay encrypted on the machine, the proxy binds to loopback, and routing decisions are made from explicit account health, local budgets, provider eligibility, pricing, and configured load-balancing policy.

## Highlights

- **Multiple accounts per provider** with independent priority, weight, health, cooldown, enablement, and local request/token/cost limits.
- **Modular provider architecture** for OpenAI, Anthropic, Gemini, Grok, compatible APIs, JSON-lines commands, and trusted local modules.
- **Safe failover** across accounts and providers for rate limits, overloads, timeouts, and network failures. A streaming request never switches after client-visible text or a tool call.
- **Seven routing strategies:** priority, round robin, weighted random, least in-flight, lowest latency, lowest estimated cost, and sticky sessions.
- **Global and per-provider routing policy** with a single action that clears every override and applies the global strategy.
- **OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages compatibility**, including streaming, images, tools, tool results, usage, and stop reasons.
- **Native Gemini support**, including `generateContent`, SSE streaming, function calling, thought-signature preservation, and long-running Deep Research interactions.
- **Detailed local usage accounting** for input, output, cache read, cache write, cost, total latency, first-token latency, request status, and every upstream route attempt.
- **Editable source-linked pricing catalog** used by cost estimates and lowest-cost routing.
- **One sandboxed React renderer on macOS, Windows, and Linux**, with a custom titlebar, compact translucent sidebar, Darwin UI components, and platform compositor backdrops.

## Status

Version 2.0 is a complete architectural replacement for version 1. The source tree, desktop application, compatibility server, documentation website, tests, packaging workflows, and migration guidance live together in this repository.

Unsigned development packages are produced by CI for all three desktop platforms. Tagged releases build installable artifacts. Production signing and notarization require maintainer-owned certificates and secrets.

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

The desktop app starts the local gateway at `http://127.0.0.1:8081` by default.

1. Open **Providers** and add a provider preset.
2. Add one or more accounts. Credentials are encrypted immediately.
3. Open **Routing** and select a global strategy or provider override.
4. Optionally configure aliases and verified rates under **Models & pricing**.
5. Point an OpenAI- or Anthropic-compatible client at the local endpoint.

OpenAI-style environment:

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8081/v1
export OPENAI_API_KEY=local-proxy-key
```

Anthropic-style environment:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8081
export ANTHROPIC_API_KEY=local-proxy-key
```

The local key is optional until enabled in **Settings**. It is never the upstream provider credential.

## Compatibility endpoints

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

The source follows domain-driven boundaries:

```text
src/domain          Pure configuration, protocol, routing, and usage rules
src/application     Use cases and orchestration services
src/providers       Upstream protocol adapters
src/infrastructure  Persistence, encrypted vault, HTTP server, and logging
desktop/main        Electron composition root and validated IPC handlers
desktop/preload     Finite context-isolated renderer bridge
desktop/renderer    Shared React desktop interface
```

The domain layer has no Electron, database, network, or provider dependencies. Application services depend on ports supplied at bootstrap. Infrastructure and presentation stay outside the domain.

Read [Architecture](docs/ARCHITECTURE.md) and the [architecture decisions](docs/adr/0001-domain-boundaries.md).

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

The test suite exercises routing strategies, cooldowns, account limits, protocol conversion, provider adapters, Deep Research polling, stream boundaries, cancellation, backpressure helpers, encrypted persistence, usage filters, cost rules, config transactions, and repository architecture.

## Documentation

Start with the [documentation index](docs/INDEX.md):

- [Quick start](docs/QUICK_START.md)
- [Configuration reference](docs/CONFIGURATION.md)
- [Providers](docs/PROVIDERS.md)
- [Routing and failover](docs/ROUTING.md)
- [Usage and pricing](docs/USAGE.md)
- [Security model](docs/SECURITY.md)
- [Version 1 migration](docs/MIGRATION_V1.md)
- [Contributing](CONTRIBUTING.md)

## Security and responsible use

Use only accounts and API access you are authorized to use. The project does not acquire credentials, scrape browser sessions, resell subscriptions, or claim to bypass provider limits. Account switching is a reliability and policy mechanism for the local user’s configured accounts; it does not make prohibited use permissible.

The server is loopback-only, browser origins are exact allow-list entries, secrets are excluded from renderer snapshots, and logs redact credential-shaped fields. Read [SECURITY.md](SECURITY.md) before exposing any local automation to the gateway.

## License

MIT. See [LICENSE](LICENSE).
