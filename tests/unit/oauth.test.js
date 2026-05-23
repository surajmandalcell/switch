import test from 'node:test';
import assert from 'node:assert/strict';

import { startCallbackServer } from '../../src/oauth.js';

test('startCallbackServer: resolves callback code only when OAuth state matches', async (t) => {
  const callback = startCallbackServer('expected-state', 2000, {
    host: '127.0.0.1',
    port: 0
  });

  await callback.ready;
  const port = callback.getPort();
  t.after(() => callback.abort());

  const res = await fetch(`http://127.0.0.1:${port}/auth/callback?code=code-123&state=expected-state`);
  assert.equal(res.status, 200);

  const result = await callback.promise;
  assert.deepEqual(result, { code: 'code-123', state: 'expected-state' });
});

test('startCallbackServer: rejects callback code when OAuth state mismatches', async (t) => {
  const callback = startCallbackServer('expected-state', 2000, {
    host: '127.0.0.1',
    port: 0
  });

  await callback.ready;
  const port = callback.getPort();
  t.after(() => callback.abort());

  const rejection = assert.rejects(callback.promise, /Invalid OAuth state/);
  const res = await fetch(`http://127.0.0.1:${port}/auth/callback?code=code-123&state=wrong-state`);
  assert.equal(res.status, 400);

  await rejection;
});
