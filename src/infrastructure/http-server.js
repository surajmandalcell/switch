import { timingSafeEqual } from 'node:crypto';
import { encodeSse } from '../providers/sse.js';

export async function createHttpServer({ proxyService, getConfig, resolveSecret, logger }) {
  const [{ default: Fastify }, { default: cors }] = await Promise.all([import('fastify'), import('@fastify/cors')]);
  const app = Fastify({ logger: false, bodyLimit: 20 * 1024 * 1024, requestTimeout: 0, disableRequestLogging: true });

  await app.register(cors, {
    origin(origin, callback) {
      const allowed = getConfig().server.corsOrigins;
      if (!origin || allowed.includes(origin)) callback(null, true);
      else callback(new Error('Origin is not allowed.'), false);
    },
    methods: ['GET', 'POST', 'OPTIONS'],
    allowedHeaders: ['content-type', 'authorization', 'x-api-key', 'anthropic-version', 'x-session-id'],
  });

  app.addHook('onRequest', async (request, reply) => {
    const secretRef = getConfig().server.apiKeySecretRef;
    if (!secretRef || request.url === '/health') return;
    const expected = resolveSecret(secretRef);
    const supplied = bearer(request.headers.authorization) ?? request.headers['x-api-key'];
    if (!constantTimeEqual(expected, supplied)) return reply.code(401).send({ error: { type: 'authentication_error', message: 'A valid local proxy key is required.' } });
  });

  app.get('/health', async () => ({ status: 'ok', version: 2, providers: getConfig().providers.filter((provider) => provider.enabled).length }));
  app.get('/v1/models', async () => ({ object: 'list', data: discoverModels(getConfig()).map((id) => ({ id, object: 'model', owned_by: 'subscription-proxy-inator' })) }));

  app.post('/v1/chat/completions', async (request, reply) => handleProtocol('openai-chat', request, reply, proxyService));
  app.post('/v1/responses', async (request, reply) => handleProtocol('openai-responses', request, reply, proxyService));
  app.post('/v1/messages', async (request, reply) => handleProtocol('anthropic', request, reply, proxyService));
  app.post('/v1/messages/count_tokens', async (request) => ({ input_tokens: estimateTokens(request.body) }));

  app.setErrorHandler((error, request, reply) => {
    logger?.error('Proxy request failed', { code: error.code, status: error.status, message: error.message, requestId: request.id });
    if (reply.sent) return;
    const status = Number(error.status ?? 500);
    if (request.url.startsWith('/v1/messages')) reply.code(status).send({ type: 'error', error: { type: error.code ?? 'api_error', message: error.message } });
    else reply.code(status).send({ error: { type: error.code ?? 'api_error', message: error.message, failures: error.failures?.map((failure) => ({ provider_id: failure.providerId, account_id: failure.accountId, code: failure.error.code })) } });
  });

  return {
    app,
    async start() {
      const { host, port } = getConfig().server;
      if (!['127.0.0.1', 'localhost'].includes(host)) throw new Error('Refusing to bind the local proxy outside loopback.');
      await app.listen({ host, port });
      return { host, port };
    },
    async stop() { await app.close(); },
  };
}

async function handleProtocol(protocol, request, reply, proxyService) {
  const abortController = new AbortController();
  const abort = () => {
    if (abortController.signal.aborted) return;
    const error = new Error('Client disconnected');
    error.name = 'AbortError';
    error.code = 'CLIENT_ABORTED';
    abortController.abort(error);
  };
  const onReplyClose = () => { if (!reply.raw.writableEnded) abort(); };
  request.raw.once('aborted', abort);
  reply.raw.once('close', onReplyClose);
  let streaming = false;
  try {
    if (!request.body?.stream) return await proxyService.execute(protocol, request.body ?? {}, request.headers, abortController.signal);
    streaming = true;
    reply.hijack();
    reply.raw.statusCode = 200;
    reply.raw.setHeader('content-type', 'text/event-stream; charset=utf-8');
    reply.raw.setHeader('cache-control', 'no-cache, no-transform');
    reply.raw.setHeader('connection', 'keep-alive');
    reply.raw.flushHeaders?.();
    try {
      for await (const event of proxyService.stream(protocol, request.body ?? {}, request.headers, abortController.signal)) {
        await writeFrame(reply.raw, encodeSse(event));
      }
    } catch (error) {
      if (!abortController.signal.aborted && !reply.raw.destroyed && !reply.raw.writableEnded) {
        for (const frame of streamErrorFrames(protocol, error)) await writeFrame(reply.raw, frame);
      }
    } finally {
      if (!reply.raw.destroyed && !reply.raw.writableEnded) reply.raw.end();
    }
  } finally {
    request.raw.off('aborted', abort);
    reply.raw.off('close', onReplyClose);
    if (!streaming && abortController.signal.aborted) throw abortController.signal.reason;
  }
}

async function writeFrame(stream, frame) {
  if (stream.destroyed || stream.writableEnded) return;
  if (stream.write(frame)) return;
  await new Promise((resolve, reject) => {
    const cleanup = () => { stream.off('drain', onDrain); stream.off('error', onError); stream.off('close', onClose); };
    const onDrain = () => { cleanup(); resolve(); };
    const onError = (error) => { cleanup(); reject(error); };
    const onClose = () => { cleanup(); resolve(); };
    stream.once('drain', onDrain);
    stream.once('error', onError);
    stream.once('close', onClose);
  });
}

function streamErrorFrames(protocol, error) {
  const code = error?.code ?? 'upstream_error';
  const message = error?.message ?? 'The upstream request failed.';
  if (protocol === 'anthropic') return [encodeSse({ event: 'error', data: { type: 'error', error: { type: code, message } } })];
  if (protocol === 'openai-responses') return [encodeSse({ event: 'response.failed', data: { type: 'response.failed', response: { status: 'failed', error: { code, message } } } })];
  return [encodeSse({ data: { error: { type: code, message } } }), encodeSse({ data: '[DONE]' })];
}

function bearer(value) {
  const match = /^Bearer\s+(.+)$/i.exec(String(value ?? ''));
  return match?.[1] ?? null;
}

function constantTimeEqual(expected, supplied) {
  if (typeof expected !== 'string' || typeof supplied !== 'string') return false;
  const left = Buffer.from(expected);
  const right = Buffer.from(supplied);
  return left.length === right.length && timingSafeEqual(left, right);
}

function discoverModels(config) {
  const models = new Set(config.modelAliases.map((entry) => entry.requested));
  for (const provider of config.providers) for (const glob of provider.modelGlobs) if (!/[?*]/.test(glob)) models.add(glob);
  return [...models].sort();
}

function estimateTokens(body) {
  const text = JSON.stringify(body?.messages ?? body?.input ?? body ?? '');
  return Math.max(1, Math.ceil(text.length / 4));
}

export { bearer, constantTimeEqual, discoverModels, estimateTokens, streamErrorFrames, writeFrame };
