# Troubleshooting

## The local server does not start

1. Make sure that another program does not use the port.
2. Change the port in **Settings**.
3. Close old desktop processes.
4. Read the local logs.

Look for `EADDRINUSE` or permission errors.

The app rejects a host other than `127.0.0.1` or `localhost`.

## The router finds no eligible route

Check these items:

- Provider enabled state
- Account enabled state
- Credential state
- Model globs
- Cooldown state
- Attention state
- Request limits
- Token limits
- Cost limits
- Attempt limits

## Authentication fails

The system uses two types of credentials:

- Local proxy key
- Provider account credential

A local `401` can show a missing or incorrect proxy key.

A provider authentication error shows a problem with the selected provider credential.

## Streaming stops after partial output

This behavior is intentional after visible output starts. The gateway does not change providers after text or a tool call.

A route change at that time can duplicate text or tool work.

## Gemini Deep Research waits for a result

Deep Research is a background interaction. The gateway sends SSE comments while it polls the interaction.

Increase `adapter.deepResearch.timeoutMs` for a long report. Make sure that the model ID starts with `deep-research-`.

## A command provider fails

- Use an absolute program path when necessary.
- Read one canonical JSON request from standard input.
- Write one JSON event per output line.
- Write diagnostics to standard error.
- Do not write banners to standard output.

## A native dependency does not build

`better-sqlite3` can require platform build tools. Use Node.js 22 and the supported Electron version.

Delete `node_modules` after a Node.js or Electron version change. Then run `npm ci` again.

## A documentation link fails

```bash
npm run check:links
npm run build:site
```

The project checks source links and generated-site links separately.
