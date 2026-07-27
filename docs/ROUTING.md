# Routing and failover

## Route eligibility

A provider and account route is eligible only when all these conditions are true:

- The provider is enabled.
- The account is enabled.
- The provider model globs match the requested model.
- The account has an encrypted secret reference.
- The account has no active cooldown.
- The account does not need attention.
- The account is below all local limits.
- Attempt limits are not complete.

The router checks the client model before it applies an alias. It applies the provider alias immediately before the adapter call.

## Strategies

| Strategy | Selection rule |
| --- | --- |
| `priority` | Select the lowest account priority |
| `round-robin` | Rotate through eligible routes |
| `weighted-random` | Use each positive account weight |
| `least-inflight` | Select the lowest active request count |
| `lowest-latency` | Select the lowest recent weighted latency |
| `lowest-cost` | Select the lowest estimated model cost |
| `sticky` | Reuse a healthy session route |

The global strategy applies when a provider has no override. A provider override changes only that provider's route order.

The reset action removes all provider overrides. It also sets the selected global strategy.

## Local limits

Local account limits use recorded gateway data:

- Requests during the last 60 seconds
- Tokens since the UTC day start
- Tokens since the UTC month start
- Cost since the UTC month start

An account becomes ineligible when a value reaches its limit.

These values are local safeguards. They are not provider quota values.

## Failure classes

The router uses machine codes such as:

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

A `Retry-After` value sets the cooldown when it is available. Otherwise, the cooldown grows from `baseCooldownMs` to `maxCooldownMs`.

An authentication or permission error marks the account for attention.

The router can try another account after an authentication error only when `failoverOnAuthError` is true.

Client cancellation reduces the active request count. It does not mark the account as failed.

## Streaming boundary

The gateway buffers metadata before visible output. SSE heartbeat comments can pass through immediately.

The first text delta or tool call starts visible output.

After visible output starts:

- The route cannot change.
- The same stream returns the error.
- The gateway does not call another provider.

This rule prevents duplicate text and repeated tool effects.

Read [ADR 0002](adr/0002-streaming-failover.md).

## Route attempts

Each route attempt stores these fields:

- Request ID
- Attempt ID
- Start time
- Provider ID
- Account ID
- Upstream model
- Final status
- Latency
- Error code

Select a request in **Usage** to see its attempts.
