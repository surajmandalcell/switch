# Development workflow

## Requirements

- Node.js 22 or later
- npm 10.9 or later
- Git
- Platform build tools for Electron native dependencies

## Install dependencies

```bash
npm ci
```

The lockfile is authoritative. Review compatibility before you change an exact package version.

## Start development mode

```bash
npm run dev
```

Vite serves the renderer on loopback. Electron loads the renderer after Vite is ready.

A production package loads `dist/renderer/index.html`.

## Test-driven development

Tests use these groups:

```text
tests/domain          Domain rules and protocol conversion
tests/application     Use cases, composition, and transactions
tests/providers       Provider protocols, streams, and cancellation
tests/infrastructure  Storage, vault, HTTP, SQLite, and logs
tests/repository      Repository, architecture, docs, and interface rules
```

Run the tests:

```bash
npm test
npm run test:coverage
```

Coverage applies to every file in `src`.

The gate requires at least 99 percent line coverage. It requires 96 percent function coverage and 90 percent branch coverage.

Add tests for new branches before you change a threshold. Do not exclude a source layer to make the gate pass.

## Quality gates

```bash
npm run verify
npm run check:ste
npm run check:links
npm run build:renderer
npm run build:site
npm run dist:dir
```

`npm run build` runs all checks and both web builds.

## Branch lifecycle

Use `master` as the only persistent branch.

A temporary work branch can exist while a change is under review. Do not keep agent, automation, release, audit, or experiment branches after completion.

Desktop CI deletes every non-default branch after validation and all platform package builds pass.

Do not disable this cleanup job. Do not protect a temporary work branch.

## Change domain code

1. Add a failing domain test.
2. Change one domain rule or value conversion.
3. Connect the change to an application service.
4. Add outer-layer code only when necessary.
5. Update an architecture decision when the rule changes.
6. Update public documentation.

## Change the desktop app or website

The renderer must not use process APIs. Add a named preload action for privileged work.

Do not expose a general IPC function.

For a presentation change:

1. Add a repository contract.
2. Use the existing type, color, spacing, and breakpoint tokens.
3. Build the renderer and the website.
4. Inspect wide, medium, and narrow layouts.
5. Check keyboard focus and horizontal overflow.
6. Check wrapped actions and table scrolling.

Do not add false product data. Do not add unsupported provider claims.

Do not load fonts or scripts from an external CDN.

## Data migrations

SQLite migrations must be additive. A migration must be safe for an existing local database.

Configuration normalization must add defaults for missing fields. It must reject an unsupported schema version.
