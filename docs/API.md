# Local compatibility API

The server listens on loopback only. All endpoints except `/health` require the configured local key when local authentication is enabled. Supply it as `Authorization: Bearer …` or `x-api-key`.

## `GET /health`

Returns local process health without authentication:

```json
{
  "status": "ok",
  "version": 2,
  "providers": 4
}
```

## `GET /v1/models`

Returns configured model aliases and provider model entries that do not contain wildcard characters.

```json
{
  "object": "list",
  "data": [
    { "id": "gpt-5", "object": "model", "owned_by": "subscription-proxy-inator" }
  ]
}
```

## `POST /v1/chat/completions`

Accepts OpenAI Chat Completions fields:

- `model`
- `messages`
- system, developer, user, assistant, and tool roles
- string and structured text/image content
- `tools` and `tool_choice`
- `temperature`, `top_p`, `max_completion_tokens`, `max_tokens`, and `stop`
- `stream`
- `metadata`

Streaming returns `chat.completion.chunk` SSE data frames and a final `[DONE]` frame. Errors before stream completion use an OpenAI-style error data frame.

## `POST /v1/responses`

Accepts the implemented subset of OpenAI Responses:

- `model`
- string or item-array `input`
- `instructions`
- function tools and tool choice
- `temperature`, `top_p`, and `max_output_tokens`
- `stream`
- `metadata`

Non-streaming output contains message and function-call items. Streaming emits `response.created`, output text/tool deltas, `response.completed`, or `response.failed`.

## `POST /v1/messages`

Accepts Anthropic Messages fields:

- `model`
- `system`
- `messages`
- text, image, tool-use, and tool-result blocks
- `tools` and `tool_choice`
- `temperature`, `top_p`, `max_tokens`, and `stop_sequences`
- `stream`
- `metadata`

Streaming emits Anthropic event names and maintains stable content-block indexes. Streaming errors use the Anthropic `error` event envelope.

## `POST /v1/messages/count_tokens`

Returns a deterministic local estimate based on serialized input size:

```json
{ "input_tokens": 42 }
```

This endpoint does not call an upstream tokenizer and should be treated as an estimate.

## Session routing

The gateway recognizes:

- `x-session-id`
- `x-sticky-session` for Chat Completions
- `anthropic-session-id` for Anthropic Messages

The value becomes the canonical sticky key. With sticky routing, a healthy selected account remains pinned until the configured TTL expires. Grok routes also forward the value as the xAI conversation ID.

## Content and tools

Protocol conversion normalizes:

- Text blocks.
- URL and inline-data images.
- Function/tool declarations.
- Tool invocations with incremental arguments.
- Tool results and error results.
- Usage and cache usage.
- End-turn, token-limit, tool-use, and stop-sequence reasons.

Provider capabilities still apply. A compatible endpoint may ignore or reject fields it does not implement.

## Failure responses

Before streaming starts, failures use the client protocol’s JSON error shape. The OpenAI error includes sanitized route failure summaries containing provider ID, account ID, and machine code; it does not include credentials, prompts, or upstream secret headers.
