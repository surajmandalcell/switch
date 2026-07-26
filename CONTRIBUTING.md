# Contributing

Contributions should preserve the application’s domain boundaries, local security model, deterministic behavior, and protocol compatibility.

## Before changing code

1. Read [Architecture](docs/ARCHITECTURE.md), [Development](docs/DEVELOPMENT.md), and the relevant architecture decisions.
2. Reproduce the behavior with a test at the lowest responsible layer.
3. Keep provider-specific wire behavior in `src/providers` or protocol conversion modules, not in routing policy.
4. Never expose credentials or internal secret references to the renderer.

## Workflow

```bash
npm ci
npm run check
npm run build
npm run dist:dir
```

Use test-driven development:

- Add a failing contract.
- Implement the smallest coherent domain or application change.
- Add branch and failure-path coverage.
- Update public documentation and the website when behavior changes.
- Run the complete quality gate before publishing.

## Architecture rules

- `src/domain` must remain pure and cannot import application, infrastructure, provider, Electron, or UI code.
- `src/application` coordinates ports and domain policy; it cannot import infrastructure or desktop code.
- Provider adapters translate canonical requests and events to one upstream protocol.
- Infrastructure owns persistence, local HTTP, vaults, and logs.
- The renderer uses only the finite preload bridge.
- Config and secret mutations must have explicit commit and rollback ordering.

## Provider adapters

See [Provider development](docs/PROVIDER_DEVELOPMENT.md). New adapters need:

- A stable provider type.
- JSON and streaming behavior.
- Cancellation and timeout propagation.
- Usage normalization.
- Tool and image tests where supported.
- Documentation for authentication and adapter options.

## Pull requests

Keep commits focused and explain:

- The user-visible behavior.
- The domain invariant or compatibility contract.
- Tests added.
- Security implications.
- Documentation updated.

Do not commit credentials, local databases, generated release files, package caches, or editor state.
