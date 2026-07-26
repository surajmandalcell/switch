import test from 'node:test';
import assert from 'node:assert/strict';
import { StrategyState, selectCandidate } from '../../src/domain/routing/strategies.js';
import { parseRetryAfter, classifyUpstreamError, UpstreamError } from '../../src/domain/routing/errors.js';
import { evaluateAccountLimits } from '../../src/domain/routing/limits.js';
import { RoutingEngine } from '../../src/domain/routing/router.js';
import { createDefaultConfig, createProvider, createAccount } from '../../src/domain/config.js';

const candidate = (id, options = {}) => ({ provider: { id: options.providerId ?? 'p', strategyOverride: options.strategyOverride ?? null, maxAttempts: options.maxAttempts ?? null }, account: { id, priority: options.priority ?? 100, weight: options.weight ?? 1 }, runtime: { inflight: options.inflight ?? 0, latencyEwmaMs: options.latency ?? null }, estimatedCostUsd: options.cost ?? Infinity });

test('priority chooses the lowest numeric value', () => assert.equal(selectCandidate('priority', [candidate('a', { priority: 9 }), candidate('b', { priority: 2 })]).account.id, 'b'));
test('priority is deterministic for ties', () => assert.equal(selectCandidate('priority', [candidate('z'), candidate('a')]).account.id, 'a'));
test('round robin cycles candidates', () => {
  const state = new StrategyState();
  const items = [candidate('a'), candidate('b'), candidate('c')];
  assert.deepEqual([0,1,2,3].map(() => selectCandidate('round-robin', items, { scopeKey: 'm' }, state).account.id), ['a','b','c','a']);
});
test('round robin counters are isolated by scope', () => {
  const state = new StrategyState(); const items = [candidate('a'), candidate('b')];
  assert.equal(selectCandidate('round-robin', items, { scopeKey: 'x' }, state).account.id, 'a');
  assert.equal(selectCandidate('round-robin', items, { scopeKey: 'y' }, state).account.id, 'a');
});
test('weighted random honors boundaries', () => {
  const items = [candidate('a', { weight: 1 }), candidate('b', { weight: 3 })];
  assert.equal(selectCandidate('weighted-random', items, { random: () => 0 }).account.id, 'a');
  assert.equal(selectCandidate('weighted-random', items, { random: () => 0.99 }).account.id, 'b');
});
test('weighted random falls back when all weights are zero', () => {
  const items = [candidate('b', { weight: 0, priority: 2 }), candidate('a', { weight: 0, priority: 1 })];
  assert.equal(selectCandidate('weighted-random', items, { random: () => .5 }).account.id, 'a');
});
test('least inflight chooses the smallest active count', () => assert.equal(selectCandidate('least-inflight', [candidate('a', { inflight: 3 }), candidate('b', { inflight: 0 })]).account.id, 'b'));
test('lowest latency treats unknown latency as infinity', () => assert.equal(selectCandidate('lowest-latency', [candidate('a'), candidate('b', { latency: 20 })]).account.id, 'b'));
test('lowest cost chooses the estimated minimum', () => assert.equal(selectCandidate('lowest-cost', [candidate('a', { cost: .4 }), candidate('b', { cost: .1 })]).account.id, 'b'));
test('sticky reuses a healthy route', () => {
  const state = new StrategyState(); const items = [candidate('a', { priority: 1 }), candidate('b', { priority: 2 })];
  assert.equal(selectCandidate('sticky', items, { stickyKey: 'session', now: 0, stickyTtlMs: 10 }, state).account.id, 'a');
  assert.equal(selectCandidate('sticky', items.reverse(), { stickyKey: 'session', now: 5, stickyTtlMs: 10 }, state).account.id, 'a');
});
test('sticky expires and selects again', () => {
  const state = new StrategyState();
  selectCandidate('sticky', [candidate('a', { priority: 1 })], { stickyKey: 'session', now: 0, stickyTtlMs: 5 }, state);
  assert.equal(selectCandidate('sticky', [candidate('b', { priority: 1 })], { stickyKey: 'session', now: 6, stickyTtlMs: 5 }, state).account.id, 'b');
});
test('unknown strategy is rejected', () => assert.throws(() => selectCandidate('x', [candidate('a')]), /Unknown routing/));
test('empty candidate list is rejected', () => assert.throws(() => selectCandidate('priority', []), /At least one/));

test('retry-after parses seconds and dates', () => {
  assert.equal(parseRetryAfter('1.5', 0), 1500);
  assert.equal(parseRetryAfter('Thu, 01 Jan 1970 00:00:03 GMT', 1000), 2000);
  assert.equal(parseRetryAfter('bad', 0), null);
});
test('classification preserves upstream errors', () => {
  const error = new UpstreamError('x'); assert.equal(classifyUpstreamError(error), error);
});
test('authentication errors request attention and may fail over', () => {
  const error = classifyUpstreamError({ status: 401, message: 'bad key' }, { failoverOnAuthError: true, maxCooldownMs: 1000 });
  assert.equal(error.code, 'authentication_error'); assert.equal(error.attention, true); assert.equal(error.retryable, true);
});
test('rate limits honor retry-after', () => {
  const error = classifyUpstreamError({ status: 429, headers: { 'retry-after': '2' } }, { baseCooldownMs: 100, maxCooldownMs: 5000 }, 0);
  assert.equal(error.cooldownMs, 2000); assert.equal(error.retryable, true);
});
test('server failures use exponential cooldown', () => {
  const error = classifyUpstreamError({ status: 503, failureCount: 2 }, { baseCooldownMs: 100, maxCooldownMs: 1000 });
  assert.equal(error.cooldownMs, 400);
});
test('client cancellation is not retryable', () => {
  const error = classifyUpstreamError(Object.assign(new Error('bye'), { name: 'AbortError' }));
  assert.equal(error.code, 'client_cancelled'); assert.equal(error.retryable, false);
});
test('network and timeout failures are retryable', () => {
  assert.equal(classifyUpstreamError(new Error('fetch failed')).code, 'network_error');
  assert.equal(classifyUpstreamError(new Error('request timeout')).code, 'timeout');
});
test('ordinary 400 errors are not retryable', () => assert.equal(classifyUpstreamError({ status: 400, message: 'bad' }).retryable, false));

test('limits report every exceeded budget', () => {
  const account = createAccount({ id: 'a', limits: { requestsPerMinute: 2, tokensPerDay: 10, tokensPerMonth: 20, costPerMonthUsd: 1 } });
  const result = evaluateAccountLimits(account, { requestsMinute: 2, tokensDay: 11, tokensMonth: 20, costMonthUsd: 2 }, Date.now());
  assert.equal(result.allowed, false);
  assert.deepEqual(result.reasons, ['requests_per_minute','tokens_per_day','tokens_per_month','cost_per_month']);
});
test('unset limits allow traffic', () => assert.equal(evaluateAccountLimits(createAccount({}), {}).allowed, true));

test('routing candidates exclude disabled, cooldown, attention, model mismatch, and limits', () => {
  const config = createDefaultConfig();
  config.providers = [createProvider({ id: 'p', name: 'P', type: 'openai', modelGlobs: ['gpt-*'], accounts: [createAccount({ id: 'ok' }), createAccount({ id: 'cool' }), createAccount({ id: 'attention' }), createAccount({ id: 'disabled', enabled: false }), createAccount({ id: 'limited', limits: { requestsPerMinute: 1 } })] })];
  const runtime = new Map([['cool', { cooldownUntil: 100 }], ['attention', { attention: true }]]);
  const engine = new RoutingEngine({ now: () => 50 });
  const usage = { requestsSince(id) { return id === 'limited' ? 1 : 0; } };
  assert.deepEqual(engine.candidates(config, { model: 'gpt-5' }, runtime, usage).map((item) => item.account.id), ['ok']);
  assert.equal(engine.candidates(config, { model: 'claude' }, runtime, usage).length, 0);
});
test('routing plan avoids retrying the same route', () => {
  const config = createDefaultConfig(); config.routing.maxAttempts = 3;
  config.providers = [createProvider({ id: 'p', name: 'P', type: 'openai', accounts: [createAccount({ id: 'a' }), createAccount({ id: 'b' })] })];
  const plan = new RoutingEngine().plan(config, { model: 'x' });
  const ids = [plan.next().account.id, plan.next().account.id];
  assert.equal(new Set(ids).size, 2); assert.equal(plan.next(), null);
});
test('provider max attempts is respected', () => {
  const config = createDefaultConfig(); config.routing.maxAttempts = 5;
  config.providers = [createProvider({ id: 'p', name: 'P', type: 'openai', maxAttempts: 1, accounts: [createAccount({ id: 'a' }), createAccount({ id: 'b' })] })];
  const plan = new RoutingEngine().plan(config, { model: 'x' });
  assert.ok(plan.next()); assert.equal(plan.next(), null);
});
