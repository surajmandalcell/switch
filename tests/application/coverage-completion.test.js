import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderConfigurationService } from '../../src/application/provider-configuration-service.js';
import { ProxyService } from '../../src/application/proxy-service.js';
import { SettingsService, serverEndpointChanged } from '../../src/application/settings-service.js';
import { UsageService, estimateCanonicalInputTokens } from '../../src/application/usage-service.js';
import { createAccount, createDefaultConfig, createProvider, normalizeConfig } from '../../src/domain/config.js';
import { canonicalResponse, streamEvent } from '../../src/domain/protocol/canonical.js';

function configStoreFixture() {
  let config = normalizeConfig({
    ...createDefaultConfig(),
    providers: [createProvider({
      id: 'p',
      name: 'Provider',
      type: 'openai',
      accounts: [createAccount({ id: 'a', label: 'Primary', secretRef: 'old' })],
    })],
  });
  return {
    get: () => structuredClone(config),
    async update(mutator) {
      config = normalizeConfig({ ...await mutator(structuredClone(config)), revision: config.revision + 1 });
      return structuredClone(config);
    },
    async save(value) { config = structuredClone(value); return structuredClone(config); },
  };
}

function secretStoreFixture() {
  const values = new Map([['old', 'old-secret']]);
  const deleted = [];
  let count = 0;
  return {
    values,
    deleted,
    async set(value, ref) {
      const next = ref ?? `new-${++count}`;
      values.set(next, value);
      return next;
    },
    async delete(ref) { deleted.push(ref); return values.delete(ref); },
  };
}

test('provider configuration covers provider and account success paths', async () => {
  const configStore = configStoreFixture();
  const secretStore = secretStoreFixture();
  const cleared = [];
  const service = new ProviderConfigurationService({ configStore, secretStore, runtime: { clear: (id) => cleared.push(id) } });
  const addedProvider = await service.addProvider({ id: 'p2', name: 'Second', type: 'anthropic' });
  assert.equal(addedProvider.providers.at(-1).id, 'p2');
  const addedAccount = await service.addAccount('p2', { id: 'a2', label: 'No secret' });
  assert.equal(addedAccount.providers.at(-1).accounts[0].hasSecret, false);
  const removed = await service.removeAccount('p', 'a');
  assert.equal(removed.providers[0].accounts.length, 0);
  assert.deepEqual(cleared, ['a']);
  assert.deepEqual(secretStore.deleted, ['old']);
});

test('account update failure removes only the new secret', async () => {
  const configStore = configStoreFixture();
  const secretStore = secretStoreFixture();
  const service = new ProviderConfigurationService({ configStore, secretStore });
  configStore.update = async () => { throw new Error('commit failed'); };
  await assert.rejects(service.updateAccount('p', 'a', { secret: 'replacement' }), /commit failed/);
  assert.equal(secretStore.values.has('old'), true);
  assert.equal(secretStore.values.size, 1);
  assert.equal(secretStore.deleted.length, 1);
});

function proxyFixture(routing, records = []) {
  return new ProxyService({
    routing,
    getConfig: () => ({ providers: [], pricing: [] }),
    resolveSecret: () => null,
    usageService: { estimateRouteCosts: () => ({}), record: (value) => records.push(value) },
    clock: (() => { let value = 0; return () => value += 5; })(),
  });
}

test('proxy normalizes every client protocol and rejects unknown protocols', () => {
  const service = proxyFixture({});
  assert.equal(service.normalize('openai-responses', { model: 'm', input: 'hello' }).model, 'm');
  assert.equal(service.normalize('anthropic', { model: 'm', messages: [{ role: 'user', content: 'hello' }] }).messages[0].role, 'user');
  assert.throws(() => service.normalize('unknown', {}), (error) => error.code === 'unsupported_protocol' && error.status === 404);
});

test('proxy streams Responses and Anthropic events and records failed route metadata', async () => {
  const candidate = { provider: { id: 'p' }, account: { id: 'a' } };
  const records = [];
  const routing = {
    async *stream(request, context) {
      context.observer.attemptFailed({ candidate, upstreamRequest: { ...request, model: 'upstream' } });
      yield streamEvent('start', { model: 'upstream' });
      yield streamEvent('text-delta', { text: 'hello' });
      yield streamEvent('finish', { stopReason: 'end_turn' });
    },
  };
  const responses = [];
  for await (const event of proxyFixture(routing, records).stream('openai-responses', { model: 'm', input: 'hello', stream: true })) responses.push(event);
  assert.equal(responses[0].event, 'response.created');
  assert.equal(records[0].providerId, 'p');
  assert.equal(records[0].upstreamModel, 'upstream');
  const anthropic = [];
  for await (const event of proxyFixture(routing, records).stream('anthropic', { model: 'm', messages: [{ role: 'user', content: 'hello' }], stream: true })) anthropic.push(event);
  assert.equal(anthropic[0].event, 'message_start');
});

test('proxy execution serializes Responses and Anthropic results', async () => {
  const candidate = { provider: { id: 'p' }, account: { id: 'a' } };
  const routing = { execute: async () => ({ candidate, response: canonicalResponse({ model: 'm', content: 'ok' }) }) };
  const service = proxyFixture(routing);
  assert.equal((await service.execute('openai-responses', { model: 'm', input: 'hello' })).object, 'response');
  assert.equal((await service.execute('anthropic', { model: 'm', messages: [{ role: 'user', content: 'hello' }] })).type, 'message');
});

test('settings replace and API-key rollback paths are transactional', async () => {
  const configStore = configStoreFixture();
  const secretStore = secretStoreFixture();
  const service = new SettingsService({ configStore, secretStore });
  const replacement = createDefaultConfig();
  replacement.appearance.theme = 'light';
  assert.equal((await service.replace(replacement)).appearance.theme, 'light');
  configStore.update = async () => { throw new Error('config failed'); };
  await assert.rejects(service.setApiKey('new-key'), /config failed/);
  assert.equal(secretStore.deleted.length, 1);
});

test('usage cost estimation, attempts, and token estimation cover optional paths', () => {
  const config = createDefaultConfig();
  config.providers = [
    createProvider({ id: 'p1', name: 'One', type: 'openai' }),
    createProvider({ id: 'p2', name: 'Two', type: 'anthropic' }),
  ];
  config.modelAliases = [{ requested: 'smart', target: 'real', providerId: 'p1' }];
  config.pricing = [{ providerId: 'p1', modelGlob: 'real', inputPerMillionUsd: 1, outputPerMillionUsd: 2 }];
  const repository = { list: () => [], insert: (value) => value, prune: () => 0 };
  const service = new UsageService(repository, () => config);
  const costs = service.estimateRouteCosts({ model: 'smart', messages: [{ role: 'user', content: 'hello' }], maxOutputTokens: 10 });
  assert.ok(costs.p1 > 0);
  assert.equal(costs.p2, 0);
  assert.deepEqual(service.attempts('r'), []);
  assert.ok(estimateCanonicalInputTokens({}) >= 1);
});

test('usage record precedence and repository method branches are explicit', () => {
  const config = createDefaultConfig();
  config.providers = [createProvider({ id: 'p', type: 'openai', name: 'P' })];
  config.pricing = [{ providerId: 'p', modelGlob: 'm', inputPerMillionUsd: 1 }];
  const repository = {
    insert: (value) => value,
    list: () => [{ id: 'r', status: 'success' }],
    summary: () => ({ requests: 7 }),
    csv: () => 'csv',
    listAttempts: () => [{ id: 'a' }],
    prune: () => 2,
  };
  const service = new UsageService(repository, () => config);
  assert.equal(service.record({ providerId: 'p', upstreamModel: 'm', inputTokens: 10, reportedCostUsd: 5 }).estimatedCostUsd, 5);
  assert.equal(service.record({ providerId: 'p', upstreamModel: 'm', inputTokens: 10, estimatedCostUsd: 4 }).estimatedCostUsd, 4);
  assert.ok(service.record({ providerId: 'p', upstreamModel: 'm', inputTokens: 10 }).estimatedCostUsd > 0);
  assert.equal(service.record({ providerId: 'missing', requestedModel: 'unknown' }).pricingKnown, false);
  assert.deepEqual(service.list({}, { limit: 1 }), [{ id: 'r', status: 'success' }]);
  assert.deepEqual(service.summary(), { requests: 7 });
  assert.equal(service.csv(), 'csv');
  assert.deepEqual(service.attempts('r'), [{ id: 'a' }]);
  assert.equal(service.prune(3), 2);
});

test('settings service covers restart, login, rollback, clear, and key branches', async () => {
  const configStore = configStoreFixture();
  const secretStore = secretStoreFixture();
  const restarts = [];
  const login = [];
  const service = new SettingsService({
    configStore,
    secretStore,
    restartServer: async () => { restarts.push('restart'); },
    setLoginItem: (value) => login.push(value),
  });
  await service.updatePatch({ server: { port: 9000, startOnLogin: true }, appearance: { theme: 'light' } });
  assert.equal(restarts.length, 1);
  assert.deepEqual(login, [true]);
  assert.equal((await service.setApiKey('same-ref')).server.hasApiKey, true);
  assert.equal(secretStore.values.get('new-1'), 'same-ref');
  assert.equal((await service.setApiKey('')).server.hasApiKey, undefined);
  assert.equal(secretStore.deleted.includes('new-1'), true);
  assert.equal(serverEndpointChanged(createDefaultConfig(), createDefaultConfig()), false);
  const changed = createDefaultConfig();
  changed.server.host = 'localhost';
  assert.equal(serverEndpointChanged(createDefaultConfig(), changed), true);
  const rollbackStore = configStoreFixture();
  const rollbackRestarts = [];
  const rollback = new SettingsService({
    configStore: rollbackStore,
    secretStore,
    restartServer: async () => { rollbackRestarts.push('try'); if (rollbackRestarts.length === 1) throw new Error('restart failed'); },
    setLoginItem: (value) => login.push(value),
  });
  await assert.rejects(rollback.updatePatch({ server: { port: 9001, startOnLogin: true } }), /restart failed/);
  assert.equal(rollbackStore.get().server.port, 8081);
  assert.equal(rollbackRestarts.length, 2);
});

test('provider configuration covers secret success, updates, removals, and missing records', async () => {
  const configStore = configStoreFixture();
  const secretStore = secretStoreFixture();
  const cleared = [];
  const service = new ProviderConfigurationService({ configStore, secretStore, runtime: { clear: (id) => cleared.push(id) } });
  await service.addAccount('p', { id: 'secret-account', label: 'Secret', secret: 'new-secret' });
  assert.equal(configStore.get().providers[0].accounts.at(-1).secretRef, 'new-1');
  await service.updateProvider('p', { name: 'Changed', accounts: [] });
  assert.equal(configStore.get().providers[0].name, 'Changed');
  await service.updateAccount('p', 'a', { label: 'Updated' });
  assert.equal(configStore.get().providers[0].accounts[0].label, 'Updated');
  await service.updateAccount('p', 'a', { secret: 'replacement' });
  assert.equal(secretStore.deleted.includes('old'), true);
  await service.removeProvider('p');
  assert.ok(cleared.includes('a'));
  assert.throws(() => service.findProvider('missing'), /does not exist/);
  assert.throws(() => service.findAccount('p2', 'missing'), /does not exist/);
});
