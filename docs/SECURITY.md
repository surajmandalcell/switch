# Security model

## Assets

The application protects:

- Upstream provider credentials.
- The optional local API key.
- Non-secret routing and provider configuration integrity.
- Local usage records.
- The boundary between unprivileged renderer content and the Electron main process.

## Local HTTP boundary

The configured host must be `127.0.0.1` or `localhost`. The server repeats this check when listening, so an invalid persisted value cannot silently expose the proxy.

CORS origins are exact URLs. Wildcards, malformed URLs, credentials, and path-bearing origin values are rejected. Requests without a browser `Origin` header remain available to local native and CLI clients.

When enabled, the local API key protects every route except `/health`. Comparison uses equal-length timing-safe byte comparison.

## Renderer boundary

`BrowserWindow` uses:

```text
contextIsolation: true
sandbox: true
nodeIntegration: false
webSecurity: true
```

The preload bridge exposes a finite list of typed actions. IPC handlers validate the sender URL. External navigation is denied in the renderer and opened through the operating system only for HTTPS URLs.

Public snapshots remove account secret references and the local API secret reference. The renderer sees only `hasSecret` and `hasApiKey` booleans.

## Vault

Platform `safeStorage` is preferred. The fallback uses:

- Random 256-bit key.
- AES-256-GCM.
- Random 96-bit IV per secret.
- Authentication tag per ciphertext.
- Mode-0600 key and vault files where the platform supports permissions.
- Atomic temporary-file rename for vault persistence.

The fallback key resides beside application data. It protects against accidental plaintext disclosure, not an attacker who controls the same operating-system user.

## Configuration transactions

Credential creation and config persistence cannot be one filesystem transaction, so ordering is deliberate:

- Add: encrypt new secret → commit config → delete new secret on commit failure.
- Replace: encrypt under a new reference → commit config → delete old reference.
- Remove: commit config removal → delete old secret.

Removal prefers a harmless encrypted orphan over a live config reference to missing material.

## Provider input validation

- Remote base URLs require HTTPS.
- Embedded URL credentials are rejected.
- Custom credential-like headers are discarded.
- External modules are restricted to the trusted provider directory.
- Command adapters spawn an explicit executable with `shell: false`.

## Logging and usage

Structured logs recursively redact credential-shaped keys and bearer strings. Logs are bounded in memory. Usage storage contains routing metadata and token/cost measurements, not prompt or response bodies.

## Operational guidance

- Enable a local API key when other local software is not fully trusted.
- Do not bind through a port forward, reverse proxy, container publish rule, or public tunnel.
- Review command and external-module code before configuration.
- Keep the operating system and Electron runtime updated.
- Use only accounts and API access you are authorized to use.
