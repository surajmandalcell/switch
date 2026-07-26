import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createAccount, createDefaultConfig, createProvider, normalizeConfig, publicConfig,
  replaceProviderOverrides, resolveModelAlias, sanitizeHeaders, validateConfig,
} from '../../src/domain/config.js';

test('default config is loopback-only and valid', () => {
  const config = createDefaultConfig();
  assert.equal(config.server.host, '127.0.0.1');
  assert.equal(validateConfig(config), config);
});

test('provider defaults are useful and independent', () => {
  const first = createProvider({ name: 'A' });
  const second = createProvider({ name: 'B' });
  assert.notEqual(first.id, second.id);
  assert.deepEqual(first.modelGlobs, ['*']);
  first.modelGlobs.push('x');
  assert.deepEqual(second.modelGlobs, ['*']);
});

test('account coerces priority and positive weight', () => {
  const account = createAccount({ priority: '4', weight: '2.5' });
  assert.equal(account.priority, 4);
  assert.equal(account.weight, 2.5);
  assert.equal(createAccount({ weight: 0 }).weight, 1);
});

test('account normalizes local limits', () => {
  const account = createAccount({ limits: { requestsPerMinute: '12', tokensPerDay: '', tokensPerMonth: -1, costPerMonthUsd: '9.5' } });
  assert.equal(account.limits.requestsPerMinute, 12);
  assert.equal(account.limits.tokensPerDay, null);
  assert.equal(account.limits.tokensPerMonth, null);
  assert.equal(account.limits.costPerMonthUsd, 9.5);
});

test('sensitive provider headers are discarded', () => {
  assert.deepEqual(sanitizeHeaders({ 'X-Trace': 4, Authorization: 'secret', 'x-api-key': 'secret', Cookie: 'x' }), { 'X-Trace': '4' });
});

test('normalization merges nested defaults', () => {
  const config = normalizeConfig({ server: { port: 9000 }, routing: { strategy: 'sticky' } });
  assert.equal(config.server.port, 9000);
  assert.equal(config.server.host, '127.0.0.1');
  assert.equal(config.routing.strategy, 'sticky');
  assert.equal(config.routing.maxAttempts, 4);
});

test('validation rejects non-loopback binding', () => {
  const config = createDefaultConfig();
  config.server.host = '0.0.0.0';
  assert.throws(() => validateConfig(config), /loopback/);
});

test('validation rejects unsafe ports', () => {
  for (const port of [0, 80, 65536, 1.5]) {
    const config = createDefaultConfig();
    config.server.port = port;
    assert.throws(() => validateConfig(config), /port/);
  }
});

test('validation rejects unknown strategies', () => {
  const config = createDefaultConfig();
  config.routing.strategy = 'chaos';
  assert.throws(() => validateConfig(config), /strategy/);
});

test('validation rejects duplicate provider ids', () => {
  const provider = createProvider({ id: 'same' });
  const config = { ...createDefaultConfig(), providers: [provider, { ...provider }] };
  assert.throws(() => validateConfig(config), /Duplicate provider/);
});

test('validation rejects duplicate account ids across providers', () => {
  const account = createAccount({ id: 'same-account' });
  const config = { ...createDefaultConfig(), providers: [createProvider({ id: 'one', accounts: [account] }), createProvider({ id: 'two', accounts: [account] })] };
  assert.throws(() => validateConfig(config), /Duplicate account/);
});

test('validation rejects aliases referencing a missing provider', () => {
  const config = { ...createDefaultConfig(), modelAliases: [{ requested: 'a', target: 'b', providerId: 'missing' }] };
  assert.throws(() => validateConfig(config), /missing provider/);
});

test('public config redacts secret references', () => {
  const config = normalizeConfig({ server: { apiKeySecretRef: 'local' }, providers: [{ id: 'p', name: 'P', type: 'openai', accounts: [{ id: 'a', label: 'A', secretRef: 'credential' }] }] });
  const copy = publicConfig(config);
  assert.equal(copy.server.hasApiKey, true);
  assert.equal('apiKeySecretRef' in copy.server, false);
  assert.equal(copy.providers[0].accounts[0].hasSecret, true);
  assert.equal('secretRef' in copy.providers[0].accounts[0], false);
  assert.equal(config.providers[0].accounts[0].secretRef, 'credential');
});

test('replaceProviderOverrides updates global strategy and clears overrides', () => {
  const config = normalizeConfig({ providers: [{ id: 'p', name: 'P', type: 'openai', strategyOverride: 'sticky' }] });
  const next = replaceProviderOverrides(config, 'round-robin');
  assert.equal(next.routing.strategy, 'round-robin');
  assert.equal(next.providers[0].strategyOverride, null);
  assert.equal(next.revision, config.revision + 1);
});

test('model alias resolution prefers provider-specific mappings', () => {
  const config = normalizeConfig({ providers: [{ id: 'p', name: 'P', type: 'openai' }], modelAliases: [{ requested: 'smart', target: 'global' }, { requested: 'smart', target: 'provider', providerId: 'p' }] });
  assert.equal(resolveModelAlias(config, 'smart', 'p'), 'provider');
  assert.equal(resolveModelAlias(config, 'smart', 'other'), 'global');
  assert.equal(resolveModelAlias(config, 'raw', 'p'), 'raw');
});

test('validation rejects insecure remote provider URLs and malformed browser origins', () => {
  assert.throws(() => normalizeConfig({ ...createDefaultConfig(), providers: [{ id: 'p', name: 'Remote', type: 'openai-compatible', baseUrl: 'http://api.example.test/v1', modelGlobs: ['*'], accounts: [] }] }), /HTTPS/);
  assert.doesNotThrow(() => normalizeConfig({ ...createDefaultConfig(), providers: [{ id: 'p', name: 'Local', type: 'openai-compatible', baseUrl: 'http://127.0.0.1:9999/v1', modelGlobs: ['*'], accounts: [] }] }));
  assert.throws(() => normalizeConfig({ ...createDefaultConfig(), server: { ...createDefaultConfig().server, corsOrigins: ['https://*.example.com'] } }), /exact URLs/);
  assert.throws(() => normalizeConfig({ ...createDefaultConfig(), server: { ...createDefaultConfig().server, corsOrigins: ['not a url'] } }), /Invalid CORS/);
});

test('validation rejects duplicate aliases and invalid pricing records', () => {
  const base = { ...createDefaultConfig(), providers: [{ id: 'p', name: 'Provider', type: 'openai', baseUrl: 'https://api.openai.com/v1', modelGlobs: ['gpt-*'], accounts: [] }] };
  assert.throws(() => normalizeConfig({ ...base, modelAliases: [{ requested: 'fast', target: 'a' }, { requested: 'fast', target: 'b' }] }), /Duplicate model alias/);
  assert.throws(() => normalizeConfig({ ...base, pricing: [{ id: 'x', providerId: 'missing', modelGlob: '*', inputPerMillionUsd: 1 }] }), /missing provider/);
  assert.throws(() => normalizeConfig({ ...base, pricing: [{ id: 'x', modelGlob: '*', inputPerMillionUsd: -1 }] }), /non-negative/);
  assert.throws(() => normalizeConfig({ ...base, pricing: [{ id: 'x', modelGlob: '*', sourceUrl: 'http://prices.example.com' }] }), /HTTPS/);
});

test('validation bounds retention and provider attempts', () => {
  assert.throws(() => normalizeConfig({ ...createDefaultConfig(), retentionDays: 0 }), /Retention/);
  assert.throws(() => normalizeConfig({ ...createDefaultConfig(), providers: [{ id: 'p', name: 'Provider', type: 'openai', baseUrl: 'https://api.openai.com/v1', modelGlobs: ['gpt-*'], maxAttempts: 21, accounts: [] }] }), /maxAttempts/);
});
