import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  createUsageMetricsStore,
  tapUsageEventStream
} from '../../src/usage-metrics.js';

function makeTempDb(t) {
  const dir = mkdtempSync(join(tmpdir(), 'codex-proxy-metrics-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, 'metrics.duckdb');
}

test('usage metrics store records request shape and aggregates token usage', async (t) => {
  const store = createUsageMetricsStore({ dbPath: makeTempDb(t) });
  t.after(async () => store.close());

  await store.recordUsageEvent({
    startedAt: '2026-05-23T10:00:00.000Z',
    completedAt: '2026-05-23T10:00:01.250Z',
    endpoint: '/v1/messages',
    requestedModel: 'claude-sonnet-4-5',
    upstreamModel: 'gpt-5.5',
    accountLabel: 'me@example.com',
    provider: 'openai',
    stream: true,
    messageCount: 2,
    toolCount: 1,
    usage: {
      input_tokens: 10,
      output_tokens: 7,
      cache_read_input_tokens: 3
    },
    status: 200,
    durationMs: 1250
  });

  await store.recordUsageEvent({
    startedAt: '2026-05-23T11:00:00.000Z',
    completedAt: '2026-05-23T11:00:00.500Z',
    endpoint: '/v1/chat/completions',
    requestedModel: 'gpt-5.4-mini',
    upstreamModel: 'gpt-5.4-mini',
    accountLabel: 'me@example.com',
    provider: 'openai',
    stream: false,
    messageCount: 1,
    toolCount: 0,
    usage: {
      input_tokens: 4,
      output_tokens: 5,
      cache_read_input_tokens: 0
    },
    status: 200,
    durationMs: 500
  });

  const summary = await store.getSummary({ range: 'all' });
  assert.deepEqual(summary.totals, {
    requestCount: 2,
    successCount: 2,
    errorCount: 0,
    inputTokens: 14,
    outputTokens: 12,
    cacheReadInputTokens: 3,
    totalTokens: 26,
    averageDurationMs: 875
  });
  assert.equal(summary.byModel[0].model, 'gpt-5.5');
  assert.equal(summary.byModel[0].totalTokens, 17);
  assert.equal(summary.byAccount[0].accountLabel, 'me@example.com');
  assert.equal(summary.byAccount[0].requestCount, 2);
  assert.equal(summary.timeline.length, 2);
});

test('usage metrics store returns recent events in newest-first order', async (t) => {
  const store = createUsageMetricsStore({ dbPath: makeTempDb(t) });
  t.after(async () => store.close());

  await store.recordUsageEvent({
    startedAt: '2026-05-23T10:00:00.000Z',
    completedAt: '2026-05-23T10:00:00.250Z',
    endpoint: '/v1/messages',
    requestedModel: 'claude-haiku-4',
    upstreamModel: 'gpt-5.4-mini',
    accountLabel: 'first@example.com',
    provider: 'openai',
    stream: false,
    messageCount: 1,
    toolCount: 0,
    usage: { input_tokens: 1, output_tokens: 2 },
    status: 200,
    durationMs: 250
  });
  await store.recordUsageEvent({
    startedAt: '2026-05-23T10:05:00.000Z',
    completedAt: '2026-05-23T10:05:00.750Z',
    endpoint: '/v1/messages',
    requestedModel: 'claude-opus-4-5',
    upstreamModel: 'gpt-5.5',
    accountLabel: 'second@example.com',
    provider: 'openai',
    stream: true,
    messageCount: 3,
    toolCount: 2,
    usage: { input_tokens: 8, output_tokens: 13 },
    status: 500,
    errorType: 'API_ERROR',
    durationMs: 750
  });

  const recent = await store.getRecentEvents({ range: 'all', limit: 10 });
  assert.equal(recent.events.length, 2);
  assert.equal(recent.events[0].upstreamModel, 'gpt-5.5');
  assert.equal(recent.events[0].errorType, 'API_ERROR');
  assert.equal(recent.events[0].totalTokens, 21);
  assert.equal(recent.events[1].upstreamModel, 'gpt-5.4-mini');
});

test('usage metrics compact-only policy records compaction attempts without deleting history', async (t) => {
  const store = createUsageMetricsStore({ dbPath: makeTempDb(t), maxBytes: 1 });
  t.after(async () => store.close());

  await store.recordUsageEvent({
    startedAt: '2026-05-23T10:00:00.000Z',
    completedAt: '2026-05-23T10:00:00.100Z',
    endpoint: '/v1/messages',
    requestedModel: 'claude-sonnet-4-5',
    upstreamModel: 'gpt-5.5',
    accountLabel: 'me@example.com',
    provider: 'openai',
    stream: false,
    messageCount: 1,
    toolCount: 0,
    usage: { input_tokens: 2, output_tokens: 3 },
    status: 200,
    durationMs: 100
  });

  const storage = await store.getStorageInfo();
  assert.equal(storage.maxBytes, 1);
  assert.equal(storage.overLimit, true);
  assert.ok(storage.lastCompactionAttemptAt);

  const recent = await store.getRecentEvents({ range: 'all', limit: 10 });
  assert.equal(recent.events.length, 1);
});

test('tapUsageEventStream forwards events and reports final usage once', async () => {
  const sourceEvents = [
    { event: 'message_start', data: { type: 'message_start' } },
    {
      event: 'message_delta',
      data: {
        type: 'message_delta',
        usage: {
          input_tokens: 11,
          output_tokens: 12,
          cache_read_input_tokens: 4
        }
      }
    },
    { event: 'message_stop', data: { type: 'message_stop' } }
  ];

  async function* source() {
    for (const event of sourceEvents) {
      yield event;
    }
  }

  const captured = [];
  const forwarded = [];
  for await (const event of tapUsageEventStream(source(), (usage) => captured.push(usage))) {
    forwarded.push(event);
  }

  assert.deepEqual(forwarded, sourceEvents);
  assert.deepEqual(captured, [{
    input_tokens: 11,
    output_tokens: 12,
    cache_read_input_tokens: 4
  }]);
});
