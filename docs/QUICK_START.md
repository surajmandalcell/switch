# Quick start

## Install from source

```bash
git clone https://github.com/surajmandalcell/subscription-proxy-inator.git
cd subscription-proxy-inator
npm ci
npm run check
npm run dev
```

The desktop window and local server start together. The default address is `http://127.0.0.1:8081`.

## Add a provider

1. Open **Providers**.
2. Select a provider preset.
3. Enter a base URL when the preset has no URL.
4. Add one or more accounts.
5. Enter the account credentials.
6. Set priority, weight, and local limits.
7. Save the provider.

The main process encrypts credentials. The renderer does not receive the credential values.

## Select a routing strategy

1. Open **Routing**.
2. Select the global strategy.
3. Add a provider override when necessary.

Use `priority` for a predictable first configuration. Use `least-inflight` for concurrent work.

Use `lowest-cost` only when the pricing catalog has current rules.

## Connect an OpenAI-compatible client

```bash
curl http://127.0.0.1:8081/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer YOUR_LOCAL_PROXY_KEY' \
  -d '{
    "model": "gpt-5",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## Connect an Anthropic-compatible client

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

The local key is necessary only after you enable it in **Settings**.

## Add model aliases and prices

Open **Models & pricing**. Then do these tasks:

- Map a client model ID to an upstream model.
- Add rates for input, output, cache read, and cache write tokens.
- Add the source URL and verification date.

## Validate the checkout

```bash
npm run build
npm run dist:dir
```

The first command runs all source checks and web builds. The second command builds an unpacked desktop application.
