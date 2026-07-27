# Security model

## Protected data

The application protects these assets:

- Provider credentials
- Optional local API key
- Configuration integrity
- Local usage data
- Electron main-process boundary

## Local HTTP boundary

The host must be `127.0.0.1` or `localhost`. The server checks the value again when it starts.

CORS accepts exact origin URLs. It rejects wildcards, malformed URLs, credentials, and origin paths.

A native local client can omit the browser `Origin` header.

The local API key protects all routes except `/health`. The comparison uses equal-length, timing-safe bytes.

## Renderer boundary

`BrowserWindow` uses these settings:

```text
contextIsolation: true
sandbox: true
nodeIntegration: false
webSecurity: true
```

The preload bridge exposes a fixed list of actions. IPC handlers check the sender URL.

The renderer cannot open an external page directly. The main process opens only HTTPS external URLs.

Public snapshots do not contain account secret references or the local API secret reference.

The renderer sees only `hasSecret` and `hasApiKey` states.

## Secret vault

The app uses platform `safeStorage` when it is available.

The fallback uses these controls:

- Random 256-bit key
- AES-256-GCM
- Random 96-bit initialization value for each secret
- Authentication tag for each encrypted value
- Mode-0600 key and vault files when supported
- Atomic temporary-file rename

The fallback key is in the application data directory. It does not protect data from the same operating-system user.

## Configuration and secret order

Configuration and secrets use separate files. Use this order:

- Add: Create a secret. Commit configuration. Remove the secret after a failed commit.
- Replace: Create a new secret. Commit configuration. Remove the old secret.
- Remove: Commit configuration removal. Remove the old secret.

An encrypted orphan is safer than a live reference to missing secret data.

## Provider input checks

- A remote base URL must use HTTPS.
- A URL cannot contain credentials.
- Custom credential-like headers are removed.
- An external module must be in the trusted provider directory.
- A command adapter starts a program with `shell: false`.

## Logs and usage

Structured logs remove credential-like keys and bearer strings. The app keeps a bounded number of log entries.

Usage data contains route and token measurements. It does not contain prompts or response bodies.

## Operation rules

- Enable a local API key when local software is not trusted.
- Do not expose the server through a tunnel or port forward.
- Review each command and external module.
- Keep the operating system and Electron current.
- Use only accounts and APIs that you have permission to use.
