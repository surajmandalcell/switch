# Routing and failover

## Candidate eligibility

A provider/account route is eligible only when:

- The provider and account are enabled.
- The provider model globs match the requested model.
- The account has an encrypted credential reference.
- The account is not in cooldown or attention-only state.
- The account is below all configured local limits.
- The provider and global attempt budgets have not been exhausted.

Model eligibility is evaluated using the client-requested model. The provider-specific alias is applied immediately before invoking the adapter.

## Strategies

| Strategy | Ordering |
| --- | --- |
| `priority` | Lowest account priority, then stable IDs |
| `round-robin` | Rotating eligible candidate index |
| `weighted-random` | Random selection proportional to positive account weight |
| `least-inflight` | Lowest active request count |
| `lowest-latency` | Lowest exponentially weighted recent latency |
| `lowest-cost` | Lowest estimated cost for aliased upstream model |
| `sticky` | Existing healthy session route, otherwise priority selection and pin |

One global strategy applies to every provider without an override. Provider overrides change ordering only for candidates belonging to that provider. The desktop reset action clears every override and replaces the global strategy.

## Limits

Local account limits use recorded gateway usage:

- Requests in the trailing 60 seconds.
- Tokens since UTC day start.
- Tokens since UTC month start.
- Cost since UTC month start.

A value equal to or above the configured limit makes the account ineligible. These limits are local safeguards and do not represent the upstream provider’s authoritative quota.

## Failure classification

The router classifies failures into machine codes such as:

- `rate_limited`
- `quota_exhausted`
- `authentication_error`
- `permission_error`
- `overloaded`
- `timeout`
- `network_error`
- `client_cancelled`
- `invalid_request`
- `upstream_error`

`Retry-After` controls cooldown when present. Otherwise transient failure cooldown grows exponentially from `baseCooldownMs` and is clamped by `maxCooldownMs`.

Authentication and permission failures mark the account for attention. They may be followed by another account only when `failoverOnAuthError` is enabled.

Client cancellation decrements in-flight state without marking the account failed or placing it in cooldown.

## Streaming safety

Before visible output, metadata events are buffered. Heartbeats are sent immediately as SSE comments but do not count as semantic output.

The first non-empty text delta or tool call establishes the visible boundary. After that boundary:

- The selected route cannot change.
- A failure is returned to the client on the same stream.
- No second provider is invoked.

This rule prevents duplicated text, repeated tool execution, and hidden cross-provider continuation.

See [ADR 0002](adr/0002-streaming-failover.md).

## Route attempts

Every attempt records:

- Request ID and attempt ID.
- Start time.
- Provider and account.
- Aliased upstream model.
- Success, error, or cancellation status.
- Latency and error code.

The **Usage** screen exposes attempts for a selected request.
