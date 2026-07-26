# Configuration reference

Configuration is stored in `config.json`, validated on every load and write, and assigned schema version 2. The renderer receives a public copy without secret references.

## Server

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `host` | string | `127.0.0.1` | Must be `127.0.0.1` or `localhost` |
| `port` | integer | `8081` | Local port from 1024 through 65535 |
| `corsOrigins` | string array | `[]` | Exact browser origins; wildcards are rejected |
| `apiKeySecretRef` | internal string | `null` | Encrypted local bearer-key reference; never rendered |
| `requestTimeoutMs` | integer | `120000` | Standard upstream request timeout |
| `startOnLogin` | boolean | `false` | Electron login-item behavior |

The server restarts only when host or port changes. A failed restart rolls configuration and login effects back.

## Routing

| Field | Meaning |
| --- | --- |
| `strategy` | Global strategy identifier |
| `maxAttempts` | Maximum candidate attempts per request, 1–20 |
| `stickyTtlMs` | Sticky-session route lifetime |
| `baseCooldownMs` | Initial transient-failure cooldown |
| `maxCooldownMs` | Maximum exponential cooldown |
| `failoverOnAuthError` | Whether another account may be tried after an auth failure |

## Provider

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

Remote provider URLs require HTTPS. Plain HTTP is accepted only for loopback-compatible endpoints. URLs cannot contain usernames or passwords.

Custom headers are non-secret only. Header names resembling authorization, API keys, cookies, or tokens are discarded. Store credentials as accounts instead.

### Adapter options

Adapter options are provider-specific JSON. Examples:

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

## Account

| Field | Meaning |
| --- | --- |
| `id` | Stable global account ID |
| `label` | Human-readable account name |
| `enabled` | Whether the account is eligible |
| `secretRef` | Internal encrypted reference; not rendered |
| `priority` | Lower numeric value is preferred by priority routing |
| `weight` | Positive relative weight for weighted random routing |
| `limits.requestsPerMinute` | Local rolling request limit |
| `limits.tokensPerDay` | Local input + output token limit since UTC day start |
| `limits.tokensPerMonth` | Local input + output token limit since UTC month start |
| `limits.costPerMonthUsd` | Local estimated/reported cost limit since UTC month start |
| `metadata` | Non-secret adapter/account metadata |

A `null` limit means unlimited. Local limits are safeguards based on recorded gateway usage; they do not query or alter upstream quotas.

## Model aliases

```json
{
  "id": "alias_fast",
  "requested": "fast",
  "providerId": "provider_openai",
  "target": "gpt-5-mini"
}
```

Provider-specific aliases outrank global aliases. Duplicate requested/scope pairs are rejected.

## Pricing

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

Rules may target a provider ID, provider type, or every provider. Exact provider and model rules are more specific than broad type/glob rules. Rates must be non-negative. Source URLs must use HTTPS.

## Appearance and retention

- `appearance.theme`: `system`, `dark`, or `light`.
- `appearance.compact`: compact desktop density.
- `appearance.reduceMotion`: disable nonessential transitions.
- `retentionDays`: 1–3650 days of local usage history.
