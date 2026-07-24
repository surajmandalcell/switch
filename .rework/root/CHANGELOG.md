# Changelog

All notable changes to Subscription Proxy Inator are documented here.

## 2.0.0 - 2026-07-24

### Rebuilt

- Replaced the single-account browser dashboard with a cross-platform Electron desktop application.
- Added a frameless custom titlebar, compact translucent sidebar, shared Inter typography, Darwin UI components, and one renderer across macOS, Windows, and Linux.
- Replaced provider-specific request handling with a canonical request/response and streaming event model.

### Providers and accounts

- Added modular native adapters for OpenAI, Anthropic, Google Gemini, and xAI Grok.
- Added OpenAI-compatible, Anthropic-compatible, command/CLI, Gemini CLI-style, and external `.mjs` provider support.
- Added multiple encrypted accounts per provider with priority, weight, enable state, health, cooldown, and four budget types.
- Added exact and glob model aliases plus provider model-eligibility globs.

### Routing

- Added priority, round robin, weighted random, least in-flight, lowest latency, lowest cost, and sticky strategies.
- Added global strategy plus per-provider overrides and a one-click action that clears every override.
- Added account/provider failover, `Retry-After`, exponential cooldowns, authentication attention state, and local limit exclusion.
- Added buffered stream selection and prohibited retries after client-visible output.

### Compatibility

- Added OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, token counting, model discovery, and health routes.
- Added JSON and SSE translation across provider protocols.
- Added text, image, function declaration, tool call, tool result, stop, usage, and cache normalization.

### Metering and security

- Added SQLite usage and route-attempt ledgers.
- Added reported-versus-estimated token tracking, input/output/cache separation, latency, first-token latency, and cost estimates.
- Added an editable, source-linked, verification-dated pricing catalog.
- Added Electron `safeStorage`, sandboxed renderer, narrow preload IPC, local binding, optional local API key, CORS control, and redacted logs.

### Tooling and documentation

- Added cross-platform electron-builder targets and GitHub Actions packaging matrix.
- Added architecture, configuration, provider, API, security, and contribution documentation.

## 1.2.3 and earlier

The original project was a local Node.js web proxy focused on one ChatGPT/Codex account and Anthropic-compatible requests. Version 2.0 supersedes that architecture.
