import { invariant } from '../domain/shared.js';

export class ProviderRegistry {
  constructor(adapters = []) {
    this.adapters = new Map();
    for (const adapter of adapters) this.register(adapter);
  }

  register(adapter) {
    invariant(adapter && typeof adapter === 'object', 'Provider adapter must be an object.');
    invariant(typeof adapter.type === 'string' && adapter.type, 'Provider adapter needs a type.');
    invariant(typeof adapter.execute === 'function', `Provider adapter ${adapter.type} needs execute().`);
    invariant(typeof adapter.stream === 'function', `Provider adapter ${adapter.type} needs stream().`);
    invariant(!this.adapters.has(adapter.type), `Provider adapter already registered: ${adapter.type}`);
    this.adapters.set(adapter.type, adapter);
    return this;
  }

  replace(adapter) {
    invariant(adapter?.type, 'Provider adapter needs a type.');
    this.adapters.set(adapter.type, adapter);
    return this;
  }

  get(type) {
    const adapter = this.adapters.get(type);
    invariant(adapter, `No adapter is registered for provider type ${type}.`);
    return adapter;
  }

  has(type) {
    return this.adapters.has(type);
  }

  list() {
    return [...this.adapters.keys()].sort();
  }
}
