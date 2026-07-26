# Development workflow

## Prerequisites

- Node.js 22+
- npm 10.9+
- Git
- Platform build tools for native Electron dependencies

## Install

```bash
npm ci
```

The lockfile is authoritative. Do not replace exact package versions with ranges without reviewing compatibility and regenerating the lockfile.

## Run

```bash
npm run dev
```

Vite serves the renderer on loopback and Electron loads it after the server becomes ready. Production Electron loads `dist/renderer/index.html` from the packaged application.

## Test-driven development

Tests are grouped by responsibility:

```text
tests/domain          Pure invariants, protocol conversion, routing, pricing
tests/application     Use-case orchestration and transaction behavior
tests/providers       Upstream adapter wire behavior
tests/infrastructure  Persistence, vault, HTTP helpers, logging
tests/repository      Public tree, architecture, workflows, documentation, interface contracts
```

Run all contracts:

```bash
npm test
npm run test:coverage
```

The coverage command applies thresholds to domain and application logic rather than inflating results with generated UI or framework composition.

## Quality gates

```bash
npm run verify
npm run check:links
npm run build:renderer
npm run build:site
npm run dist:dir
```

`npm run build` combines repository verification, coverage, source links, renderer build, and site build.

## Domain changes

1. Write a pure failing contract.
2. Add or change a domain invariant or value transformation.
3. Integrate it in an application service.
4. Add infrastructure or provider behavior only at outer layers.
5. Update documentation and architecture decisions when the contract changes materially.

## Desktop and website changes

The renderer must remain process-agnostic. Add privileged behavior as a narrowly named preload capability and validated main-process handler. Never expose a generic IPC send/invoke function.

Presentation changes must follow [Interface design system](DESIGN_SYSTEM.md):

1. Add or change a repository contract for the intended spacing, typography, responsive, accessibility, or factual-content behavior.
2. Use the existing IBM Plex, color, spacing, and breakpoint tokens before adding values.
3. Build both the renderer and generated site.
4. Inspect the renderer at wide, medium, and narrow sizes and the site at desktop, tablet, and mobile sizes.
5. Check horizontal overflow, keyboard focus, wrapped actions, table scrolling, and navigation state.

Do not add fabricated product metrics, mock usage values, unsupported provider claims, external font/CDN imports, or decorative content that can be mistaken for application behavior.

## Data migrations

SQLite migrations must be additive and safe on an existing local database. Configuration normalization should supply defaults for omitted fields and reject unsupported schema versions.
