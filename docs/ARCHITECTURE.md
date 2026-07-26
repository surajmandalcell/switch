# Architecture

## Goals

The architecture isolates business rules from Electron, HTTP frameworks, databases, and provider wire formats. It supports many accounts per provider, deterministic routing, protocol compatibility, and safe desktop configuration without coupling those concerns together.

## Layers

```text
┌──────────────────────────────────────────────────────────────┐
│ Desktop presentation                                         │
│ Electron main · finite preload bridge · React renderer       │
├──────────────────────────────────────────────────────────────┤
│ Infrastructure                                               │
│ Fastify · SQLite · encrypted vault · config files · logging  │
├──────────────────────────────────────────────────────────────┤
│ Provider adapters                                            │
│ OpenAI · Anthropic · Gemini · Grok · command · modules       │
├──────────────────────────────────────────────────────────────┤
│ Application services                                         │
│ Proxy · routing orchestration · usage · settings · mutations │
├──────────────────────────────────────────────────────────────┤
│ Domain                                                       │
│ Config invariants · canonical protocols · routing · pricing  │
└──────────────────────────────────────────────────────────────┘
```

### Domain

`src/domain` contains pure policy:

- Configuration normalization and validation.
- Canonical request, response, content, tool, and stream events.
- OpenAI, Anthropic, and Gemini protocol transformations.
- Account eligibility and local limit calculations.
- Strategy ordering and sticky-session state.
- Error classification and cooldown duration.
- Pricing specificity, cost calculation, filtering, summaries, and CSV shape.

It does not import application, provider, infrastructure, Electron, or renderer code.

### Application

`src/application` implements use cases against ports:

- `RoutingService` executes a route plan and owns failover boundaries.
- `ProxyService` translates client protocols, invokes routing, serializes output, and records usage.
- `UsageService` selects pricing and delegates storage.
- `SettingsService` coordinates configuration, local API credentials, server restarts, and login effects.
- `ProviderConfigurationService` coordinates provider/account configuration and encrypted secret lifecycle.
- `RuntimeState` tracks in-flight work, latency EWMA, failures, cooldown, and attention state.

### Providers

Each adapter accepts a canonical request and context. It provides:

```js
{
  type: 'provider-type',
  execute(request, context) => canonicalResponse,
  stream(request, context) => AsyncIterable<canonicalEvent>
}
```

Provider adapters do not select accounts or decide failover. They translate one upstream protocol and propagate cancellation, timeout, status, and usage.

### Infrastructure

Infrastructure implements persistence and process boundaries:

- Atomic JSON configuration store.
- Encrypted secret vault.
- SQLite request and route-attempt ledgers.
- Loopback Fastify compatibility server.
- Bounded structured logger with redaction.

### Desktop

The Electron main process is the composition root. The renderer receives public configuration and finite actions through a context-isolated preload bridge. The renderer never receives `secretRef`, `apiKeySecretRef`, provider credentials, Node APIs, or raw IPC.

## Request flow

1. The HTTP server authenticates the local request and selects a client protocol.
2. `ProxyService` converts the body to a canonical request.
3. `UsageService` estimates provider costs for lowest-cost routing.
4. `RoutingEngine` filters and orders eligible provider/account candidates.
5. `RoutingService` invokes an adapter and records attempt lifecycle events.
6. On retryable failure before visible streaming output, the next candidate is attempted.
7. The successful canonical response/events are serialized to the original client protocol.
8. Usage and route attempts are persisted independently.

## Persistence

Application data lives under Electron’s platform-specific user-data directory:

| File | Purpose |
| --- | --- |
| `config.json` | Non-secret schema-versioned configuration |
| `secrets.json` | Encrypted credential records |
| `secret.key` | AES fallback key when platform storage is unavailable |
| `usage.sqlite` | Request and route-attempt ledgers |
| `providers/` | Trusted external provider modules |

## Failure model

The router distinguishes rate limits, quota exhaustion, authentication failures, overloads, timeouts, network errors, client cancellation, and non-retryable request errors. Runtime state is updated per account. Client cancellation does not penalize an account.

See [Routing](ROUTING.md), [Security](SECURITY.md), and [ADR 0002](adr/0002-streaming-failover.md).
