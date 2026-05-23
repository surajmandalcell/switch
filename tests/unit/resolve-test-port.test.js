import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';

import { findAvailablePort, prepareTestPort } from '../../scripts/resolve-test-port.mjs';

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

test('prepareTestPort: kills previous repo proxy listener and reuses requested port', async () => {
  let occupied = true;
  const killed = [];

  const result = await prepareTestPort({
    host: '127.0.0.1',
    requestedPort: 28100,
    explicit: false,
    maxAttempts: 5,
    repoRoot: '/repo',
    findListenerPids: async (port) => (port === 28100 && occupied ? [1234] : []),
    getProcessInfo: async (pid) => ({
      pid,
      cwd: '/repo',
      command: 'node src/index.js'
    }),
    killPid: async (pid) => {
      killed.push(pid);
      occupied = false;
    },
    canListen: async ({ port }) => port === 28100 && !occupied
  });

  assert.equal(result.port, 28100);
  assert.deepEqual(killed, [1234]);
  assert.deepEqual(result.killed.map(({ pid }) => pid), [1234]);
});

test('prepareTestPort: leaves unrelated listeners alone and selects the next port', async () => {
  const killed = [];

  const result = await prepareTestPort({
    host: '127.0.0.1',
    requestedPort: 28100,
    explicit: false,
    maxAttempts: 5,
    repoRoot: '/repo',
    findListenerPids: async (port) => (port === 28100 ? [5678] : []),
    getProcessInfo: async (pid) => ({
      pid,
      cwd: '/other-repo',
      command: 'node src/index.js'
    }),
    killPid: async (pid) => {
      killed.push(pid);
    },
    canListen: async ({ port }) => port !== 28100
  });

  assert.equal(result.port, 28101);
  assert.deepEqual(killed, []);
  assert.deepEqual(result.killed, []);
});
