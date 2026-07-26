# Security policy

## Supported version

Security fixes target the current 2.x release line.

## Reporting a vulnerability

Do not open a public issue containing credentials, exploit details, or sensitive logs. Use GitHub private vulnerability reporting for this repository. Include affected version, platform, reproduction steps, impact, and any suggested mitigation.

## Trust boundary

Subscription Proxy Inator is a local single-user desktop application. Its default security properties are:

- The HTTP server accepts only `127.0.0.1` or `localhost` bindings.
- Remote provider base URLs require HTTPS; plain HTTP is accepted only for loopback endpoints.
- Browser CORS access uses exact origins and does not support wildcard entries.
- Provider credentials are encrypted outside `config.json`.
- The renderer is sandboxed, context-isolated, and has no Node integration.
- A finite preload API is the renderer’s only privileged capability.
- Secret references are removed from renderer snapshots.
- Credential-shaped fields and bearer strings are redacted from logs.
- Optional local bearer authentication protects every endpoint except `/health`.

These controls do not protect a machine already compromised at the operating-system or user-account level.

## Credential storage

Electron `safeStorage` is used when the platform encryption backend is available. Otherwise the application stores AES-256-GCM ciphertext and a mode-0600 local key in the application data directory. The fallback protects configuration backups and casual disclosure; it is not a hardware-backed vault.

Credential updates create a new encrypted reference, commit configuration, then remove the previous reference. Failed configuration commits remove the newly created secret. Deletion removes configuration first and vault material second, preferring an orphaned encrypted value over a dangling live reference.

## Provider and module risks

- Command providers receive the selected account secret through `SPI_ACCOUNT_SECRET` and execute without a shell. Configure only commands you trust.
- External modules load only from the application’s trusted provider directory, but execute with main-process privileges. Treat them as installed code, not sandboxed plugins.
- Custom provider headers reject names resembling authorization, API keys, cookies, and tokens. Credentials must use account storage.
- Only use upstream accounts and services you are authorized to access.

Read the detailed [security model](docs/SECURITY.md).
