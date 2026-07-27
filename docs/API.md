# Local compatibility API

The server listens on loopback. Local authentication can protect all routes except `/health`.

Send the local key in one of these headers:

- `Authorization: Bearer LOCAL_KEY`
- `x-api-key: LOCAL_KEY`

## `GET /health`

This route returns local process health without authentication.

```json
{
  "status": "ok",
  "version": 2,
  "providers": 4
}
```

## `GET /v1/models`

This route returns aliases and exact provider model IDs. It does not return model entries that contain wildcards.

```json
{
  "object": "list",
  "data": [
    { "id": "gpt-5", "object": "model", "owned_by": "subscription-proxy-inator" }
  ]
}
```

## `POST /v1/chat/completions`

Supported OpenAI Chat Completions fields:

- `model`
- `messages`
- System, developer, user, assistant, and tool roles
- Text and image content
- `tools`
- `tool_choice`
- `temperature`
- `top_p`
- `max_completion_tokens`
- `max_tokens`
- `stop`
- `stream`
- `metadata`

A stream returns `chat.completion.chunk` SSE frames. The final frame is `[DONE]`.

A pre-completion error uses an OpenAI error frame.

## `POST /v1/responses`

Supported Responses fields:

- `model`
- String or item-array `input`
- `instructions`
- Function tools
- Tool choice
- `temperature`
- `top_p`
- `max_output_tokens`
- `stream`
- `metadata`

A non-stream response contains message items and function-call items.

A stream can return `response.created`, text deltas, tool deltas, `response.completed`, or `response.failed`.

## `POST /v1/messages`

Supported Anthropic Messages fields:

- `model`
- `system`
- `messages`
- Text blocks
- Image blocks
- Tool-use blocks
- Tool-result blocks
- `tools`
- `tool_choice`
- `temperature`
- `top_p`
- `max_tokens`
- `stop_sequences`
- `stream`
- `metadata`

A stream uses Anthropic event names. Content-block indexes remain stable.

A stream error uses the Anthropic `error` event.

## `POST /v1/messages/count_tokens`

This route returns a local estimate from serialized input size.

```json
{ "input_tokens": 42 }
```

The route does not call a provider tokenizer. Treat the value as an estimate.

## Sticky session headers

The gateway recognizes these headers:

- `x-session-id`
- `x-sticky-session`
- `anthropic-session-id`

The header value becomes the sticky route key. A healthy account stays selected until the configured lifetime ends.

A Grok route also sends the value as the xAI conversation ID.

## Content conversion

Protocol conversion supports these data types:

- Text
- URL images
- Inline images
- Tool declarations
- Tool calls
- Incremental tool arguments
- Tool results
- Error results
- Token and cache usage
- Stop reasons

Provider support can differ. A compatible server can reject a field that it does not implement.

## Error responses

A failure before streaming uses the client protocol JSON error shape.

An OpenAI error can contain sanitized route summaries. The summary can include provider ID, account ID, and machine code.

The summary does not contain credentials, prompts, or provider secret headers.
