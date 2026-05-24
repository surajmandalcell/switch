# Changelog

All notable changes to this package are documented in this file.

This project uses release entries grouped by package version, with the newest release first.

## [1.2.2] - 2026-05-24

### Fixed

- Made release verification run against an isolated temporary proxy config instead of the user's real local account and settings.
- Made `test:all` run unit tests and server-backed tests sequentially so mutable settings tests cannot race each other.
- Made `make update` restore its own version bump if verification fails before the release commit is created.

## [1.2.1] - 2026-05-24

### Fixed

- Made release metadata tests compare against the active package version so `make update` can bump patch, minor, major, or explicit versions without breaking on stale literals.
- Updated the release script to refresh the dashboard version along with package metadata, lockfile metadata, and the server banner.

## [1.2.0] - 2026-05-24

### Added

- Single-account local mode for the ChatGPT account manager, API surface, CLI, and dashboard.
- `codex-proxy account` CLI commands for configuring, showing, verifying, and removing the one local account.
- Singular account API routes under `/account`, including status, add, import, refresh, delete, quota, models, usage, and OAuth cleanup endpoints.
- Responsible use documentation for local single-user intent, credential boundaries, no resale, and no rate-limit bypass behavior.
- Regression tests for single-account storage, route registration, CLI command shape, release metadata, changelog packaging, and static removal audits.

### Changed

- Adding or importing an account now replaces the existing configured account instead of appending another account.
- `/v1/messages` now uses only the configured account credentials for OpenAI requests.
- The dashboard Account tab now shows one account card and one empty state instead of multi-account tables or switching controls.
- Package metadata, lockfile metadata, server banner, and dashboard version now report `1.2.0`.

### Removed

- Removed plural first-party account-management routes and per-email account operations.
- Removed legacy plural account CLI command handling, account listing, switching, refresh-all, and quota-all semantics.
- Removed legacy account fallback code, tests, settings, and related docs.

## [1.1.0] - 2026-05-24

### Changed

- Hardened release/update flow so update verification does not depend on stale local proxy instances.
- Restored npm package metadata to the `1.1.0` release line after local version experiments.

## [1.0.8] - 2026-05-23

### Added

- Added explicit update bump commands for release maintenance.
- Added compact dashboard account controls for narrow screens.

### Changed

- Refreshed README screenshots and dashboard presentation.
- Tightened small-screen action bars and bottom navigation styling.
- Removed legacy local artifacts from the tracked package surface.

## [1.0.7] - 2026-05-23

### Added

- Added token usage metrics and recent request dashboard panels.
- Added Claude model mapping and reasoning mapping controls.
- Added Claude Code configuration helpers in the dashboard.

### Changed

- Simplified dashboard header layout and local development entrypoints.
- Removed account strategy selection from settings.
