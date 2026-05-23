# API Reference

## Main Endpoints

### Kilo Routing Settings

The explicit `kilo` model route can be configured to use an alternate provider target such as **MiniMax M2.5** or **Kimi K2.5** when `CODEX_CLAUDE_PROXY_ENABLE_KILO=true` is set. Claude Haiku aliases use OpenAI by default.

```bash
GET /settings/haiku-model

# Response
{
  "success": true,
  "haikuKiloModel": "minimax/minimax-m2.5:free",
  "kiloEnabled": false
}
```

```bash
POST /settings/haiku-model
Content-Type: application/json

{
  "haikuKiloModel": "minimax-2.5"
}

# Response
{
  "success": true,
  "haikuKiloModel": "minimax-2.5",
  "kiloEnabled": true
}
```

### Chat Completions (OpenAI-compatible)

```bash
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "gpt-5.5",
  "messages": [{"role": "user", "content": "Hello"}],
  "tools": [...],
  "stream": true
}
```

### Messages (Anthropic-compatible)

```bash
POST /v1/messages
Content-Type: application/json

{
  "model": "claude-sonnet-4-5",
  "max_tokens": 1024,
  "system": "You are helpful.",
  "messages": [{"role": "user", "content": "Hello"}],
  "tools": [...],
  "stream": true
}
```

### Models

```bash
GET /v1/models
```

### Token Counting

```bash
POST /v1/messages/count_tokens
Content-Type: application/json

{
  "messages": [...],
  "tools": [...]
}
```

## Account Management

Common endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/account` | GET | View the configured account |
| `/account/status` | GET | Get account status summary |
| `/account/add` | POST | Start OAuth flow that replaces the local account |
| `/account/add/manual` | POST | Complete headless OAuth manually |
| `/account/import` | POST | Import the local Codex app account, replacing the existing local account |
| `/account/refresh` | POST | Refresh the configured account token |
| `/account/quota` | GET | Get quota info |
| `/account/models` | GET | Get models for the configured account |
| `/account/usage` | GET | Get usage stats for the configured account |
| `/account/oauth/cleanup` | POST | Stop any pending OAuth callback server |
| `/account` | DELETE | Remove the configured account |

### Add Account

```bash
POST /account/add
Content-Type: application/json

# Optional: specify callback port
{"port": 1455}

# Response
{
  "status": "oauth_url",
  "oauth_url": "https://auth.openai.com/oauth/authorize?...",
  "callback_port": 1455
}
```

### Import Account

```bash
POST /account/import

# Response
{"success": true, "message": "Imported account from Codex"}
```

### Refresh Account

```bash
POST /account/refresh

# Response
{"success": true, "message": "Token refreshed"}
```

### OAuth Callback

```bash
GET /auth/callback?code=...&state=...
```

## Claude CLI Configuration

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/claude/config` | GET | View current config |
| `/claude/config/proxy` | POST | Configure for proxy |
| `/claude/config/direct` | POST | Configure for direct API |

### Configure Proxy Mode

```bash
POST /claude/config/proxy

# Response
{
  "success": true,
  "message": "Claude CLI configured to use proxy at http://localhost:8081",
  "config": {...}
}
```

## Health

```bash
GET /health

# Response
{
  "status": "ok",
  "total": 1,
  "active": "active@example.com",
  "account": {...}
}
```

## Error Responses

### Authentication Error

```json
{
  "type": "error",
  "error": {
    "type": "authentication_error",
    "message": "No account configured"
  }
}
```

### Rate Limit Error

```json
{
  "type": "error",
  "error": {
    "type": "rate_limit_error",
    "message": "Rate limited: ..."
  }
}
```

## Streaming Events

Anthropic SSE format:

```
event: message_start
data: {"type":"message_start","message":{...}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{...}}

event: message_stop
data: {"type":"message_stop"}

data: [DONE]
```

## Tool Calling

### Request with Tools

```json
{
  "model": "claude-sonnet-4-5",
  "messages": [
    {"role": "user", "content": "What's the weather in Tokyo?"}
  ],
  "tools": [{
    "name": "get_weather",
    "description": "Get weather for a location",
    "input_schema": {
      "type": "object",
      "properties": {
        "location": {"type": "string"}
      },
      "required": ["location"]
    }
  }]
}
```

### Response with Tool Use

```json
{
  "id": "msg_...",
  "type": "message",
  "role": "assistant",
  "content": [{
    "type": "tool_use",
    "id": "toolu_...",
    "name": "get_weather",
    "input": {"location": "Tokyo"}
  }],
  "stop_reason": "tool_use"
}
```

### Tool Result

```json
{
  "messages": [
    {"role": "user", "content": "What's the weather?"},
    {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_123", "name": "get_weather", "input": {"location": "Tokyo"}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_123", "content": "Sunny, 22°C"}]}
  ]
}
```
