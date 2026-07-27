# Configuration reference

The application stores non-secret settings in `config.json`. It checks the file during each read and write.

The current schema version is 2. The renderer receives a public copy without secret references.

## Server settings

| Field | Type | Default | Function |
| --- | --- | --- | --- |
| `host` | string | `127.0.0.1` | Set the loopback host |
| `port` | integer | `8081` | Set a local port from 1024 through 65535 |
| `corsOrigins` | string array | `[]` | Set exact browser origins |
| `apiKeySecretRef` | internal string | `null` | Refer to the encrypted local key |
| `requestTimeoutMs` | integer | `120000` | Set the provider request timeout |
| `startOnLogin` | boolean | `false` | Start the app after user login |

The renderer never receives `apiKeySecretRef`.

The server restarts when the host or port changes. A failed restart restores the old configuration and login state.

## Routing settings

| Field | Function |
| --- | --- |
| `strategy` | Set the global strategy |
| `maxAttempts` | Set 1 through 20 candidate attempts |
| `stickyTtlMs` | Set the sticky route lifetime |
| `baseCooldownMs` | Set the first temporary-failure cooldown |
| `maxCooldownMs` | Set the maximum cooldown |
| `failoverOnAuthError` | Permit another account after an authentication error |

## Provider object

```json
{
  "id": "provider_openai",
  "name": "OpenAI",
  "type": "openai",
  "enabled": true,
  "baseUrl": "https://api.openai.com/v1",
  "modelGlobs": ["gpt-*"],
  "strategyOverride": null,
  "maxAttempts": null,
  "headers": {},
  "adapter": {},
  "accounts": []
}
```

A remote provider URL must use HTTPS. A loopback provider URL can use HTTP.

A provider URL cannot contain a user name or password.

Custom headers must not contain credentials. The application removes header names that look like authorization, keys, cookies, or tokens.

Store a credential in an account.

### Adapter settings

Adapter settings use provider-specific JSON.

Grok service tier:

```json
{
  "serviceTier": "priority"
}
```

Gemini Deep Research:

```json
{
  "deepResearch": {
    "pollIntervalMs": 5000,
    "timeoutMs": 1800000,
    "thinkingSummaries": "auto",
    "visualization": "off",
    "collaborativePlanning": false,
    "tools": [{ "type": "google_search" }]
  }
}
```

Command provider:

```json
{
  "command": "gemini",
  "args": ["--json"],
  "environment": {
    "EXAMPLE_MODE": "local"
  }
}
```

External module:

```json
{
  "modulePath": "/platform/user-data/providers/custom.mjs",
  "reloadToken": "2026-07-26",
  "options": {}
}
```

## Account object

| Field | Function |
| --- | --- |
| `id` | Set the global account ID |
| `label` | Set the account name |
| `enabled` | Permit route selection |
| `secretRef` | Refer to the encrypted credential |
| `priority` | Set the priority order |
| `weight` | Set the weighted-random share |
| `limits.requestsPerMinute` | Set the local request limit |
| `limits.tokensPerDay` | Set the local daily token limit |
| `limits.tokensPerMonth` | Set the local monthly token limit |
| `limits.costPerMonthUsd` | Set the local monthly cost limit |
| `metadata` | Store non-secret adapter data |

The renderer does not receive `secretRef`.

A `null` limit means that the local limit is off. Local limits use gateway records and do not change provider quotas.

## Model alias

```json
{
  "id": "alias_fast",
  "requested": "fast",
  "providerId": "provider_openai",
  "target": "gpt-5-mini"
}
```

A provider alias has priority over a global alias. The application rejects two aliases with the same request and scope.

## Price rule

```json
{
  "id": "price_openai_gpt5",
  "providerId": "provider_openai",
  "providerType": null,
  "modelGlob": "gpt-5",
  "inputPerMillionUsd": 1.25,
  "outputPerMillionUsd": 10,
  "cacheReadPerMillionUsd": 0.125,
  "cacheWritePerMillionUsd": 0,
  "sourceUrl": "https://provider.example/pricing",
  "verifiedAt": "2026-07-26"
}
```

A rule can match one provider ID, one provider type, or all providers. An exact provider and model rule has the highest priority.

A rate cannot be negative. A source URL must use HTTPS.

## Appearance and retention

- `appearance.theme`: Use `system`, `dark`, or `light`.
- `appearance.compact`: Use compact desktop spacing.
- `appearance.reduceMotion`: Remove nonessential motion.
- `retentionDays`: Keep 1 through 3650 days of usage data.
