# Providers

## Provider/account model

A provider describes one upstream protocol and endpoint. Accounts hold encrypted credentials and routing properties. Multiple accounts can belong to the same provider, and multiple providers can be eligible for the same requested model.

The router does not inspect credential content. It selects an eligible account, resolves its encrypted secret in the main process, and passes the secret only to the chosen adapter.

## OpenAI

- Type: `openai`
- Default base URL: `https://api.openai.com/v1`
- Wire API: Chat Completions
- Supports JSON, SSE, tools, tool results, images accepted from compatible clients, and usage.

Client-facing OpenAI Responses requests are normalized and can be routed through this adapter, then serialized back to Responses format.

## Anthropic

- Type: `anthropic`
- Default base URL: `https://api.anthropic.com/v1`
- Wire API: Messages
- Sends `x-api-key` and an Anthropic version header.
- Supports JSON, SSE, tools, tool results, images, cache-token usage, and stop reasons.

## Google Gemini

- Type: `gemini`
- Default base URL: `https://generativelanguage.googleapis.com/v1beta`
- Standard models use native `generateContent` and `streamGenerateContent`.
- Supports system instructions, text, inline/URL images, functions, function calls, function responses, generation settings, usage metadata, and Gemini thought signatures.

### Deep Research

Model IDs beginning with `deep-research-` use Google’s Interactions API rather than `generateContent`.

The adapter:

1. Creates a background interaction.
2. Polls the interaction until completed, failed, cancelled, or timed out.
3. Emits SSE keep-alive comments while waiting.
4. Returns the final cited report and generated images as canonical content.
5. Cancels the interaction when the local client disconnects.

Options live under `provider.adapter.deepResearch`; see [Configuration](CONFIGURATION.md).

Official references:

- [Gemini Deep Research agent](https://ai.google.dev/gemini-api/docs/deep-research)
- [Gemini Interactions API](https://ai.google.dev/gemini-api/docs/interactions)

## xAI Grok

- Type: `grok`
- Default base URL: `https://api.x.ai/v1`
- Uses xAI’s OpenAI-compatible Chat Completions interface.
- Supports JSON, SSE, tools, and normalized usage.
- For sticky requests, the canonical session ID is forwarded as `x-grok-conv-id`.
- `provider.adapter.serviceTier` is forwarded as `service_tier`.
- `cost_in_usd_ticks` is converted to an upstream-reported USD value and takes precedence over local estimates.

Official references:

- [xAI Chat Completions](https://docs.x.ai/developers/api-reference#chat-completions)
- [xAI cost tracking](https://docs.x.ai/docs/key-information/monitoring-usage)

## OpenAI-compatible

- Type: `openai-compatible`
- Configure an HTTPS URL or a loopback HTTP URL.
- Uses the same Chat Completions adapter as OpenAI.
- Suitable for gateways and local servers that implement the expected OpenAI request, response, and SSE shapes.

Compatibility is behavioral, not brand-based. Verify tool, image, stream, and usage fields for the target endpoint.

## Anthropic-compatible

- Type: `anthropic-compatible`
- Configure an HTTPS URL or a loopback HTTP URL.
- Uses Anthropic Messages wire shapes and headers.

## Command / CLI

- Type: `command`
- Executes an explicit binary without a shell.
- Sends one canonical request as JSON followed by a newline on standard input.
- Sets `SPI_ACCOUNT_SECRET` for the selected account.
- Reads one canonical stream event as JSON per line from standard output.
- Captures standard error and returns a provider failure for non-zero exit codes.
- Terminates the child on client cancellation.

Example output:

```jsonl
{"type":"start","model":"example"}
{"type":"text-delta","text":"Hello"}
{"type":"usage","usage":{"inputTokens":10,"outputTokens":2}}
{"type":"finish","stopReason":"end_turn"}
```

Only configure commands you trust. A command provider executes with the desktop process user’s permissions.

## Trusted external modules

- Type: `external-module`
- Module files must live below the application user-data `providers` directory.
- The module must export `createAdapter(options)`.
- `reloadToken` changes the import cache key.

External modules are path-restricted but not sandboxed. They execute in the main process and must be treated as installed trusted code.

See [Provider development](PROVIDER_DEVELOPMENT.md).
