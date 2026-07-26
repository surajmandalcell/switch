# Troubleshooting

## The application cannot start the local server

- Confirm the configured port is not already in use.
- Change the port under **Settings**.
- Verify no stale desktop process is running.
- Check local logs for `EADDRINUSE` or permission errors.

A host other than `127.0.0.1` or `localhost` is intentionally rejected.

## No eligible route

Check:

- Provider and account enablement.
- Credential status.
- Requested model against provider model globs.
- Runtime cooldown or attention state on the dashboard.
- Local request, token, and monthly cost limits.
- Global and provider maximum-attempt settings.

## Authentication failures

There are two separate credentials:

- The local proxy key supplied by your client.
- The encrypted upstream account credential selected by routing.

A local `401` mentioning the proxy key means the first is missing or incorrect. A recorded provider authentication error means the upstream credential needs attention.

## Streaming stops after partial output

This is expected when the selected upstream fails after visible text or a tool call. The gateway will not switch providers after that boundary because doing so could duplicate content or tool execution.

## Gemini Deep Research appears idle

Deep Research is a background interaction. The gateway sends SSE comments as keep-alives while polling. Increase `adapter.deepResearch.timeoutMs` for complex reports and confirm the model ID begins with `deep-research-`.

## Command provider fails

- Use an absolute executable path when the desktop environment has a limited `PATH`.
- Confirm the command reads one canonical JSON request from standard input.
- Emit one JSON event per line on standard output.
- Send diagnostics to standard error.
- Do not emit banners or non-JSON text to standard output.

## Native dependency build errors

`better-sqlite3` may need platform build tools when a prebuilt binary is unavailable. Use Node 22, a supported Electron version, and the platform’s compiler toolchain. Delete `node_modules` and rerun `npm ci` after changing Node or Electron versions.

## Website or documentation link failure

Run:

```bash
npm run check:links
npm run build:site
```

Source links and generated-site links are validated separately.
