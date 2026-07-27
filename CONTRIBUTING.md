# Contributing

Keep the domain boundaries and the local security model. Keep deterministic behavior and protocol compatibility.

## Before you change code

1. Read [Architecture](docs/ARCHITECTURE.md).
2. Read [Development workflow](docs/DEVELOPMENT.md).
3. Read the applicable architecture decisions.
4. Add a failing test at the lowest applicable layer.
5. Keep provider wire code in `src/providers` or protocol modules.
6. Do not put provider wire code in routing policy.
7. Do not send credentials to the renderer.

## Development gate

```bash
npm ci
npm run check
npm run build
npm run dist:dir
```

Use test-driven development:

- Add one failing contract.
- Make the smallest complete change.
- Test failure paths and branch paths.
- Update public text when behavior changes.
- Run the complete gate before publication.

## Architecture rules

- `src/domain` must not import outer layers.
- `src/application` must not import infrastructure or desktop code.
- Provider adapters translate one upstream protocol.
- Infrastructure owns storage, local HTTP, vaults, and logs.
- The renderer uses only the preload bridge.
- Secret changes must have clear commit and rollback order.

## Provider adapters

Read [Provider development](docs/PROVIDER_DEVELOPMENT.md). A new adapter must have:

- A stable provider type
- JSON behavior
- Streaming behavior
- Cancellation and timeout support
- Usage normalization
- Tool tests when tools are supported
- Image tests when images are supported
- Authentication and option documentation

## Pull requests

Keep each commit focused. Explain these items:

- User-visible behavior
- Domain or compatibility rule
- Tests
- Security effects
- Documentation changes

Do not commit credentials, local databases, release output, package caches, or editor state.
