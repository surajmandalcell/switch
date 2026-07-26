import { createAccount, createProvider, publicConfig } from '../domain/config.js';
import { invariant } from '../domain/shared.js';

/**
 * Owns provider/account configuration changes so credential and config writes
 * have one transaction boundary. Configuration is the source of truth;
 * detached secrets are cleaned only after a successful config commit.
 */
export class ProviderConfigurationService {
  constructor({ configStore, secretStore, runtime = null }) {
    this.configStore = configStore;
    this.secretStore = secretStore;
    this.runtime = runtime;
  }

  async addProvider(input) {
    const provider = createProvider({ ...input, accounts: [] });
    return this.expose(await this.configStore.update((config) => ({
      ...config,
      providers: [...config.providers, provider],
    })));
  }

  async updateProvider(providerId, patch = {}) {
    const current = this.findProvider(providerId);
    const { accounts: _ignoredAccounts, ...safePatch } = patch;
    const provider = createProvider({ ...current, ...safePatch, id: current.id, accounts: current.accounts });
    return this.expose(await this.configStore.update((config) => ({
      ...config,
      providers: config.providers.map((item) => item.id === providerId ? provider : item),
    })));
  }

  async removeProvider(providerId) {
    const current = this.findProvider(providerId);
    const next = await this.configStore.update((config) => ({
      ...config,
      providers: config.providers.filter((provider) => provider.id !== providerId),
      modelAliases: config.modelAliases.filter((alias) => alias.providerId !== providerId),
      pricing: config.pricing.filter((rule) => rule.providerId !== providerId),
    }));
    for (const account of current.accounts) {
      this.runtime?.clear(account.id);
      if (account.secretRef) await this.secretStore.delete(account.secretRef);
    }
    return this.expose(next);
  }

  async addAccount(providerId, input = {}) {
    this.findProvider(providerId);
    const secretRef = input.secret ? await this.secretStore.set(input.secret) : null;
    try {
      const account = createAccount({ ...input, secretRef });
      const next = await this.configStore.update((config) => ({
        ...config,
        providers: config.providers.map((provider) => provider.id === providerId
          ? { ...provider, accounts: [...provider.accounts, account] }
          : provider),
      }));
      return this.expose(next);
    } catch (error) {
      if (secretRef) await this.secretStore.delete(secretRef).catch(() => {});
      throw error;
    }
  }

  async updateAccount(providerId, accountId, patch = {}) {
    const current = this.findAccount(providerId, accountId);
    const nextSecretRef = patch.secret ? await this.secretStore.set(patch.secret) : current.secretRef;
    try {
      const { secret: _secret, hasSecret: _hasSecret, ...safePatch } = patch;
      const account = createAccount({ ...current, ...safePatch, id: current.id, secretRef: nextSecretRef });
      const next = await this.configStore.update((config) => ({
        ...config,
        providers: config.providers.map((provider) => provider.id === providerId
          ? { ...provider, accounts: provider.accounts.map((item) => item.id === accountId ? account : item) }
          : provider),
      }));
      if (patch.secret && current.secretRef && current.secretRef !== nextSecretRef) {
        await this.secretStore.delete(current.secretRef);
      }
      return this.expose(next);
    } catch (error) {
      if (patch.secret && nextSecretRef !== current.secretRef) await this.secretStore.delete(nextSecretRef).catch(() => {});
      throw error;
    }
  }

  async removeAccount(providerId, accountId) {
    const current = this.findAccount(providerId, accountId);
    const next = await this.configStore.update((config) => ({
      ...config,
      providers: config.providers.map((provider) => provider.id === providerId
        ? { ...provider, accounts: provider.accounts.filter((account) => account.id !== accountId) }
        : provider),
    }));
    this.runtime?.clear(accountId);
    if (current.secretRef) await this.secretStore.delete(current.secretRef);
    return this.expose(next);
  }

  findProvider(providerId) {
    const provider = this.configStore.get().providers.find((item) => item.id === providerId);
    invariant(provider, `Provider ${providerId} does not exist.`);
    return provider;
  }

  findAccount(providerId, accountId) {
    const provider = this.findProvider(providerId);
    const account = provider.accounts.find((item) => item.id === accountId);
    invariant(account, `Account ${accountId} does not exist in provider ${providerId}.`);
    return account;
  }

  expose(config) { return publicConfig(config); }
}
