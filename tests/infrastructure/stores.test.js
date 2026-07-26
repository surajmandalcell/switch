import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { ConfigStore } from '../../src/infrastructure/config-store.js';
import { SecretStore } from '../../src/infrastructure/secret-store.js';
import { MemoryUsageRepository } from '../../src/infrastructure/usage-memory.js';
import { Logger, redact } from '../../src/infrastructure/logger.js';
import { buildWhere } from '../../src/infrastructure/usage-sqlite.js';
import { bearer, constantTimeEqual, discoverModels, estimateTokens } from '../../src/infrastructure/http-server.js';
import { createDefaultConfig, createProvider } from '../../src/domain/config.js';

async function temp() { return mkdtemp(path.join(os.tmpdir(), 'spi-test-')); }

test('config store creates a default file atomically', async () => {
  const dir = await temp(); const file = path.join(dir, 'config.json'); const store = new ConfigStore(file); const config = await store.load();
  assert.equal(config.schemaVersion, 2); assert.equal(JSON.parse(await readFile(file, 'utf8')).server.host, '127.0.0.1');
});
test('config store loads existing configuration', async () => {
  const dir = await temp(); const file = path.join(dir, 'config.json'); await writeFile(file, JSON.stringify({ ...createDefaultConfig(), server: { ...createDefaultConfig().server, port: 9000 } }));
  const store = new ConfigStore(file); assert.equal((await store.load()).server.port, 9000);
});
test('config updates are serialized and revisions increase', async () => {
  const dir = await temp(); const store = new ConfigStore(path.join(dir, 'config.json')); await store.load();
  await Promise.all([store.update(async (config) => { await new Promise((resolve) => setTimeout(resolve, 20)); config.retentionDays += 1; return config; }), store.update((config) => { config.retentionDays += 1; return config; })]);
  assert.equal(store.get().retentionDays, 92); assert.equal(store.get().revision, 2);
});
test('config save validates configuration', async () => {
  const dir = await temp(); const store = new ConfigStore(path.join(dir, 'config.json')); const config = createDefaultConfig(); config.server.host = '0.0.0.0'; await assert.rejects(store.save(config), /loopback/);
});

test('AES secret store encrypts and survives restart', async () => {
  const dir = await temp(); const options = { vaultPath: path.join(dir, 'vault.json'), keyPath: path.join(dir, 'key') };
  const first = new SecretStore(options); await first.load(); const ref = await first.set('top-secret');
  assert.equal(first.get(ref), 'top-secret'); assert.doesNotMatch(await readFile(options.vaultPath, 'utf8'), /top-secret/);
  const second = new SecretStore(options); await second.load(); assert.equal(second.get(ref), 'top-secret'); assert.equal((await stat(options.keyPath)).mode & 0o777, 0o600);
});
test('secret store can replace and delete a reference', async () => {
  const dir = await temp(); const store = new SecretStore({ vaultPath: path.join(dir, 'v'), keyPath: path.join(dir, 'k') }); await store.load();
  const ref = await store.set('one', 'fixed'); await store.set('two', ref); assert.equal(store.get(ref), 'two'); assert.equal(await store.delete(ref), true); assert.equal(store.get(ref), null); assert.equal(await store.delete(ref), false);
});
test('safeStorage mode is used when available', async () => {
  const safeStorage = { isEncryptionAvailable: () => true, encryptString: (value) => Buffer.from(value).map((x) => x ^ 1), decryptString: (buffer) => Buffer.from(buffer).map((x) => x ^ 1).toString() };
  const dir = await temp(); const store = new SecretStore({ vaultPath: path.join(dir, 'v'), keyPath: path.join(dir, 'k'), safeStorage }); await store.load(); const ref = await store.set('safe'); assert.equal(store.get(ref), 'safe'); assert.equal(store.vault.secrets[ref].mode, 'safe-storage');
});
test('secret references are listed deterministically', async () => {
  const dir = await temp(); const store = new SecretStore({ vaultPath: path.join(dir, 'v'), keyPath: path.join(dir, 'k') }); await store.load(); await store.set('x', 'z'); await store.set('x', 'a'); assert.deepEqual(store.listRefs(), ['a','z']);
});

test('memory usage repository inserts, sorts, paginates, summarizes, and exports', () => {
  const repo = new MemoryUsageRepository(); repo.insert({ id: 'a', startedAt: '2026-01-01', status: 'success' }); repo.insert({ id: 'b', startedAt: '2026-01-02', status: 'error' });
  assert.deepEqual(repo.list({}, { offset: 0, limit: 1 }).map((r) => r.id), ['b']); assert.equal(repo.summary().requests, 2); assert.match(repo.csv({ status: 'error' }), /"b"/);
});
test('memory usage repository generates ids and prunes old records', () => {
  const repo = new MemoryUsageRepository(); const generated = repo.insert({ status: 'success' }); assert.match(generated.id, /^usage_/); repo.insert({ id: 'old', startedAt: '2000-01-01', status: 'success' }); assert.equal(repo.prune(1), 1);
});

test('redaction handles nested keys and bearer strings', () => {
  assert.deepEqual(redact({ Authorization: 'x', nested: { apiKey: 'y', message: 'Bearer abc.def' } }), { Authorization: '[REDACTED]', nested: { apiKey: '[REDACTED]', message: 'Bearer [REDACTED]' } });
});
test('logger maintains bounded history and subscriptions', () => {
  const seen = []; const sink = { info() {}, warn() {}, error() {}, debug() {} }; const logger = new Logger({ sink, capacity: 2 }); const off = logger.subscribe((entry) => seen.push(entry)); logger.info('a'); logger.warn('b'); off(); logger.error('c'); assert.deepEqual(logger.list().map((e) => e.message), ['b','c']); assert.equal(seen.length, 2);
});

test('SQLite where builder uses parameters for every filter', () => {
  const { where, params } = buildWhere({ status: 'success', protocol: 'anthropic', providerId: 'p', accountId: 'a', from: 'x', to: 'y' });
  assert.match(where, /status = @status/); assert.match(where, /started_at <= @to/); assert.deepEqual(params, { status: 'success', protocol: 'anthropic', providerId: 'p', accountId: 'a', from: 'x', to: 'y' });
});
test('SQLite where builder handles no filters', () => assert.deepEqual(buildWhere({}), { where: '', params: {} }));

test('HTTP bearer parsing is strict', () => { assert.equal(bearer('Bearer secret'), 'secret'); assert.equal(bearer('basic secret'), null); });
test('constant time string comparison handles missing and unequal values', () => { assert.equal(constantTimeEqual('a','a'), true); assert.equal(constantTimeEqual('a','b'), false); assert.equal(constantTimeEqual('a','aa'), false); assert.equal(constantTimeEqual(null,'a'), false); });
test('model discovery includes aliases and exact provider model ids only', () => {
  const config = createDefaultConfig(); config.modelAliases = [{ requested: 'smart', target: 'x' }]; config.providers = [createProvider({ name: 'P', type: 'openai', modelGlobs: ['gpt-*','gpt-5'] })]; assert.deepEqual(discoverModels(config), ['gpt-5','smart']);
});
test('token estimation is positive and size-sensitive', () => { assert.ok(estimateTokens({ messages: [{ content: 'a'.repeat(100) }] }) > estimateTokens({ messages: [{ content: 'a' }] })); });

import { streamErrorFrames } from '../../src/infrastructure/http-server.js';

test('streaming protocol errors use native wire envelopes', () => {
  const error = Object.assign(new Error('failed'), { code: 'rate_limited' });
  assert.match(streamErrorFrames('anthropic', error)[0], /event: error/);
  assert.match(streamErrorFrames('openai-responses', error)[0], /event: response.failed/);
  const chat = streamErrorFrames('openai-chat', error);
  assert.match(chat[0], /rate_limited/);
  assert.match(chat[1], /\[DONE\]/);
});
