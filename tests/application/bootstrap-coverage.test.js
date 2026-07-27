import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { bootstrap } from '../../src/bootstrap.js';
import { createDefaultConfig } from '../../src/domain/config.js';

class StatementFixture {
  constructor(sql, database) { this.sql = sql; this.database = database; }
  run(value) { this.database.runs.push({ sql: this.sql, value }); return { changes: 1 }; }
  all() { return []; }
  get() { return { value: 0 }; }
}
class DatabaseFixture {
  constructor(filePath) { this.filePath = filePath; this.runs = []; DatabaseFixture.instances.push(this); }
  static instances = [];
  pragma() {}
  exec() {}
  prepare(sql) { return new StatementFixture(sql, this); }
  close() { this.closed = true; }
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

test('bootstrap composes services, route hooks, and HTTP restart lifecycle', async () => {
  const userDataPath = await mkdtemp(path.join(os.tmpdir(), 'spi-bootstrap-'));
  const config = createDefaultConfig();
  config.server.port = await freePort();
  await writeFile(path.join(userDataPath, 'config.json'), JSON.stringify(config));
  const services = await bootstrap({ userDataPath, safeStorage: null, Database: DatabaseFixture });
  assert.ok(services.configStore);
  assert.ok(services.proxyService);
  assert.ok(services.httpServer);
  const candidate = { provider: { id: 'p' }, account: { id: 'a' } };
  const request = { id: 'r', model: 'requested' };
  const upstreamRequest = { model: 'upstream' };
  services.routing.hooks.attemptStarted({ candidate, request, upstreamRequest });
  services.routing.hooks.attemptSucceeded({ attemptId: 'one', candidate, request, upstreamRequest, latencyMs: 10, startedAt: 0 });
  services.routing.hooks.attemptFailed({ attemptId: 'two', candidate, request, upstreamRequest, error: { code: 'client_cancelled' }, latencyMs: 11, startedAt: 0 });
  services.routing.hooks.attemptFailed({ attemptId: 'three', candidate, request, upstreamRequest, error: { code: 'temporary' }, latencyMs: 12, startedAt: 0 });
  assert.equal(DatabaseFixture.instances.at(-1).runs.length, 3);
  assert.equal(services.logger.list().length, 3);
  const first = services.httpServer;
  await services.restartHttpServer();
  assert.notEqual(services.httpServer, first);
  await services.httpServer.stop();
});
