# Usage and pricing

## Request ledger

Each completed, failed, or cancelled request stores:

- Start time and status.
- Client protocol.
- Requested and upstream model.
- Selected provider and account.
- Input and output tokens.
- Cache-read and cache-write tokens.
- Estimated or upstream-reported USD cost.
- Total latency and first-token latency.
- Terminal error code.

Prompts, response text, tools, and credentials are not stored in the usage ledger.

## Route-attempt ledger

A request can have several upstream attempts before success. Attempts are stored separately so the final request record remains one row while diagnostics retain each provider/account failure and latency.

## Filters

The UI and repository support composable filters:

- Status.
- Provider.
- Account.
- Client protocol.
- Inclusive start and end timestamps.

The same filter object is used by the ledger, summary, and CSV export.

## Pricing specificity

A pricing rule matches by:

1. Provider ID, provider type, or every provider.
2. Model glob.
3. Verification date as a tiebreaker.

Provider-ID rules are more specific than provider-type rules. Exact model names are more specific than wildcard globs. The most specific matching rule wins.

## Cost calculation

Rates are USD per million tokens:

```text
cost = (
  input × input rate +
  output × output rate +
  cache read × cache-read rate +
  cache write × cache-write rate
) / 1,000,000
```

When an upstream reports billed cost, that value takes precedence. xAI cost ticks are normalized to USD. If no rule or reported cost exists, the ledger stores zero and the pricing status is unknown internally.

## Lowest-cost routing

Before routing, the application estimates canonical input tokens from the system, messages, and tools. Expected output uses the request maximum or a conservative default. Each provider’s alias and pricing rule produce a comparable estimated route cost.

Accurate lowest-cost routing requires current pricing rules and reasonable output limits. It is an estimate, not a billing guarantee.

## Retention and export

Retention is configurable from 1 to 3650 days. Pruning deletes old request and route-attempt rows.

CSV columns are stable:

```text
id, startedAt, status, protocol, requestedModel, upstreamModel,
providerId, accountId, inputTokens, outputTokens, cacheReadTokens,
cacheWriteTokens, estimatedCostUsd, latencyMs, firstTokenLatencyMs
```
