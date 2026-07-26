# Changelog

All notable changes to Subscription Proxy Inator are documented here.

## Unreleased

### Interface completion

- Reworked the website hero so the first viewport states the product outcome, supported provider families, local request path, pre-stream failover boundary, and local usage accounting.
- Separated Quick start and Download actions with responsive spacing, consistent sizing, and visible keyboard focus.
- Replaced every active product mark with one canonical rounded calendar-and-refresh SVG used by the website, renderer, manifest, README, social preview, and all Electron packaging targets.
- Added deterministic Apple touch, 192 px, and 512 px PNG fallbacks from the same canonical SVG for package and web-install compatibility.
- Added purposeful website reveal, hover, navigation, page, notice, and loading transitions with operating-system and in-app reduced-motion fallbacks.
- Completed mobile menu focus handling, Escape behavior, accessible copy feedback, action wrapping, and narrow-screen alignment contracts.
- Added repository tests for hero clarity, icon consistency, motion behavior, reduced-motion parity, and stale raster-icon removal.

## 2.1.0 - 2026-07-26

### Interface system

- Rebuilt the desktop renderer around IBM Plex typography, an 8 px spacing grid, square information surfaces, explicit borders, and Carbon-inspired interaction sizing.
- Reorganized navigation, page headers, metrics, provider editors, routing controls, usage filters, settings, and logs around consistent 40 px controls and readable table rows.
- Added responsive layouts for wide, medium, compact, and narrow windows without shrinking primary text or removing configuration capabilities.
- Added a documented interface contract and repository tests for typography, spacing, breakpoints, responsive structure, and prohibited decorative regressions.

### Website

- Replaced the promotional mock dashboard with a factual product site containing only implemented provider, routing, API, metering, security, build, and release information.
- Removed fabricated traffic, cost, success-rate, and latency values from the product presentation.
- Rebuilt the public site and generated documentation with the same IBM Plex and grid-based system.
- Self-hosted IBM Plex Sans and IBM Plex Mono from pinned Fontsource packages.

### Engineering

- Removed the unused Darwin UI and Inter dependencies.
- Added cross-platform path and interface contracts to the existing TDD suite.
- Kept all provider, routing, compatibility, storage, security, and metering behavior unchanged.

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

- Added a frameless titlebar, compact navigation, theme selection, density controls, and reduced-motion support.
- Added detailed provider, account, routing, model-alias, pricing, usage, logs, local API, and application settings screens.
- Added a public product site and generated documentation website.

### Engineering

- Added test-driven contracts across domain, application, provider, infrastructure, repository, and security behavior.
- Added cross-platform CI and Electron packaging, CodeQL, Dependabot, documentation hosting, and tagged release workflows.
- Replaced stale package metadata, screenshots, workflows, and documentation from version 1.

## 1.x

Version 1 was a local Node.js proxy and browser dashboard focused on a narrower single-account workflow. Version 2 supersedes that architecture. See [Version 1 migration](docs/MIGRATION_V1.md).
