import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';

import { stopAutoRefresh } from '../../src/account-manager.js';
import { DEFAULT_HOST, startServer } from '../../src/server.js';

test('startServer: binds to loopback by default', async (t) => {
  const server = startServer({ port: 0 });
  t.after(() => {
    stopAutoRefresh();
    server.close();
  });
  await once(server, 'listening');

  assert.equal(DEFAULT_HOST, '127.0.0.1');
  assert.equal(server.address().address, '127.0.0.1');
});
