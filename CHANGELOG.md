# Changelog

This file lists important changes to Subscription Proxy Inator.

## Unreleased

### Public interface

- Reduced the hero diagram to two visible connector lines.
- Removed extra diagram borders from the hero.
- Kept one headline, one sentence, and two actions in the hero copy.
- Removed the request-boundary sequence diagram from the README.
- Kept the system, architecture, and security diagrams in the README.
- Added an explicit release-status table to the README.

### Documentation

- Added a fixed navigation-row contract to generated documentation.
- Kept active and inactive sidebar labels at the same font weight.
- Reserved scrollbar space to prevent horizontal page movement.
- Loaded documentation layout rules before first paint.
- Used the canonical product icon in generated documentation.
- Documented whole-source coverage and automatic branch cleanup.

### Testing

- Expanded coverage from two layers to every file in `src`.
- Set minimum coverage to 99 percent lines, 96 percent functions, and 90 percent branches.
- Added application, bootstrap, domain, provider, HTTP, SQLite, vault, and logger completion tests.
- Reached 99.62 percent lines, 96.66 percent functions, and 90.31 percent branches in the local completion run.
- Fixed SSE cancellation to use a mutable coded `AbortError`.

### Technical writing

- Expanded the ASD-STE100 project gate to all repository Markdown.
- Added desktop renderer strings, website SVG text, and issue forms to the gate.
- Changed prohibited-phrase checks to use word boundaries.
- Kept sentence, contraction, semicolon, and controlled-phrase checks active.
- Standardized the Proxy-Inator product term in the desktop interface.

### Automation

- Limited Desktop CI to pushes on `master`.
- Limited CodeQL to pushes on `master`.
- Limited the responsive UI audit to pushes on `master`.
- Kept the release workflow tag-only.
- Added a post-package job that deletes every non-default branch.
- Added repository checks for workflow triggers, branch cleanup, coverage, and stable documentation geometry.
- Removed the temporary coverage-audit workflow and ignored transient audit and test files.

## 2.1.2 - 2026-07-28

### Documentation cleanup

- Removed two obsolete documentation pages.
- Kept the automated ASD-STE100 gate active.
- Reduced the hero to one headline, one sentence, two actions, and the routing diagram.

### Technical writing

- Rewrote the website, README, and documentation with the project ASD-STE100 profile.
- Added controlled terms and sentence rules to the writing checker.
- Added an automated check for sentence length, contractions, semicolons, and prohibited phrases.
- Added the writing check to the standard project gate.

### Interface completion

- Replaced the text panel in the hero with an accessible system diagram.
- The diagram shows Claude, Codex, and Z.ai as example sources.
- The diagram shows Proxy-Inator as the local gateway.
- The diagram shows Harness, Automation, and App as example clients.
- Balanced the wide website sections with equal columns.
- Changed the product mark to a white calendar and refresh glyph on blue.
- Generated all website and package icons from one SVG source.
- Added short interface transitions and reduced-motion rules.
- Improved mobile focus, action wrapping, and diagram stacking.
- Added repository tests for the interface rules.

## 2.1.1 - 2026-07-27

### Documentation

- Rewrites public project text with the ASD-STE100 Issue 9 project profile.
- Adds an automated check for sentence length, contractions, semicolons, and prohibited phrases.
- Adds the controlled technical-term list and writing maintenance rules.
- Fixes HTML text extraction for encoded entities and raw-text elements.

### Validation

- Passes 195 tests, coverage limits, documentation links, CodeQL, and the responsive browser audit.
- Passes unpacked Electron package builds on Linux, macOS, and Windows.

## 2.1.0 - 2026-07-26

### Interface system

- Changed the desktop renderer to IBM Plex typefaces.
- Added a fixed spacing system and clear borders.
- Set a minimum height of 40 px for primary desktop controls.
- Added responsive layouts for wide and narrow windows.
- Added repository tests for type, spacing, breakpoints, and factual content.

### Website

- Replaced the old mock dashboard with a factual product website.
- Removed false traffic, cost, success-rate, and latency values.
- Used the same type and grid system for the website and generated docs.
- Added local IBM Plex font files from pinned packages.

### Engineering

- Removed unused Darwin UI and Inter packages.
- Added cross-platform path and interface tests.
- Kept provider, routing, storage, security, and usage behavior unchanged.

## 2.0.0 - 2026-07-26

### Architecture

- Replaced the version 1 browser dashboard with an Electron desktop app.
- Added separate domain, application, provider, infrastructure, and presentation layers.
- Added one sandboxed React renderer for Windows, macOS, and Linux.

### Providers and accounts

- Added OpenAI, Anthropic, Gemini, and Grok adapters.
- Added compatible HTTP, command, and trusted module adapters.
- Added multiple encrypted accounts for each provider.
- Added account priority, weight, health, cooldown, and local limits.
- Added transaction rules for configuration and secret changes.
- Added Gemini tools, images, thought signatures, streams, and Deep Research polling.
- Added Grok session headers, service tiers, and reported cost data.

### Routing

- Added seven routing strategies.
- Added one global strategy and optional provider overrides.
- Added model globs, aliases, attempt limits, cooldowns, and local account limits.
- Added provider and account failover before visible output.
- Stopped route changes after visible output.
- Added cancellation, timeout classes, heartbeats, backpressure, and stream errors.

### Local API

- Added Chat Completions, Responses, Messages, token estimates, models, and health routes.
- Added JSON and SSE conversion for text, images, tools, usage, and stop reasons.
- Added optional local bearer authentication and exact-origin CORS.

### Usage

- Added SQLite request and route-attempt records.
- Added token, cache, cost, latency, status, and error data.
- Added status, provider, account, protocol, and date filters.
- Added stable CSV export and price rules.

### Desktop and website

- Added the custom titlebar, navigation, themes, density, and reduced motion.
- Added provider, routing, price, usage, log, API, and settings pages.
- Added a public website and generated documentation.

### Engineering

- Added tests for all architecture layers.
- Added CI, package builds, CodeQL, Dependabot, Pages, and release workflows.
- Removed version 1 metadata, workflows, and images.

## 1.x

Version 1 used a local Node.js proxy and a browser dashboard. Version 2 replaces that design.
