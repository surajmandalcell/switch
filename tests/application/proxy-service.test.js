import test from 'node:test';
import assert from 'node:assert/strict';
import { ProxyService } from '../../src/application/proxy-service.js';
import { canonicalResponse, streamEvent } from '../../src/domain/protocol/canonical.js';

function body(stream = false) { return { model: 'smart', stream, messages: [{ role: 'user', content: 'hello' }] }; }
function candidate() { return { provider: { id: 'p', type: 'openai' }, account: { id: 'a' } }; }

test('proxy execute estimates routes, serializes output, and records successful usage', async () => {
  const records = [];
  let routed;
  const service = new ProxyService({
    routing: { async execute(request) { routed = request; return { candidate: candidate(), response: canonicalResponse({ model: 'gpt-upstream', content: 'done', usage: { inputTokens: 4, outputTokens: 2 } }) }; } },
    getConfig: () => ({ server: { requestTimeoutMs: 1 } }),
    resolveSecret: () => 'secret',
    usageService: { estimateRouteCosts: () => ({ p: 0.02 }), record: (record) => records.push(record) },
    clock: (() => { let now = 1000; return () => now += 25; })(),
  });
  const output = await service.execute('openai-chat', body());
  assert.deepEqual(routed.estimatedCosts, { p: 0.02 });
  assert.equal(output.choices[0].message.content, 'done');
  assert.equal(records[0].status, 'success');
  assert.equal(records[0].providerId, 'p');
  assert.equal(records[0].inputTokens, 4);
  assert.ok(records[0].latencyMs > 0);
});

test('proxy execute records terminal failures and rethrows them', async () => {
  const records = [];
  const failure = Object.assign(new Error('bad'), { code: 'rate_limited', failures: [{ providerId: 'p', accountId: 'a', upstreamModel: 'gpt-real' }] });
  const service = new ProxyService({ routing: { execute: async () => { throw failure; } }, getConfig: () => ({}), resolveSecret: () => null, usageService: { record: (record) => records.push(record) } });
  await assert.rejects(service.execute('openai-chat', body()), /bad/);
  assert.deepEqual(records.map(({ status, providerId, upstreamModel, errorCode }) => ({ status, providerId, upstreamModel, errorCode })), [{ status: 'error', providerId: 'p', upstreamModel: 'gpt-real', errorCode: 'rate_limited' }]);
});

test('proxy streaming emits keep-alive comments and records selected route', async () => {
  const records = [];
  const routing = {
    async *stream(request, context) {
      context.observer.attemptSucceeded({ candidate: candidate(), upstreamRequest: { ...request, model: 'gpt-real' } });
      yield streamEvent('heartbeat');
      yield streamEvent('start', { model: 'gpt-real' });
      yield streamEvent('text-delta', { text: 'hello' });
      yield streamEvent('usage', { usage: { inputTokens: 3, outputTokens: 1, totalTokens: 4 } });
      yield streamEvent('finish', { stopReason: 'end_turn' });
    },
  };
  let now = 0;
  const service = new ProxyService({ routing, getConfig: () => ({}), resolveSecret: () => null, usageService: { record: (record) => records.push(record) }, clock: () => (now += 10) });
  const events = [];
  for await (const event of service.stream('openai-chat', body(true))) events.push(event);
  assert.equal(events[0].comment, 'keep-alive');
  assert.equal(events.at(-1).data, '[DONE]');
  assert.equal(records[0].providerId, 'p');
  assert.equal(records[0].upstreamModel, 'gpt-real');
  assert.ok(records[0].firstTokenLatencyMs > 0);
});

test('proxy streaming records cancellation', async () => {
  const records = [];
  const error = Object.assign(new Error('gone'), { code: 'client_cancelled', failures: [{ providerId: 'p', accountId: 'a', upstreamModel: 'm' }] });
  const service = new ProxyService({ routing: { async *stream() { throw error; } }, getConfig: () => ({}), resolveSecret: () => null, usageService: { record: (record) => records.push(record) } });
  await assert.rejects(async () => { for await (const _ of service.stream('openai-chat', body(true))) void _; }, /gone/);
  assert.equal(records[0].status, 'cancelled');
});

test('usage persistence errors are contained and logged', () => {
  const errors = [];
  const service = new ProxyService({ routing: {}, getConfig: () => ({}), resolveSecret: () => null, usageService: { record() { throw new Error('disk'); } }, logger: { error: (...args) => errors.push(args) } });
  assert.equal(service.record({ id: 'r' }), null);
  assert.equal(errors.length, 1);
});
