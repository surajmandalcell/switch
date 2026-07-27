# Version 1 migration

Version 2 replaces the version 1 architecture. It is not an in-place extension.

## Main changes

| Version 1 | Version 2 |
| --- | --- |
| Browser dashboard | Electron desktop application |
| Small account workflow | Multiple encrypted accounts per provider |
| Provider-specific request path | Canonical protocols and adapters |
| One routing behavior | Seven routing strategies |
| Basic request logs | SQLite request and attempt records |
| Limited compatibility | Chat Completions, Responses, and Messages |
| Mixed UI and server assumptions | Separate domain and outer layers |

## Recreate configuration

Do not copy the old configuration file. Start version 2 and create the providers again.

Use the desktop app to add accounts. This process puts credentials in the encrypted vault.

Recreate model mappings in **Models & pricing**. Add current pricing rules separately.

## Update clients

Use one of these local routes:

```text
http://127.0.0.1:8081/v1/chat/completions
http://127.0.0.1:8081/v1/responses
http://127.0.0.1:8081/v1/messages
```

Enable a new local proxy key in **Settings**. Then update the client environment variables.

## Usage data

Version 2 does not import version 1 request logs. It starts a new SQLite usage database.

The new database stores token, cost, latency, status, and route-attempt fields.

## Remove old files

Validate version 2 first. Then remove old startup scripts, browser shortcuts, environment overrides, and old application data.

Keep a backup only when it is necessary and encrypted.
