import test from 'node:test';
import assert from 'node:assert/strict';
import { SettingsService, serverEndpointChanged } from '../../src/application/settings-service.js';
import { createDefaultConfig } from '../../src/domain/config.js';

class FakeConfigStore {
  constructor(config = createDefaultConfig()) { this.value = structuredClone(config); }
  get() { return this.value; }
  async update(mutator) { const next = await mutator(structuredClone(this.value)); next.revision = this.value.revision + 1; this.value = next; return next; }
  async save(value) { this.value = structuredClone(value); return this.value; }
}
class FakeSecrets {
  constructor() { this.values = new Map(); this.deleted = []; }
  async set(value, ref = `secret_${this.values.size}`) { this.values.set(ref, value); return ref; }
  async delete(ref) { this.deleted.push(ref); return this.values.delete(ref); }
}

test('settings patch merges domains and restarts only when endpoint changes', async () => {
  const store = new FakeConfigStore(); let restarts = 0; const logins = [];
  const service = new SettingsService({ configStore: store, secretStore: new FakeSecrets(), restartServer: async () => { restarts++; }, setLoginItem: (value) => logins.push(value) });
  const first = await service.updatePatch({ appearance: { theme: 'light' } });
  assert.equal(first.appearance.theme, 'light'); assert.equal(restarts, 0);
  await service.updatePatch({ server: { port: 9000, startOnLogin: true } });
  assert.equal(restarts, 1); assert.deepEqual(logins, [true]);
});

test('settings rollback configuration and effects when restart fails', async () => {
  const store = new FakeConfigStore(); const original = structuredClone(store.get()); let calls = 0;
  const service = new SettingsService({ configStore: store, secretStore: new FakeSecrets(), restartServer: async () => { calls++; if (calls === 1) throw new Error('occupied'); } });
  await assert.rejects(service.updatePatch({ server: { port: 9001 } }), /occupied/);
  assert.equal(store.get().server.port, original.server.port); assert.equal(calls, 2);
});

test('local API key is encrypted, replaceable, clearable, and redacted', async () => {
  const store = new FakeConfigStore(); const secrets = new FakeSecrets();
  const service = new SettingsService({ configStore: store, secretStore: secrets });
  const configured = await service.setApiKey('local-key');
  assert.equal(configured.server.hasApiKey, true); assert.equal(configured.server.apiKeySecretRef, undefined);
  const ref = store.get().server.apiKeySecretRef; assert.equal(secrets.values.get(ref), 'local-key');
  const cleared = await service.clearApiKey(); assert.equal(cleared.server.hasApiKey, undefined); assert.equal(store.get().server.apiKeySecretRef, null); assert.deepEqual(secrets.deleted, [ref]);
});

test('empty API key clears the current key', async () => {
  const store = new FakeConfigStore(); const secrets = new FakeSecrets(); const service = new SettingsService({ configStore: store, secretStore: secrets });
  await service.setApiKey('x'); await service.setApiKey('  '); assert.equal(store.get().server.apiKeySecretRef, null);
});

test('endpoint change predicate ignores dynamic server options', () => {
  const a = createDefaultConfig(); const b = structuredClone(a); b.server.requestTimeoutMs += 1;
  assert.equal(serverEndpointChanged(a, b), false); b.server.port += 1; assert.equal(serverEndpointChanged(a, b), true);
});
