# Account Management

## Storage Structure

The proxy stores one configured ChatGPT account at a time.

| File | Purpose |
| --- | --- |
| `~/.codex-claude-proxy/account.json` | Local account registry and quota snapshot |
| `~/.codex-claude-proxy/auth.json` | Token file compatible with the Codex app auth shape |
| Legacy `accounts.json` in the config directory | Legacy file read once for migration only |

### Main Registry

```json
{
  "account": {
    "email": "user@gmail.com",
    "accountId": "d41e9636-16d8-42be-91da-7ea8773bfb7e",
    "planType": "plus",
    "accessToken": "eyJhbGciOiJSUzI1NiIs...",
    "refreshToken": "rt_WpTMn1...",
    "idToken": "eyJhbGciOiJSUzI1NiIs...",
    "expiresAt": 1770886178000,
    "addedAt": "2026-02-13T04:00:00.000Z",
    "lastUsed": "2026-02-13T04:30:00.000Z",
    "quota": {
      "usage": {},
      "account": {},
      "lastChecked": "2026-02-14T10:00:00.000Z"
    }
  },
  "activeAccount": "user@gmail.com",
  "version": 2
}
```

## Operations

| Operation | Endpoint |
| --- | --- |
| View configured account | `GET /account` |
| Start browser OAuth | `POST /account/add` |
| Complete headless OAuth | `POST /account/add/manual` |
| Import from Codex app | `POST /account/import` |
| Refresh token | `POST /account/refresh` |
| Fetch quota | `GET /account/quota` |
| Remove account | `DELETE /account` |

Adding, importing, or manually completing OAuth replaces the existing local account.

### Add Account

```bash
curl -X POST http://localhost:8081/account/add
```

### Import from Codex App

```bash
curl -X POST http://localhost:8081/account/import
```

### View Account

```bash
curl http://localhost:8081/account
```

### Remove Account

```bash
curl -X DELETE http://localhost:8081/account
```

## Token Lifecycle

| Step | Behavior |
| --- | --- |
| Expiration | Access tokens expire in about 1 hour. |
| Auto-refresh | Background refresh runs every 55 minutes. |
| Startup | The server schedules a refresh shortly after startup. |
| Request path | Each OpenAI-bound request uses the one configured account after refreshing if needed. |

## Quota Tracking

```bash
curl http://localhost:8081/account/quota
```

The Account tab renders remaining quota from the normalized usage percentage. If quota data is unavailable, the UI shows `Unavailable` instead of rendering a broken bar. If the upstream marks the limit as reached, the UI shows the quota as used.

## Legacy Migration

On first startup after upgrading, the proxy checks for the old `accounts.json` file only if `account.json` does not already exist. It imports the previously selected account, or the first account in the legacy file when no selection is recorded. Legacy files are left in place unless the user clears the configured account.

## Security

| Boundary | Detail |
| --- | --- |
| Local storage | Tokens stay under `~/.codex-claude-proxy/`. |
| File permissions | Account files are written with user-only permissions where supported. |
| API responses | Access, refresh, and ID tokens are never returned in account API responses. |
| Account boundary | The proxy does not share, pool, rotate, or retry across other accounts. |
