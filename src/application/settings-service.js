import { publicConfig } from '../domain/config.js';

export class SettingsService {
  constructor({ configStore, secretStore, restartServer = async () => {}, setLoginItem = () => {} }) {
    this.configStore = configStore;
    this.secretStore = secretStore;
    this.restartServer = restartServer;
    this.setLoginItem = setLoginItem;
  }

  async updatePatch(patch) {
    return this.update((config) => ({
      ...config,
      ...patch,
      server: { ...config.server, ...(patch.server ?? {}) },
      routing: { ...config.routing, ...(patch.routing ?? {}) },
      appearance: { ...config.appearance, ...(patch.appearance ?? {}) },
    }));
  }

  async replace(input) {
    return this.update(() => ({ ...input, revision: this.configStore.get().revision }));
  }

  async update(mutator) {
    const previous = structuredClone(this.configStore.get());
    const next = await this.configStore.update(mutator);
    try {
      if (serverEndpointChanged(previous, next)) await this.restartServer();
      if (previous.server.startOnLogin !== next.server.startOnLogin) this.setLoginItem(next.server.startOnLogin);
      return publicConfig(next);
    } catch (error) {
      await this.configStore.save(previous);
      if (serverEndpointChanged(previous, next)) await this.restartServer().catch(() => {});
      this.setLoginItem(previous.server.startOnLogin);
      throw error;
    }
  }

  async setApiKey(secret) {
    const value = String(secret ?? '').trim();
    const previousRef = this.configStore.get().server.apiKeySecretRef;
    if (!value) return this.clearApiKey();
    let newRef;
    try {
      newRef = await this.secretStore.set(value, previousRef ?? undefined);
      const next = await this.configStore.update((config) => ({ ...config, server: { ...config.server, apiKeySecretRef: newRef } }));
      return publicConfig(next);
    } catch (error) {
      if (newRef && newRef !== previousRef) await this.secretStore.delete(newRef).catch(() => {});
      throw error;
    }
  }

  async clearApiKey() {
    const previousRef = this.configStore.get().server.apiKeySecretRef;
    const next = await this.configStore.update((config) => ({ ...config, server: { ...config.server, apiKeySecretRef: null } }));
    if (previousRef) await this.secretStore.delete(previousRef);
    return publicConfig(next);
  }
}

export function serverEndpointChanged(previous, next) {
  return previous.server.host !== next.server.host || previous.server.port !== next.server.port;
}
