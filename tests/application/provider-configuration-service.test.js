import test from 'node:test';
import assert from 'node:assert/strict';
import { ProviderConfigurationService } from '../../src/application/provider-configuration-service.js';
import { createDefaultConfig, createProvider, createAccount, normalizeConfig } from '../../src/domain/config.js';

function fixture({ failUpdate = false, failDelete = false } = {}) {
  let config = normalizeConfig({ ...createDefaultConfig(), providers: [createProvider({ id: 'p', name: 'Provider', type: 'openai', accounts: [createAccount({ id: 'a', label: 'Primary', secretRef: 'old' })] })], modelAliases: [{ requested: 'alias', target: 'model', providerId: 'p' }], pricing: [{ id: 'price', providerId: 'p', modelGlob: '*' }] });
  const secrets = new Map([['old', 'old-secret']]);
  let next = 0;
  const configStore = {
    get: () => structuredClone(config),
    async update(mutator) {
      if (failUpdate) throw new Error('config failed');
      config = normalizeConfig({ ...mutator(structuredClone(config)), revision: config.revision + 1 });
      return structuredClone(config);
    },
  };
  const secretStore = {
    async set(value) { const ref = `new-${++next}`; secrets.set(ref, value); return ref; },
    async delete(ref) { if (failDelete) throw new Error('delete failed'); return secrets.delete(ref); },
    get: (ref) => secrets.get(ref),
  };
  const cleared = [];
  const service = new ProviderConfigurationService({ configStore, secretStore, runtime: { clear: (id) => cleared.push(id) } });
  return { service, configStore, secretStore, secrets, cleared };
}

test('provider updates preserve credential-bearing account state from public drafts', async () => {
  const { service, configStore } = fixture();
  const result = await service.updateProvider('p', { name: 'Renamed', accounts: [{ id: 'a', label: 'Public copy', hasSecret: true }] });
  assert.equal(result.providers[0].name, 'Renamed');
  assert.equal(result.providers[0].accounts[0].label, 'Primary');
  assert.equal(configStore.get().providers[0].accounts[0].secretRef, 'old');
});

test('adding an account rolls back a freshly encrypted secret when config commit fails', async () => {
  const { service, secrets } = fixture({ failUpdate: true });
  await assert.rejects(service.addAccount('p', { label: 'Second', secret: 'new-secret' }), /config failed/);
  assert.deepEqual([...secrets.keys()], ['old']);
});

test('updating a credential commits a new reference then removes the old secret', async () => {
  const { service, configStore, secrets } = fixture();
  const result = await service.updateAccount('p', 'a', { label: 'Updated', secret: 'replacement' });
  assert.equal(result.providers[0].accounts[0].hasSecret, true);
  const stored = configStore.get().providers[0].accounts[0];
  assert.notEqual(stored.secretRef, 'old');
  assert.equal(secrets.has('old'), false);
  assert.equal(secrets.get(stored.secretRef), 'replacement');
});

test('removing a provider commits config first and clears aliases, pricing, runtime, and secrets', async () => {
  const { service, configStore, secrets, cleared } = fixture();
  const result = await service.removeProvider('p');
  assert.equal(result.providers.length, 0);
  assert.equal(configStore.get().modelAliases.length, 0);
  assert.equal(configStore.get().pricing.length, 0);
  assert.deepEqual(cleared, ['a']);
  assert.equal(secrets.size, 0);
});

test('unknown provider and account identifiers fail explicitly', async () => {
  const { service } = fixture();
  await assert.rejects(service.updateProvider('missing', {}), /does not exist/);
  await assert.rejects(service.updateAccount('p', 'missing', {}), /does not exist/);
});
