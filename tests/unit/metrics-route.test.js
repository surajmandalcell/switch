import test from 'node:test';
import assert from 'node:assert/strict';

import {
  handleGetMetricsRecent,
  handleGetMetricsStorage,
  handleGetMetricsSummary
} from '../../src/routes/metrics-route.js';

function mockReq(query = {}) {
  return { query };
}

function mockRes() {
  return {
    _status: 200,
    _body: null,
    status(code) {
      this._status = code;
      return this;
    },
    json(body) {
      this._body = body;
      return this;
    }
  };
}

function makeStore() {
  return {
    summaryArgs: null,
    recentArgs: null,
    async getSummary(filters) {
      this.summaryArgs = filters;
      return { totals: { requestCount: 0 }, byModel: [], byAccount: [], timeline: [] };
    },
    async getRecentEvents(filters) {
      this.recentArgs = filters;
      return { events: [] };
    },
    async getStorageInfo() {
      return { dbPath: '/tmp/metrics.duckdb', sizeBytes: 0, maxBytes: 52428800 };
    }
  };
}

test('handleGetMetricsSummary returns wrapped summary and forwards filters', async () => {
  const store = makeStore();
  const res = mockRes();

  await handleGetMetricsSummary(mockReq({
    range: '7d',
    model: 'gpt-5.5',
    account: 'me@example.com',
    status: 'success'
  }), res, { metricsStore: store });

  assert.equal(res._status, 200);
  assert.equal(res._body.success, true);
  assert.deepEqual(store.summaryArgs, {
    range: '7d',
    model: 'gpt-5.5',
    account: 'me@example.com',
    status: 'success'
  });
  assert.equal(res._body.summary.totals.requestCount, 0);
});

test('handleGetMetricsRecent clamps limit and returns wrapped events', async () => {
  const store = makeStore();
  const res = mockRes();

  await handleGetMetricsRecent(mockReq({ range: 'all', limit: '500' }), res, { metricsStore: store });

  assert.equal(res._status, 200);
  assert.equal(res._body.success, true);
  assert.equal(store.recentArgs.limit, 100);
  assert.deepEqual(res._body.events, []);
});

test('handleGetMetricsStorage returns wrapped storage details', async () => {
  const store = makeStore();
  const res = mockRes();

  await handleGetMetricsStorage(mockReq(), res, { metricsStore: store });

  assert.equal(res._status, 200);
  assert.equal(res._body.success, true);
  assert.equal(res._body.storage.dbPath, '/tmp/metrics.duckdb');
});
