import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';

import { findAvailablePort } from '../../scripts/resolve-test-port.mjs';

function listenOnLoopback(port = 0) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

async function listenOnAvailableLoopback(startPort = 28100) {
  for (let port = startPort; port < startPort + 50; port += 1) {
    try {
      return await listenOnLoopback(port);
    } catch {}
  }
  throw new Error('Could not reserve a loopback test port');
}

test('findAvailablePort: skips occupied default port when not explicitly requested', async (t) => {
  const blocker = await listenOnAvailableLoopback();
  t.after(() => blocker.close());

  const occupiedPort = blocker.address().port;
  const selectedPort = await findAvailablePort({
    host: '127.0.0.1',
    requestedPort: occupiedPort,
    explicit: false,
    maxAttempts: 5
  });

  assert.notEqual(selectedPort, occupiedPort);
  assert.ok(selectedPort > occupiedPort);
  assert.ok(selectedPort < occupiedPort + 5);
});

test('findAvailablePort: rejects occupied explicit test port', async (t) => {
  const blocker = await listenOnAvailableLoopback();
  t.after(() => blocker.close());

  const occupiedPort = blocker.address().port;
  await assert.rejects(
    () => findAvailablePort({
      host: '127.0.0.1',
      requestedPort: occupiedPort,
      explicit: true
    }),
    /TEST_PORT .* is already in use/
  );
});
