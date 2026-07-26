# Changelog

All notable changes to Subscription Proxy Inator are documented here.

## 2.0.0 - 2026-07-26

### Rebuilt

- Replaced the version 1 browser dashboard and single-provider assumptions with a cross-platform Electron desktop application.
- Introduced explicit domain, application, provider, infrastructure, and presentation boundaries.
- Added a single sandboxed React renderer shared by macOS, Windows, and Linux.

### Providers and accounts

- Added native OpenAI, Anthropic, Google Gemini, and xAI Grok adapters.
- Added generic OpenAI-compatible, Anthropic-compatible, command/CLI, and trusted external-module adapters.
- Added any number of encrypted accounts per provider with enablement, priority, weight, metadata, health, cooldown, and local budgets.
- Added atomic account/configuration mutations so failed config writes cannot orphan newly encrypted credentials or erase existing references.
- Added native Gemini function calling, image content, thought-signature preservation, SSE, and Deep Research Interactions API polling.
- Added Grok sticky-conversation headers, configurable service tiers, and upstream-reported cost normalization.

### Routing and reliability

- Added priority, round robin, weighted random, least in-flight, lowest latency, lowest cost, and sticky strategies.
- Added a global strategy, per-provider overrides, and one-click override replacement.
- Added model eligibility globs, provider-specific aliases, per-provider attempt caps, exponential cooldowns, `Retry-After`, attention state, and local account limits.
- Added account and provider failover before client-visible output.
- Prohibited route switching after text or tool activity reaches the client.
- Added client cancellation, timeout classification, streaming heartbeats, backpressure handling, and protocol-native stream errors.

### Compatibility API

- Added OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, token estimation, model discovery, and health endpoints.
- Added JSON and SSE translation for text, images, tools, tool results, usage, cache tokens, and stop reasons.
- Added optional encrypted local bearer authentication and exact-origin CORS.

### Metering

- Added SQLite request and route-attempt ledgers.
- Added input, output, cache-read, cache-write, cost, total latency, and first-token latency tracking.
- Added composable status, provider, account, protocol, and date filters.
- Added stable filtered CSV export and source-linked pricing rules.

### Desktop and website

- Added a frameless titlebar, translucent compact sidebar, Darwin UI component styling, theme selection, density controls, and reduced-motion support.
- Added detailed provider, account, routing, model-alias, pricing, usage, logs, local API, and application settings screens.
- Added a public product site and generated documentation website deployed through GitHub Pages.

### Engineering

- Added test-driven contracts across domain, application, provider, infrastructure, repository, and security behavior.
- Added cross-platform CI and Electron packaging, CodeQL, Dependabot, Pages deployment, and tagged release workflows.
- Replaced stale package metadata, screenshots, workflows, and documentation from version 1.

## 1.x

Version 1 was a local Node.js proxy and browser dashboard focused on a narrower single-account workflow. Version 2 supersedes that architecture. See [Version 1 migration](docs/MIGRATION_V1.md).
