# Version 1 migration

Version 2 is an architectural replacement, not an in-place extension of the previous runtime.

## What changed

| Version 1 concept | Version 2 replacement |
| --- | --- |
| Browser dashboard | Cross-platform Electron desktop application |
| Narrow account workflow | Multiple encrypted accounts per provider |
| Provider-specific request path | Canonical protocols and modular adapters |
| One routing behavior | Seven global/per-provider strategies |
| Basic request logs | Request and route-attempt SQLite ledgers |
| Limited endpoint compatibility | Chat Completions, Responses, and Messages |
| Embedded UI/backend assumptions | Explicit domain/application/infrastructure boundaries |

## Configuration

Do not copy the old configuration file over the version 2 file. Start the new application and recreate providers/accounts through the desktop UI so credentials enter the encrypted vault and all schema-2 invariants are applied.

Model mappings should be recreated under **Models & pricing** as explicit aliases. Add current verified pricing separately.

## Client migration

The default local port remains configurable. Update clients to one of:

```text
http://127.0.0.1:8081/v1/chat/completions
http://127.0.0.1:8081/v1/responses
http://127.0.0.1:8081/v1/messages
```

Enable a new local proxy key under **Settings** and update client environment variables accordingly.

## Data

Version 1 request logs are not imported. Version 2 starts a new SQLite usage ledger with normalized token, cost, latency, status, and route-attempt fields.

## Cleanup

After validating version 2, remove obsolete startup scripts, browser shortcuts, environment overrides, and version 1 application-data backups that contain stale credentials. Keep backups only when encrypted and necessary.
