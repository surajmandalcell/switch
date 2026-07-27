# Usage and pricing

## Request records

Each completed, failed, or cancelled request stores these fields:

- Start time
- Status
- Client protocol
- Requested model
- Upstream model
- Provider and account IDs
- Input and output tokens
- Cache-read and cache-write tokens
- Estimated or reported USD cost
- Total latency
- First-token latency
- Final error code

The usage database does not store prompts, response text, tools, or credentials.

## Route-attempt records

One request can have multiple provider attempts. The request remains one row.

Each attempt has a separate row for provider, account, status, latency, and error data.

## Filters

The user interface and repository use the same filter object.

Available filters:

- Status
- Provider
- Account
- Client protocol
- Start time
- End time

The same filters apply to lists, summaries, and CSV export.

## Price rule priority

The application selects a price rule by these values:

1. Provider ID, provider type, or all providers
2. Model glob
3. Verification date

A provider-ID rule has priority over a provider-type rule. An exact model has priority over a wildcard model.

The application uses the most specific rule.

## Cost calculation

Rates use USD per million tokens:

```text
cost = (
  input × input rate +
  output × output rate +
  cache read × cache-read rate +
  cache write × cache-write rate
) / 1,000,000
```

A provider-reported cost has priority over a local calculation. The Grok adapter converts xAI cost ticks to USD.

When no price is available, the stored cost is zero. The internal price state is unknown.

## Lowest-cost routing

The application estimates input tokens from system text, messages, and tools.

The output estimate uses the request maximum or a conservative default. The application applies provider aliases before it compares prices.

Lowest-cost routing needs current price rules and reasonable output limits. The result is an estimate and not a bill.

## Retention and export

Set retention from 1 through 3650 days. Pruning removes old request rows and attempt rows.

CSV columns are stable:

```text
id, startedAt, status, protocol, requestedModel, upstreamModel,
providerId, accountId, inputTokens, outputTokens, cacheReadTokens,
cacheWriteTokens, estimatedCostUsd, latencyMs, firstTokenLatencyMs
```
