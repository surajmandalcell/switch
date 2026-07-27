# Security policy

## Supported version

Security fixes apply to the current 2.x release.

## Report a vulnerability

Do not open a public issue for a vulnerability. Do not include credentials or sensitive logs in a public message.

Use GitHub private vulnerability reporting. Include these items:

- Affected version
- Operating system
- Reproduction steps
- Security effect
- Proposed correction, if available

## Trust boundary

Subscription Proxy Inator is a local, single-user desktop application.

Default controls:

- The HTTP server accepts only `127.0.0.1` or `localhost`.
- Remote provider URLs must use HTTPS.
- Loopback endpoints can use HTTP.
- CORS uses exact origins.
- Provider credentials stay outside `config.json`.
- The renderer uses a sandbox and context isolation.
- The renderer has no Node.js integration.
- The preload bridge exposes a small set of actions.
- Renderer snapshots do not contain secret references.
- Logs remove credential fields and bearer values.
- Local bearer authentication protects all routes except `/health`.

These controls cannot protect a compromised operating system account.

## Credential storage

The application uses Electron `safeStorage` when it is available.

The fallback uses AES-256-GCM. It stores a mode-0600 local key when the platform supports file permissions.

The fallback protects backups from accidental disclosure. It is not a hardware security module.

Credential replacement uses this order:

1. Create a new encrypted secret.
2. Commit the configuration.
3. Remove the old secret.

A failed configuration commit removes the new secret. A removal commits the configuration change before it removes the old secret.

## Provider and module risks

- A command provider receives `SPI_ACCOUNT_SECRET`.
- A command provider starts an explicit program without a shell.
- Configure only programs that you trust.
- External modules run with main-process permissions.
- Treat an external module as installed code.
- Custom headers cannot use credential-like names.
- Store credentials in account storage.
- Use only services that you have permission to use.

Read [Security model](docs/SECURITY.md) for more information.
