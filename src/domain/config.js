import { deepClone, invariant, newId } from './shared.js';

export const ROUTING_STRATEGIES = Object.freeze([
  'priority',
  'round-robin',
  'weighted-random',
  'least-inflight',
  'lowest-latency',
  'lowest-cost',
  'sticky',
]);

export const PROVIDER_TYPES = Object.freeze([
  'openai',
  'anthropic',
  'gemini',
  'grok',
  'openai-compatible',
  'anthropic-compatible',
  'command',
  'external-module',
]);

export function createDefaultConfig() {
  return {
    schemaVersion: 2,
    revision: 0,
    server: {
      host: '127.0.0.1',
      port: 8081,
      corsOrigins: [],
      apiKeySecretRef: null,
      requestTimeoutMs: 120_000,
      startOnLogin: false,
    },
    routing: {
      strategy: 'priority',
      maxAttempts: 4,
      stickyTtlMs: 900_000,
      baseCooldownMs: 5_000,
      maxCooldownMs: 900_000,
      failoverOnAuthError: true,
    },
    providers: [],
    modelAliases: [],
    pricing: [],
    retentionDays: 90,
    appearance: { theme: 'system', compact: true, reduceMotion: false },
  };
}

export function createProvider(input = {}) {
  return {
    id: input.id ?? newId('provider'),
    name: String(input.name ?? 'New provider').trim(),
    type: input.type ?? 'openai-compatible',
    enabled: input.enabled ?? true,
    baseUrl: String(input.baseUrl ?? '').trim(),
    modelGlobs: Array.isArray(input.modelGlobs) && input.modelGlobs.length ? input.modelGlobs.map(String) : ['*'],
    strategyOverride: input.strategyOverride ?? null,
    maxAttempts: Number.isInteger(input.maxAttempts) ? input.maxAttempts : null,
    headers: sanitizeHeaders(input.headers ?? {}),
    adapter: deepClone(input.adapter ?? {}),
    accounts: Array.isArray(input.accounts) ? input.accounts.map(createAccount) : [],
  };
}

export function createAccount(input = {}) {
  return {
    id: input.id ?? newId('account'),
    label: String(input.label ?? 'Account').trim(),
    enabled: input.enabled ?? true,
    secretRef: input.secretRef ?? null,
    priority: Number.isFinite(Number(input.priority)) ? Number(input.priority) : 100,
    weight: Number.isFinite(Number(input.weight)) && Number(input.weight) > 0 ? Number(input.weight) : 1,
    limits: {
      requestsPerMinute: nullablePositive(input.limits?.requestsPerMinute),
      tokensPerDay: nullablePositive(input.limits?.tokensPerDay),
      tokensPerMonth: nullablePositive(input.limits?.tokensPerMonth),
      costPerMonthUsd: nullablePositive(input.limits?.costPerMonthUsd),
    },
    metadata: deepClone(input.metadata ?? {}),
  };
}

function nullablePositive(value) {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

export function sanitizeHeaders(headers) {
  const output = {};
  for (const [key, value] of Object.entries(headers ?? {})) {
    const normalized = key.trim();
    if (!normalized || /authorization|api[-_]?key|cookie|token/i.test(normalized)) continue;
    output[normalized] = String(value);
  }
  return output;
}

export function normalizeConfig(input) {
  const base = createDefaultConfig();
  const config = { ...base, ...deepClone(input ?? {}) };
  config.server = { ...base.server, ...(input?.server ?? {}) };
  config.routing = { ...base.routing, ...(input?.routing ?? {}) };
  config.appearance = { ...base.appearance, ...(input?.appearance ?? {}) };
  config.providers = (input?.providers ?? []).map(createProvider);
  config.modelAliases = Array.isArray(input?.modelAliases) ? deepClone(input.modelAliases) : [];
  config.pricing = Array.isArray(input?.pricing) ? deepClone(input.pricing) : [];
  config.schemaVersion = 2;
  config.revision = Number.isInteger(input?.revision) ? input.revision : 0;
  return validateConfig(config);
}

export function validateConfig(config) {
  invariant(config && typeof config === 'object', 'Configuration must be an object.');
  invariant(config.schemaVersion === 2, 'Unsupported configuration schema version.');
  invariant(config.server.host === '127.0.0.1' || config.server.host === 'localhost', 'The proxy must bind to loopback.');
  invariant(Number.isInteger(config.server.port) && config.server.port >= 1024 && config.server.port <= 65535, 'Server port must be between 1024 and 65535.');
  invariant(ROUTING_STRATEGIES.includes(config.routing.strategy), 'Unknown global routing strategy.');
  invariant(Number.isInteger(config.retentionDays) && config.retentionDays >= 1 && config.retentionDays <= 3650, 'Retention days must be between 1 and 3650.');
  invariant(Array.isArray(config.server.corsOrigins), 'CORS origins must be an array.');
  for (const origin of config.server.corsOrigins) validateOrigin(origin);
  invariant(Number.isInteger(config.routing.maxAttempts) && config.routing.maxAttempts >= 1 && config.routing.maxAttempts <= 20, 'Global maxAttempts must be between 1 and 20.');
  const providerIds = new Set();
  const accountIds = new Set();
  for (const provider of config.providers) {
    invariant(PROVIDER_TYPES.includes(provider.type), `Unknown provider type: ${provider.type}`);
    invariant(provider.id && !providerIds.has(provider.id), `Duplicate provider id: ${provider.id}`);
    providerIds.add(provider.id);
    invariant(provider.name, `Provider ${provider.id} needs a name.`);
    if (provider.baseUrl) {
      let parsed;
      try { parsed = new URL(provider.baseUrl); } catch { invariant(false, `Provider ${provider.name} has an invalid base URL.`); }
      invariant(['http:', 'https:'].includes(parsed.protocol), `Provider ${provider.name} base URL must use HTTP or HTTPS.`);
      invariant(!parsed.username && !parsed.password, `Provider ${provider.name} base URL cannot embed credentials.`);
      invariant(parsed.protocol === 'https:' || isLoopbackHostname(parsed.hostname), `Provider ${provider.name} must use HTTPS unless it is a loopback endpoint.`);
    }
    invariant(provider.strategyOverride === null || ROUTING_STRATEGIES.includes(provider.strategyOverride), `Invalid routing override for ${provider.name}.`);
    invariant(provider.maxAttempts === null || (Number.isInteger(provider.maxAttempts) && provider.maxAttempts >= 1 && provider.maxAttempts <= 20), `Provider ${provider.name} maxAttempts must be between 1 and 20.`);
    invariant(Array.isArray(provider.modelGlobs) && provider.modelGlobs.length > 0 && provider.modelGlobs.every((glob) => typeof glob === 'string' && glob.trim()), `Provider ${provider.name} needs at least one model glob.`);
    invariant(Array.isArray(provider.accounts), `Provider ${provider.name} accounts must be an array.`);
    for (const account of provider.accounts) {
      invariant(account.id && !accountIds.has(account.id), `Duplicate account id: ${account.id}`);
      accountIds.add(account.id);
      invariant(account.label, `Account ${account.id} needs a label.`);
      invariant(account.weight > 0, `Account ${account.label} must have a positive weight.`);
      invariant(account.priority >= 0, `Account ${account.label} priority cannot be negative.`);
    }
  }
  const aliasKeys = new Set();
  for (const alias of config.modelAliases) {
    invariant(alias.requested && alias.target, 'Model aliases require requested and target values.');
    if (alias.providerId) invariant(providerIds.has(alias.providerId), `Alias references missing provider ${alias.providerId}.`);
    const key = `${alias.providerId ?? '*'}:${alias.requested}`;
    invariant(!aliasKeys.has(key), `Duplicate model alias for ${alias.requested}.`);
    aliasKeys.add(key);
  }
  const pricingIds = new Set();
  for (const rule of config.pricing) {
    if (rule.id) { invariant(!pricingIds.has(rule.id), `Duplicate pricing rule id: ${rule.id}`); pricingIds.add(rule.id); }
    if (rule.providerId) invariant(providerIds.has(rule.providerId), `Pricing rule references missing provider ${rule.providerId}.`);
    invariant(rule.modelGlob, 'Pricing rules require a model glob.');
    for (const field of ['inputPerMillionUsd','outputPerMillionUsd','cacheReadPerMillionUsd','cacheWritePerMillionUsd']) {
      invariant(Number.isFinite(Number(rule[field] ?? 0)) && Number(rule[field] ?? 0) >= 0, `Pricing field ${field} must be a non-negative number.`);
    }
    if (rule.sourceUrl) validateHttpsUrl(rule.sourceUrl, 'Pricing source URL');
  }
  return config;
}

function validateOrigin(value) {
  invariant(typeof value === 'string' && value && !value.includes('*'), 'CORS origins must be exact URLs without wildcards.');
  let url;
  try { url = new URL(value); } catch { invariant(false, `Invalid CORS origin: ${value}`); }
  invariant(['http:', 'https:'].includes(url.protocol) && !url.username && !url.password && url.origin === value.replace(/\/$/, ''), `Invalid CORS origin: ${value}`);
}

function validateHttpsUrl(value, label) {
  let url;
  try { url = new URL(value); } catch { invariant(false, `${label} is invalid.`); }
  invariant(url.protocol === 'https:' && !url.username && !url.password, `${label} must be an HTTPS URL without credentials.`);
}

function isLoopbackHostname(hostname) {
  return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1' || hostname === '[::1]';
}

export function publicConfig(config) {
  const copy = deepClone(config);
  for (const provider of copy.providers) {
    for (const account of provider.accounts) {
      account.hasSecret = Boolean(account.secretRef);
      delete account.secretRef;
    }
  }
  if (copy.server.apiKeySecretRef) copy.server.hasApiKey = true;
  delete copy.server.apiKeySecretRef;
  return copy;
}

export function replaceProviderOverrides(config, strategy = config.routing.strategy) {
  invariant(ROUTING_STRATEGIES.includes(strategy), 'Unknown routing strategy.');
  const copy = deepClone(config);
  copy.routing.strategy = strategy;
  copy.providers = copy.providers.map((provider) => ({ ...provider, strategyOverride: null }));
  copy.revision += 1;
  return validateConfig(copy);
}

export function resolveModelAlias(config, requestedModel, providerId = null) {
  const exact = config.modelAliases.find((entry) => entry.requested === requestedModel && (entry.providerId ?? null) === providerId);
  const global = config.modelAliases.find((entry) => entry.requested === requestedModel && !entry.providerId);
  return (exact ?? global)?.target ?? requestedModel;
}
