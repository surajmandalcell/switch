import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import net from 'node:net';
import { mkdtemp } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHttpServer, writeFrame } from '../../src/infrastructure/http-server.js';
import { SqliteUsageRepository } from '../../src/infrastructure/usage-sqlite.js';
import { MemoryUsageRepository } from '../../src/infrastructure/usage-memory.js';
import { SecretStore } from '../../src/infrastructure/secret-store.js';
import { Logger, redact } from '../../src/infrastructure/logger.js';
import { createDefaultConfig, createProvider } from '../../src/domain/config.js';

async function temp() { return mkdtemp(path.join(os.tmpdir(), 'spi-infra-')); }
async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function serverConfig(overrides = {}) {
  const config = createDefaultConfig();
  config.server = { ...config.server, ...overrides };
  config.providers = [createProvider({ id: 'p', name: 'Provider', type: 'openai', enabled: true, modelGlobs: ['gpt-5', 'gpt-*'] })];
  config.modelAliases = [{ requested: 'smart', target: 'gpt-5' }];
  return config;
}

function proxyFixture() {
  const calls = [];
  return {
    calls,
    async execute(protocol, body, headers, signal) {
      calls.push({ kind: 'execute', protocol, body, headers, signal });
      if (body.fail) throw Object.assign(new Error('failed request'), { code: 'bad_request', status: 422, failures: [{ providerId: 'p', accountId: 'a', error: { code: 'temporary' } }] });
      return { protocol, ok: true };
    },
    async *stream(protocol, body, headers, signal) {
      calls.push({ kind: 'stream', protocol, body, headers, signal });
      if (body.fail) throw Object.assign(new Error('stream failed'), { code: 'upstream_error' });
      yield { data: { delta: 'hello' } };
      yield { data: '[DONE]' };
    },
  };
}

test('HTTP server exposes health, model, token, protocol, and authentication routes', async () => {
  let config = serverConfig({ apiKeySecretRef: 'local-key', corsOrigins: ['https://client.example'] });
  const proxyService = proxyFixture();
  const logs = [];
  const server = await createHttpServer({
    proxyService,
    getConfig: () => config,
    resolveSecret: () => 'secret',
    logger: { error: (...args) => logs.push(args) },
  });
  const health = await server.app.inject({ method: 'GET', url: '/health' });
  assert.equal(health.statusCode, 200);
  assert.equal(health.json().providers, 1);
  const denied = await server.app.inject({ method: 'GET', url: '/v1/models' });
  assert.equal(denied.statusCode, 401);
  const models = await server.app.inject({ method: 'GET', url: '/v1/models', headers: { authorization: 'Bearer secret' } });
  assert.deepEqual(models.json().data.map((item) => item.id), ['gpt-5', 'smart']);
  const count = await server.app.inject({ method: 'POST', url: '/v1/messages/count_tokens', headers: { 'x-api-key': 'secret' }, payload: { messages: [{ content: 'hello world' }] } });
  assert.ok(count.json().input_tokens >= 1);
  for (const [url, protocol] of [['/v1/chat/completions', 'openai-chat'], ['/v1/responses', 'openai-responses'], ['/v1/messages', 'anthropic']]) {
    const response = await server.app.inject({ method: 'POST', url, headers: { authorization: 'Bearer secret' }, payload: { model: 'm' } });
    assert.equal(response.json().protocol, protocol);
  }
  const allowedOrigin = await server.app.inject({ method: 'GET', url: '/health', headers: { origin: 'https://client.example' } });
  assert.equal(allowedOrigin.headers['access-control-allow-origin'], 'https://client.example');
  const blockedOrigin = await server.app.inject({ method: 'GET', url: '/health', headers: { origin: 'https://blocked.example' } });
  assert.ok(blockedOrigin.statusCode >= 400);
  const failed = await server.app.inject({ method: 'POST', url: '/v1/messages', headers: { authorization: 'Bearer secret' }, payload: { fail: true } });
  assert.equal(failed.statusCode, 422);
  assert.equal(failed.json().type, 'error');
  const openAiFailed = await server.app.inject({ method: 'POST', url: '/v1/chat/completions', headers: { authorization: 'Bearer secret' }, payload: { fail: true } });
  assert.equal(openAiFailed.json().error.failures[0].provider_id, 'p');
  assert.ok(logs.length >= 2);
  const port = await freePort();
  config = serverConfig({ port });
  assert.deepEqual(await server.start(), { host: '127.0.0.1', port });
  await server.stop();
  config = serverConfig({ host: '0.0.0.0' });
  await assert.rejects(server.start(), /outside loopback/);
});

test('HTTP streaming returns protocol frames and handles stream errors', async () => {
  const proxyService = proxyFixture();
  const server = await createHttpServer({ proxyService, getConfig: () => serverConfig(), resolveSecret: () => null });
  const streamed = await server.app.inject({ method: 'POST', url: '/v1/chat/completions', payload: { model: 'm', stream: true } });
  assert.match(streamed.body, /hello/);
  assert.match(streamed.body, /\[DONE\]/);
  const failed = await server.app.inject({ method: 'POST', url: '/v1/responses', payload: { model: 'm', stream: true, fail: true } });
  assert.match(failed.body, /response.failed/);
  await server.stop();
});

class WritableFixture extends EventEmitter {
  constructor(result = true) { super(); this.result = result; this.destroyed = false; this.writableEnded = false; this.frames = []; }
  write(frame) { this.frames.push(frame); return this.result; }
}

test('writeFrame handles ended streams, drain, close, and error outcomes', async () => {
  const ended = new WritableFixture();
  ended.writableEnded = true;
  await writeFrame(ended, 'ignored');
  assert.equal(ended.frames.length, 0);
  const direct = new WritableFixture(true);
  await writeFrame(direct, 'one');
  assert.deepEqual(direct.frames, ['one']);
  const draining = new WritableFixture(false);
  const drained = writeFrame(draining, 'two');
  draining.emit('drain');
  await drained;
  const closing = new WritableFixture(false);
  const closed = writeFrame(closing, 'three');
  closing.emit('close');
  await closed;
  const failing = new WritableFixture(false);
  const failed = writeFrame(failing, 'four');
  failing.emit('error', new Error('write failed'));
  await assert.rejects(failed, /write failed/);
});

class StatementFixture {
  constructor(sql, database) { this.sql = sql; this.database = database; }
  run(...args) {
    this.database.runs.push({ sql: this.sql, args });
    if (this.sql.startsWith('DELETE FROM usage_records')) return { changes: 3 };
    return { changes: 1 };
  }
  all(...args) {
    this.database.alls.push({ sql: this.sql, args });
    if (this.sql.includes('FROM route_attempts')) return [{ id: 'attempt' }];
    return [{ id: 'usage', status: 'success', inputTokens: 2, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUsd: 1 }];
  }
  get(...args) {
    this.database.gets.push({ sql: this.sql, args });
    return { value: this.sql.includes('COUNT') ? 2 : this.sql.includes('SUM(input') ? 5 : 1.25 };
  }
}

class DatabaseFixture {
  constructor(filePath) { this.filePath = filePath; this.pragmas = []; this.execs = []; this.prepares = []; this.runs = []; this.alls = []; this.gets = []; DatabaseFixture.last = this; }
  pragma(value) { this.pragmas.push(value); }
  exec(value) { this.execs.push(value); }
  prepare(sql) { this.prepares.push(sql); return new StatementFixture(sql, this); }
  close() { this.closed = true; }
}

test('SQLite repository covers migrations, records, queries, totals, attempts, pruning, and close', async () => {
  const dir = await temp();
  const repository = new SqliteUsageRepository(DatabaseFixture, path.join(dir, 'usage.sqlite'));
  const database = DatabaseFixture.last;
  assert.deepEqual(database.pragmas, ['journal_mode = WAL', 'synchronous = NORMAL']);
  assert.match(database.execs[0], /CREATE TABLE IF NOT EXISTS usage_records/);
  const inserted = repository.insert({ id: 'r' });
  assert.equal(inserted.status, 'success');
  assert.equal(inserted.inputTokens, 0);
  assert.equal(repository.list({}, { limit: 20_000, offset: -5 })[0].id, 'usage');
  assert.equal(repository.summary().requests, 1);
  assert.match(repository.csv(), /usage/);
  assert.equal(repository.requestsSince('a', 0), 2);
  assert.equal(repository.tokensSince('a', 0), 5);
  assert.equal(repository.costSince('a', 0), 1.25);
  assert.deepEqual(repository.insertAttempt({ id: 'x', requestId: 'r', startedAt: 'now', providerId: 'p', accountId: 'a', status: 'success' }), { latencyMs: null, errorCode: null, upstreamModel: null, id: 'x', requestId: 'r', startedAt: 'now', providerId: 'p', accountId: 'a', status: 'success' });
  assert.deepEqual(repository.listAttempts('r'), [{ id: 'attempt' }]);
  assert.equal(repository.prune(30), 3);
  repository.close();
  assert.equal(database.closed, true);
  assert.ok(database.prepares.some((sql) => sql.includes('LIMIT @limit OFFSET @offset')));
});

test('memory repository covers every public operation', () => {
  const repository = new MemoryUsageRepository([
    { id: 'old', accountId: 'a', startedAt: '2000-01-01', inputTokens: 2, outputTokens: 3, estimatedCostUsd: 1 },
    { id: 'new', accountId: 'a', startedAt: new Date().toISOString(), inputTokens: 4, outputTokens: 5, estimatedCostUsd: 2 },
  ]);
  assert.equal(repository.requestsSince('a', 0), 2);
  assert.equal(repository.tokensSince('a', 0), 14);
  assert.equal(repository.costSince('a', 0), 3);
  repository.insertAttempt({ id: 'x', requestId: 'r' });
  repository.insertAttempt({ id: 'y', requestId: 'other' });
  assert.equal(repository.listAttempts().length, 2);
  assert.equal(repository.listAttempts('r').length, 1);
  assert.equal(repository.list({}, { limit: 0 }).length, 0);
});

test('secret and logger error branches are covered', async () => {
  const dir = await temp();
  const store = new SecretStore({ vaultPath: path.join(dir, 'vault'), keyPath: path.join(dir, 'key') });
  store.vault.secrets.bad = { mode: 'unknown' };
  assert.throws(() => store.get('bad'), /Unsupported secret mode/);
  assert.deepEqual(redact([{ token: 'x' }, 'Bearer abc']), [{ token: '[REDACTED]' }, 'Bearer [REDACTED]']);
  const calls = [];
  const logger = new Logger({ sink: { debug: (...args) => calls.push(args) }, capacity: 1 });
  logger.debug('debug', { value: 1 });
  assert.equal(logger.list(0).length, 1);
  assert.equal(calls.length, 1);
});
