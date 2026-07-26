# Provider development

## Canonical adapter contract

A provider adapter is registered by unique `type` and implements:

```js
export function createAdapter(options) {
  return {
    type: 'example',
    async execute(request, context) {
      return {
        id: 'response-id',
        model: request.model,
        content: [{ type: 'text', text: 'Hello' }],
        usage: { inputTokens: 10, outputTokens: 2 },
        stopReason: 'end_turn'
      };
    },
    async *stream(request, context) {
      yield { type: 'start', model: request.model };
      yield { type: 'text-delta', text: 'Hello' };
      yield { type: 'usage', usage: { inputTokens: 10, outputTokens: 2 } };
      yield { type: 'finish', stopReason: 'end_turn' };
    }
  };
}
```

## Context

| Property | Meaning |
| --- | --- |
| `provider` | Validated provider configuration |
| `account` | Selected account without decrypted data in persisted config |
| `secret` | Decrypted selected credential for this attempt |
| `signal` | Abort signal for client disconnect and cancellation |
| `timeoutMs` | Standard request timeout |
| `logger` | Redacting structured logger |

## Canonical content

Supported blocks:

- `text`
- `image` with data or URL
- `tool-call` with ID, name, input, and optional thought signature
- `tool-result` with call ID, optional name, content, and error flag

Stream events include `start`, `text-delta`, `tool-call`, `usage`, `finish`, `image`, and `heartbeat`.

A heartbeat is transport progress only. It must never be treated as visible semantic output and should not prevent pre-output failover.

## Error behavior

Adapters should preserve:

- HTTP status in `error.status`.
- Machine code in `error.code` when available.
- `Retry-After` in `error.details.retryAfter` or `error.retryAfter`.
- Abort identity using `AbortError` or `CLIENT_ABORTED`.

Do not implement retries in an adapter. Routing owns cross-account/provider retries and the no-retry-after-visible-output rule.

## Usage

Return normalized fields whenever the upstream exposes them:

```js
{
  inputTokens,
  outputTokens,
  cacheReadTokens,
  cacheWriteTokens,
  reportedCostUsd
}
```

If an upstream provides a billed cost, preserve it. The usage service prefers reported cost over local pricing estimates.

## Tests

Every adapter should test:

- Non-streaming request body and response conversion.
- Streaming event ordering.
- Tool calls and tool results.
- Images where supported.
- Usage and cache fields.
- Non-success status and retry metadata.
- Timeout and client cancellation.
- Provider-specific headers/options.
