import test from 'node:test';
import assert from 'node:assert/strict';
import { choosePricingRule, estimateCost, filterUsage, summarizeUsage, usageToCsv } from '../../src/domain/usage.js';

const rules = [
  { providerType: 'openai', modelGlob: '*', inputPerMillionUsd: 1 },
  { providerType: 'openai', modelGlob: 'gpt-*', inputPerMillionUsd: 2 },
  { providerId: 'p', modelGlob: 'gpt-5', inputPerMillionUsd: 3, verifiedAt: '2026-01-01' },
];

test('provider-specific exact pricing wins', () => assert.equal(choosePricingRule(rules, 'p', 'openai', 'gpt-5').inputPerMillionUsd, 3));
test('specific model glob wins over broad type rule', () => assert.equal(choosePricingRule(rules, 'other', 'openai', 'gpt-4').inputPerMillionUsd, 2));
test('no pricing match returns null', () => assert.equal(choosePricingRule(rules, 'p', 'anthropic', 'claude'), null));
test('newer verification breaks equal specificity ties', () => {
  const result = choosePricingRule([{ providerType: 'x', modelGlob: 'm', verifiedAt: '2025' }, { providerType: 'x', modelGlob: 'm', verifiedAt: '2026' }], null, 'x', 'm');
  assert.equal(result.verifiedAt, '2026');
});
test('cost includes input, output, cache read, and cache write independently', () => {
  const value = estimateCost({ inputTokens: 1_000_000, outputTokens: 2_000_000, cacheReadTokens: 3_000_000, cacheWriteTokens: 4_000_000 }, { inputPerMillionUsd: 1, outputPerMillionUsd: 2, cacheReadPerMillionUsd: 3, cacheWritePerMillionUsd: 4 });
  assert.equal(value.usd, 30); assert.equal(value.known, true);
});
test('unknown pricing is explicit', () => assert.deepEqual(estimateCost({ inputTokens: 2 }, null), { usd: 0, known: false, usage: { inputTokens: 2, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: 2 } }));

const records = [
  { id: '1', startedAt: '2026-01-01T00:00:00Z', status: 'success', providerId: 'p1', accountId: 'a1', protocol: 'openai-chat', inputTokens: 10, outputTokens: 2, cacheReadTokens: 1, estimatedCostUsd: .1, latencyMs: 100 },
  { id: '2', startedAt: '2026-01-02T00:00:00Z', status: 'error', providerId: 'p2', accountId: 'a2', protocol: 'anthropic', inputTokens: 3, outputTokens: 0, estimatedCostUsd: .2, latencyMs: 50 },
  { id: '3', startedAt: '2026-01-03T00:00:00Z', status: 'cancelled', providerId: 'p1', accountId: 'a2', protocol: 'openai-chat', inputTokens: 1, outputTokens: 1, cacheWriteTokens: 2, estimatedCostUsd: .3, latencyMs: 25 },
];

test('usage filters compose across dimensions', () => assert.deepEqual(filterUsage(records, { providerId: 'p1', accountId: 'a2', protocol: 'openai-chat', status: 'cancelled' }).map((item) => item.id), ['3']));
test('date filters are inclusive', () => assert.deepEqual(filterUsage(records, { from: '2026-01-02T00:00:00Z', to: '2026-01-03T00:00:00Z' }).map((item) => item.id), ['2','3']));
test('summary aggregates status, tokens, cache, cost, latency', () => {
  const summary = summarizeUsage(records);
  assert.deepEqual(summary, { requests: 3, successes: 1, failures: 1, cancelled: 1, inputTokens: 14, outputTokens: 3, cacheReadTokens: 1, cacheWriteTokens: 2, estimatedCostUsd: .6, totalLatencyMs: 175 });
});
test('summary applies filters', () => assert.equal(summarizeUsage(records, { providerId: 'p1' }).requests, 2));
test('CSV has stable columns and escapes values', () => {
  const csv = usageToCsv([{ ...records[0], requestedModel: 'model,"x"' }]);
  assert.match(csv, /^id,startedAt,status/); assert.match(csv, /"model,""x"""/);
});
test('CSV applies the same filters', () => { const csv = usageToCsv(records, { status: 'error' }); assert.match(csv, /"2"/); assert.doesNotMatch(csv, /"1"/); });
