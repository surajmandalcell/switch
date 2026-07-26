# Quick start

## Install from source

```bash
git clone https://github.com/surajmandalcell/subscription-proxy-inator.git
cd subscription-proxy-inator
npm ci
npm run check
npm run dev
```

The desktop window and local server start together. The default endpoint is `http://127.0.0.1:8081`.

## Add a provider

1. Open **Providers**.
2. Choose a preset: OpenAI, Anthropic, Google Gemini, xAI Grok, a compatible endpoint, or a command adapter.
3. Enter the base URL when the preset does not supply one.
4. Add one or more accounts and their credentials.
5. Save account priority, weight, enablement, and optional local budgets.

Credentials are encrypted by the main process and are never returned to the renderer.

## Choose routing

Open **Routing** and choose a global strategy. A provider can inherit that strategy or define an override. **Replace overrides** clears every override and applies the selected global policy.

For predictable initial setup, use `priority`. For concurrent workloads, `least-inflight` is a good general default. `lowest-cost` is meaningful only after the pricing catalog contains verified rules.

## Connect a client

OpenAI Chat Completions:

```bash
curl http://127.0.0.1:8081/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer YOUR_LOCAL_PROXY_KEY' \
  -d '{
    "model": "gpt-5",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

Anthropic Messages:

```bash
curl http://127.0.0.1:8081/v1/messages \
  -H 'content-type: application/json' \
  -H 'x-api-key: YOUR_LOCAL_PROXY_KEY' \
  -d '{
    "model": "claude-sonnet",
    "max_tokens": 256,
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

The local key is required only after it is enabled under **Settings**.

## Add aliases and prices

Open **Models & pricing** to:

- Map one client-facing model ID to an upstream model globally or for a specific provider.
- Enter provider/model rates for input, output, cache read, and cache write tokens.
- Record a pricing source URL and verification date.

## Validate a production checkout

```bash
npm run build
npm run dist:dir
```

The first command runs repository verification, the full coverage suite, source links, renderer build, and documentation website build. The second creates an unpacked desktop application for the current platform.
