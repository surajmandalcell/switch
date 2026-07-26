import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderRegistry } from '../../src/application/provider-registry.js';
import { RuntimeState } from '../../src/application/runtime-state.js';
import { RoutingService } from '../../src/application/routing-service.js';
import { UsageService } from '../../src/application/usage-service.js';
import { MemoryUsageRepository } from '../../src/infrastructure/usage-memory.js';
import { createDefaultConfig, createProvider, createAccount } from '../../src/domain/config.js';
import { canonicalResponse, streamEvent } from '../../src/domain/protocol/canonical.js';

const adapter = (type, methods = {}) => ({
  type,
  execute: methods.execute ?? (async (request) => canonicalResponse({ model: request.model, content: 'ok' })),
  stream: methods.stream ?? (async function* (request) { yield streamEvent('start', { model: request.model }); yield streamEvent('text-delta', { text: 'ok' }); yield streamEvent('finish', { stopReason: 'end_turn' }); }),
});

test('provider registry registers and lists adapters', () => {
  const registry = new ProviderRegistry([adapter('z'), adapter('a')]);
  assert.deepEqual(registry.list(), ['a','z']); assert.equal(registry.get('a').type, 'a'); assert.equal(registry.has('x'), false);
});
test('provider registry rejects malformed and duplicate adapters', () => {
  assert.throws(() => new ProviderRegistry([{}]), /type/);
  assert.throws(() => new ProviderRegistry([{ type: 'x', execute() {} }]), /stream/);
  const registry = new ProviderRegistry([adapter('x')]); assert.throws(() => registry.register(adapter('x')), /already/);
});
test('provider registry can intentionally replace an adapter', () => {
  const registry = new ProviderRegistry([adapter('x')]); const replacement = adapter('x', { execute: async () => 'new' }); registry.replace(replacement); assert.equal(registry.get('x'), replacement);
});
test('missing provider adapter is explicit', () => assert.throws(() => new ProviderRegistry().get('missing'), /No adapter/));

test('runtime state tracks in-flight, success, EWMA, cooldown, and attention', () => {
  const state = new RuntimeState();
  state.begin('a'); assert.equal(state.get('a').inflight, 1);
  state.succeed('a', 100); assert.equal(state.get('a').latencyEwmaMs, 100); assert.equal(state.get('a').inflight, 0);
  state.begin('a'); state.succeed('a', 200); assert.equal(state.get('a').latencyEwmaMs, 125);
  state.begin('a'); state.fail('a', { cooldownMs: 50, attention: true, code: 'auth' }, 1000);
  assert.equal(state.get('a').cooldownUntil, 1050); assert.equal(state.get('a').attention, true); assert.equal(state.get('a').lastErrorCode, 'auth');
});
test('runtime cancellation only decrements in-flight', () => {
  const state = new RuntimeState(); state.begin('a'); state.cancel('a'); const value = state.get('a'); assert.equal(value.inflight, 0); assert.equal(value.failures, 0);
});
test('runtime snapshots are detached', () => {
  const state = new RuntimeState(); state.begin('a'); const snapshot = state.snapshot(); snapshot.get('a').inflight = 99; assert.equal(state.get('a').inflight, 1);
});
test('runtime clear operations remove health state', () => {
  const state = new RuntimeState(); state.begin('a'); state.clear('a'); assert.equal(state.get('a').inflight, 0); state.begin('b'); state.clearAll(); assert.equal(state.snapshot().size, 0);
});

function configFor(types = ['first','second']) {
  const config = createDefaultConfig(); config.routing.maxAttempts = 4;
  config.providers = types.map((type, index) => createProvider({ id: `p${index}`, name: type, type, accounts: [createAccount({ id: `a${index}`, priority: index })] }));
  return config;
}
function context(config, signal) { return { config, signal, resolveSecret: () => 'secret', logger: null }; }

test('routing service returns the first successful route', async () => {
  const service = new RoutingService({ registry: new ProviderRegistry([adapter('first'), adapter('second')]), runtime: new RuntimeState(), usage: {} });
  const result = await service.execute({ model: 'm' }, context(configFor()));
  assert.equal(result.candidate.provider.type, 'first'); assert.equal(result.response.content[0].text, 'ok'); assert.equal(result.failures.length, 0);
});
test('routing service fails over after retryable errors', async () => {
  const first = adapter('first', { execute: async () => { throw Object.assign(new Error('rate limit'), { status: 429 }); } });
  const second = adapter('second');
  const runtime = new RuntimeState();
  const service = new RoutingService({ registry: new ProviderRegistry([first, second]), runtime, usage: {} });
  const result = await service.execute({ model: 'm' }, context(configFor()));
  assert.equal(result.candidate.provider.type, 'second'); assert.equal(result.failures[0].error.code, 'rate_limited'); assert.ok(runtime.get('a0').cooldownUntil > Date.now());
});
test('routing service stops on non-retryable errors', async () => {
  let secondCalls = 0;
  const service = new RoutingService({ registry: new ProviderRegistry([adapter('first', { execute: async () => { throw Object.assign(new Error('bad'), { status: 400 }); } }), adapter('second', { execute: async () => { secondCalls++; } })]), runtime: new RuntimeState(), usage: {} });
  await assert.rejects(service.execute({ model: 'm' }, context(configFor())), /bad/); assert.equal(secondCalls, 0);
});
test('routing service does not retry client cancellation', async () => {
  let secondCalls = 0;
  const service = new RoutingService({ registry: new ProviderRegistry([adapter('first', { execute: async () => { throw Object.assign(new Error('cancel'), { name: 'AbortError' }); } }), adapter('second', { execute: async () => { secondCalls++; } })]), runtime: new RuntimeState(), usage: {} });
  await assert.rejects(service.execute({ model: 'm' }, context(configFor())), (error) => error.code === 'client_cancelled'); assert.equal(secondCalls, 0);
});
test('routing service exposes no-route failures', async () => {
  const config = configFor(['first']); config.providers[0].enabled = false;
  const service = new RoutingService({ registry: new ProviderRegistry([adapter('first')]), runtime: new RuntimeState(), usage: {} });
  await assert.rejects(service.execute({ model: 'm' }, context(config)), (error) => error.code === 'no_route');
});
test('routing hooks receive attempt lifecycle events', async () => {
  const calls = [];
  const service = new RoutingService({ registry: new ProviderRegistry([adapter('first')]), runtime: new RuntimeState(), usage: {}, hooks: { attemptStarted: () => calls.push('start'), attemptSucceeded: () => calls.push('success') } });
  await service.execute({ model: 'm' }, context(configFor(['first']))); assert.deepEqual(calls, ['start','success']);
});

test('streaming fails over before client-visible output', async () => {
  const first = adapter('first', { stream: async function* () { yield streamEvent('start'); yield streamEvent('usage', { usage: {} }); throw Object.assign(new Error('overloaded'), { status: 503 }); } });
  const second = adapter('second', { stream: async function* () { yield streamEvent('start'); yield streamEvent('text-delta', { text: 'second' }); yield streamEvent('finish', { stopReason: 'end_turn' }); } });
  const service = new RoutingService({ registry: new ProviderRegistry([first, second]), runtime: new RuntimeState(), usage: {} });
  const events = []; for await (const event of service.stream({ model: 'm' }, context(configFor()))) events.push(event);
  assert.deepEqual(events.map((event) => event.type), ['start','text-delta','finish']); assert.equal(events[1].text, 'second');
});
test('streaming never fails over after visible text', async () => {
  let secondCalls = 0;
  const first = adapter('first', { stream: async function* () { yield streamEvent('start'); yield streamEvent('text-delta', { text: 'visible' }); throw Object.assign(new Error('late'), { status: 503 }); } });
  const second = adapter('second', { stream: async function* () { secondCalls++; yield streamEvent('text-delta', { text: 'duplicate' }); } });
  const service = new RoutingService({ registry: new ProviderRegistry([first, second]), runtime: new RuntimeState(), usage: {} });
  const events = [];
  await assert.rejects(async () => { for await (const event of service.stream({ model: 'm' }, context(configFor()))) events.push(event); }, /late/);
  assert.equal(events[1].text, 'visible'); assert.equal(secondCalls, 0);
});
test('tool calls are client-visible failover boundaries', async () => {
  let secondCalls = 0;
  const first = adapter('first', { stream: async function* () { yield streamEvent('tool-call', { id: 'c', name: 'f' }); throw Object.assign(new Error('late'), { status: 503 }); } });
  const second = adapter('second', { stream: async function* () { secondCalls++; } });
  const service = new RoutingService({ registry: new ProviderRegistry([first, second]), runtime: new RuntimeState(), usage: {} });
  await assert.rejects(async () => { for await (const _ of service.stream({ model: 'm' }, context(configFor()))) void _; }); assert.equal(secondCalls, 0);
});
test('non-visible completed streams flush buffered metadata', async () => {
  const only = adapter('first', { stream: async function* () { yield streamEvent('start'); yield streamEvent('usage', { usage: { inputTokens: 1 } }); yield streamEvent('finish', { stopReason: 'end_turn' }); } });
  const service = new RoutingService({ registry: new ProviderRegistry([only]), runtime: new RuntimeState(), usage: {} });
  const events = []; for await (const event of service.stream({ model: 'm' }, context(configFor(['first'])))) events.push(event);
  assert.deepEqual(events.map((event) => event.type), ['start','usage','finish']);
});

test('usage service applies pricing and stores records', () => {
  const repository = new MemoryUsageRepository();
  const config = createDefaultConfig(); config.providers = [createProvider({ id: 'p', name: 'P', type: 'openai' })]; config.pricing = [{ providerId: 'p', modelGlob: 'm', inputPerMillionUsd: 2 }];
  const service = new UsageService(repository, () => config);
  const record = service.record({ id: 'r', status: 'success', providerId: 'p', upstreamModel: 'm', inputTokens: 500000 });
  assert.equal(record.estimatedCostUsd, 1); assert.equal(record.pricingKnown, true);
});
test('usage service delegates list, summary, CSV, and prune', () => {
  const repository = new MemoryUsageRepository([{ id: 'r', startedAt: new Date().toISOString(), status: 'success' }]);
  const service = new UsageService(repository, createDefaultConfig);
  assert.equal(service.list().length, 1); assert.equal(service.summary().requests, 1); assert.match(service.csv(), /"r"/); assert.equal(service.prune(1), 0);
});
