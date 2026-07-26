# Documentation

Subscription Proxy Inator is a local desktop gateway with explicit domains for configuration, routing, protocol translation, provider integration, credential storage, and metering.

## Start here

- [Quick start](QUICK_START.md) — install, add providers, and connect a client.
- [Configuration](CONFIGURATION.md) — every persisted setting and editor field.
- [Providers](PROVIDERS.md) — OpenAI, Anthropic, Gemini, Grok, compatible endpoints, commands, and modules.
- [API](API.md) — local compatibility endpoints and supported request/stream behavior.
- [Routing](ROUTING.md) — eligibility, strategies, limits, cooldowns, and failover boundaries.
- [Usage](USAGE.md) — request records, route attempts, filters, pricing, and CSV export.
- [Security](SECURITY.md) — trust boundaries, credential lifecycle, IPC, and local HTTP policy.

## Maintainers and contributors

- [Architecture](ARCHITECTURE.md)
- [Provider development](PROVIDER_DEVELOPMENT.md)
- [Development workflow](DEVELOPMENT.md)
- [Release process](RELEASE.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Version 1 migration](MIGRATION_V1.md)

## Architecture decisions

- [ADR 0001: Domain boundaries](adr/0001-domain-boundaries.md)
- [ADR 0002: Streaming failover boundary](adr/0002-streaming-failover.md)
- [ADR 0003: Credential/configuration transaction ordering](adr/0003-credential-transactions.md)
