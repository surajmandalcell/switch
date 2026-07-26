import { pathToFileURL } from 'node:url';
import path from 'node:path';

export function createExternalModuleAdapter({ trustedRoot }) {
  const cache = new Map();
  async function load(provider) {
    const configured = path.resolve(provider.adapter?.modulePath ?? '');
    const root = path.resolve(trustedRoot);
    if (!configured.startsWith(`${root}${path.sep}`)) throw new Error('External provider modules must live inside the trusted modules directory.');
    const token = provider.adapter?.reloadToken ?? 'stable';
    const key = `${configured}:${token}`;
    if (!cache.has(key)) {
      const module = await import(`${pathToFileURL(configured).href}?v=${encodeURIComponent(token)}`);
      if (typeof module.createAdapter !== 'function') throw new Error('External provider module must export createAdapter().');
      cache.set(key, await module.createAdapter(provider.adapter?.options ?? {}));
    }
    return cache.get(key);
  }
  return {
    type: 'external-module',
    async execute(request, context) { return (await load(context.provider)).execute(request, context); },
    async *stream(request, context) { yield* (await load(context.provider)).stream(request, context); },
  };
}
