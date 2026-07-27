# Architecture

## Purpose

The architecture keeps business rules separate from Electron, HTTP, databases, provider protocols, and presentation.

This separation supports multiple accounts, deterministic routing, protocol conversion, local usage records, and safe configuration.

## Layers

```text
Presentation       Electron shell, React renderer, website, generated docs
Infrastructure     Fastify, SQLite, vault, configuration files, logs
Provider adapters  OpenAI, Anthropic, Gemini, Grok, command, modules
Application        Proxy, routing, usage, settings, mutations
Domain             Configuration rules, protocols, routing, pricing
```

## Domain

`src/domain` contains pure rules:

- Configuration normalization and validation
- Canonical requests, responses, content, tools, and stream events
- Protocol conversion
- Account eligibility and local limits
- Route ordering and sticky sessions
- Error classes and cooldown values
- Price selection and cost calculation
- Usage filters, summaries, and CSV fields

The domain does not import an outer layer.

## Application

`src/application` contains use cases:

- `RoutingService` runs a route plan.
- `ProxyService` converts protocols and records usage.
- `UsageService` selects prices and uses storage ports.
- `SettingsService` changes configuration and server state.
- `ProviderConfigurationService` changes providers, accounts, and secrets.
- `RuntimeState` tracks load, latency, failures, cooldown, and attention state.

## Providers

Each adapter receives a canonical request and an execution context.

```js
{
  type: 'provider-type',
  execute(request, context) => canonicalResponse,
  stream(request, context) => AsyncIterable<canonicalEvent>
}
```

An adapter does not select an account. It does not control failover.

An adapter converts one provider protocol. It also passes cancellation, timeout, status, and usage data.

## Infrastructure

Infrastructure supplies these functions:

- Atomic JSON configuration storage
- Encrypted secret storage
- SQLite request and attempt storage
- Loopback Fastify server
- Structured logs with redaction

## Presentation

The Electron main process connects all services. The preload bridge gives the renderer a fixed set of actions.

The renderer does not receive credentials, secret references, Node.js APIs, or raw IPC.

The website uses Markdown files in `docs/`. It does not use desktop state or desktop permissions.

## Request flow

1. The server authenticates the local request.
2. The server identifies the client protocol.
3. `ProxyService` creates a canonical request.
4. `UsageService` estimates route costs when necessary.
5. `RoutingEngine` filters and orders routes.
6. `RoutingService` calls one adapter.
7. The service records each attempt.
8. The service can try another route before visible output.
9. The service converts the result to the client protocol.
10. The service stores request and attempt data.

## Stored data

| Path | Function |
| --- | --- |
| `config.json` | Store non-secret configuration |
| `secrets.json` | Store encrypted credentials |
| `secret.key` | Store the fallback encryption key |
| `usage.sqlite` | Store requests and route attempts |
| `providers/` | Store trusted provider modules |

## Failure model

The router identifies rate limits, quota limits, authentication errors, overloads, timeouts, network errors, client cancellation, and request errors.

Client cancellation does not penalize an account.

Read [Routing](ROUTING.md), [Security](SECURITY.md), and [ADR 0002](adr/0002-streaming-failover.md).
