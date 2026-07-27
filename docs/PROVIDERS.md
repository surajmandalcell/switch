# Providers

## Provider and account model

A provider defines one provider protocol and one base URL. An account stores an encrypted credential and routing settings.

A provider can contain multiple accounts. Multiple providers can match the same requested model.

The router does not read credential content. It selects an account and asks the main process for the secret.

The main process sends the secret only to the selected adapter.

## OpenAI

- Type: `openai`
- Default URL: `https://api.openai.com/v1`
- Provider API: Chat Completions
- Data: JSON and SSE
- Content: text, tools, tool results, and images
- Usage: provider usage fields

The gateway can convert a client Responses request to this adapter. It converts the result back to Responses format.

## Anthropic

- Type: `anthropic`
- Default URL: `https://api.anthropic.com/v1`
- Provider API: Messages
- Authentication: `x-api-key`
- Data: JSON and SSE
- Content: text, images, tools, and tool results
- Usage: token and cache-token fields

## Google Gemini

- Type: `gemini`
- Default URL: `https://generativelanguage.googleapis.com/v1beta`
- Standard APIs: `generateContent` and `streamGenerateContent`
- Content: system instructions, text, images, functions, and function results
- Settings: generation options and usage metadata
- State: Gemini thought signatures

### Deep Research

A model ID that starts with `deep-research-` uses the Gemini Interactions API.

The adapter does these tasks:

1. Create a background interaction.
2. Poll the interaction.
3. Send SSE heartbeat comments while it waits.
4. Return the final report and images.
5. Cancel the interaction after a client disconnect.

Deep Research settings are in `provider.adapter.deepResearch`.

Official references:

- [Gemini Deep Research agent](https://ai.google.dev/gemini-api/docs/deep-research)
- [Gemini Interactions API](https://ai.google.dev/gemini-api/docs/interactions)

## xAI Grok

- Type: `grok`
- Default URL: `https://api.x.ai/v1`
- Provider API: xAI Chat Completions
- Data: JSON and SSE
- Content: text and tools
- Session header: `x-grok-conv-id`
- Service tier field: `service_tier`

The adapter converts `cost_in_usd_ticks` to a reported USD value. A reported value has priority over a local estimate.

Official references:

- [xAI Chat Completions](https://docs.x.ai/developers/api-reference#chat-completions)
- [xAI cost tracking](https://docs.x.ai/docs/key-information/monitoring-usage)

## OpenAI-compatible provider

- Type: `openai-compatible`
- URL: HTTPS or loopback HTTP
- Protocol: OpenAI Chat Completions

Use this type for a local server or gateway that has the required OpenAI behavior.

Test tool, image, stream, and usage fields for the selected server.

## Anthropic-compatible provider

- Type: `anthropic-compatible`
- URL: HTTPS or loopback HTTP
- Protocol: Anthropic Messages

## Command provider

- Type: `command`
- Starts one explicit program without a shell.
- Writes one canonical JSON request to standard input.
- Sets `SPI_ACCOUNT_SECRET` for the selected account.
- Reads one canonical JSON event from each output line.
- Reads diagnostics from standard error.
- Stops the program after client cancellation.

Example output:

```jsonl
{"type":"start","model":"example"}
{"type":"text-delta","text":"Hello"}
{"type":"usage","usage":{"inputTokens":10,"outputTokens":2}}
{"type":"finish","stopReason":"end_turn"}
```

Configure only programs that you trust. The program uses the permissions of the desktop process user.

## Trusted external module

- Type: `external-module`
- Location: Application user-data `providers` directory
- Export: `createAdapter(options)`
- Cache key: `reloadToken`

The path is restricted, but the module is not sandboxed. It runs in the main process.

Treat the module as installed code. Read [Provider development](PROVIDER_DEVELOPMENT.md).
