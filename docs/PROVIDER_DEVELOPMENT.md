# Provider development

## Adapter contract

Register each adapter with one unique `type`.

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

## Execution context

| Property | Function |
| --- | --- |
| `provider` | Give the validated provider settings |
| `account` | Give the selected public account data |
| `secret` | Give the decrypted credential for this attempt |
| `signal` | Stop work after cancellation |
| `timeoutMs` | Set the provider timeout |
| `logger` | Write redacted structured logs |

## Canonical content

Supported content blocks:

- `text`
- `image`
- `tool-call`
- `tool-result`

A `tool-call` contains an ID, name, input, and optional thought signature.

A `tool-result` contains a call ID, optional name, content, and error state.

Supported stream events:

- `start`
- `text-delta`
- `tool-call`
- `usage`
- `finish`
- `image`
- `heartbeat`

A heartbeat shows transport activity. It is not visible model output and does not stop pre-output failover.

## Error data

Preserve these values when the provider supplies them:

- HTTP status in `error.status`
- Machine code in `error.code`
- Retry delay in `error.details.retryAfter` or `error.retryAfter`
- Cancellation as `AbortError` or `CLIENT_ABORTED`

Do not retry in an adapter. Routing controls retries and the visible-output boundary.

## Usage data

Return these normalized fields when they are available:

```js
{
  inputTokens,
  outputTokens,
  cacheReadTokens,
  cacheWriteTokens,
  reportedCostUsd
}
```

Keep a provider-reported billed cost. The usage service gives it priority over a local estimate.

## Tests

Test these conditions for each adapter:

- Non-streaming request and response conversion
- Stream event order
- Tool calls and tool results
- Images when supported
- Token and cache fields
- Error status and retry data
- Timeout and client cancellation
- Provider headers and options
