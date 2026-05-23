/**
 * Model Mapper
 * Maps Anthropic/Claude model names to upstream OpenAI/Kilo model identifiers.
 */

import { getServerSettings } from './server-settings.js';

const DEFAULT_OPENAI_MODEL = 'gpt-5.5';
const DEFAULT_SMALL_OPENAI_MODEL = 'gpt-5.4-mini';
const LATEST_CODEX_MODEL = 'gpt-5.3-codex';
const KILO_ENABLED_ENV = 'CODEX_CLAUDE_PROXY_ENABLE_KILO';
const CLAUDE_MODEL_ALIASES = ['opus', 'sonnet', 'haiku'];
const OPENAI_MODEL_OPTIONS = [
  { id: 'gpt-5.5', name: 'GPT-5.5' },
  { id: 'gpt-5.5-2026-04-23', name: 'GPT-5.5 Snapshot' },
  { id: 'gpt-5.4', name: 'GPT-5.4' },
  { id: 'gpt-5.4-2026-03-05', name: 'GPT-5.4 Snapshot' },
  { id: 'gpt-5.4-mini', name: 'GPT-5.4 Mini' },
  { id: 'gpt-5.4-nano', name: 'GPT-5.4 Nano' },
  { id: 'gpt-5.3-codex', name: 'GPT-5.3 Codex' },
  { id: 'gpt-5.2-codex', name: 'GPT-5.2 Codex' },
  { id: 'gpt-5.2', name: 'GPT-5.2' },
  { id: 'gpt-5.1', name: 'GPT-5.1' },
  { id: 'gpt-5', name: 'GPT-5' },
  { id: 'gpt-5.1-codex-max', name: 'GPT-5.1 Codex Max' },
  { id: 'gpt-5.1-codex', name: 'GPT-5.1 Codex' },
  { id: 'gpt-5-codex', name: 'GPT-5 Codex' },
  { id: 'gpt-5.1-codex-mini', name: 'GPT-5.1 Codex Mini' },
  { id: 'gpt-5-codex-mini', name: 'GPT-5 Codex Mini' }
];
const OPENAI_MODEL_IDS = new Set(OPENAI_MODEL_OPTIONS.map((model) => model.id));
const REASONING_LEVEL_OPTIONS = [
  { id: 'low', name: 'Low', description: 'Fast responses with lighter reasoning' },
  { id: 'medium', name: 'Medium', description: 'Balanced speed and reasoning depth' },
  { id: 'high', name: 'High', description: 'Greater reasoning depth for complex work' },
  { id: 'xhigh', name: 'Extra High', description: 'Extra high reasoning depth for complex work' }
];
const REASONING_LEVEL_IDS = new Set(REASONING_LEVEL_OPTIONS.map((level) => level.id));
const DEFAULT_MODEL_MAPPINGS = {
  opus: DEFAULT_OPENAI_MODEL,
  sonnet: DEFAULT_OPENAI_MODEL,
  haiku: DEFAULT_SMALL_OPENAI_MODEL
};
const DEFAULT_REASONING_MAPPINGS = {
  opus: 'high',
  sonnet: 'medium',
  haiku: 'low'
};

const CLAUDE_MODEL_MAP = {
  // Current Claude 4.6 models (Feb 2026)
  'claude-opus-4-6': DEFAULT_OPENAI_MODEL,
  'claude-opus-4-6-20250219': DEFAULT_OPENAI_MODEL,
  'claude-sonnet-4-6': DEFAULT_OPENAI_MODEL,
  'claude-sonnet-4-6-20250219': DEFAULT_OPENAI_MODEL,
  'claude-haiku-4-5': DEFAULT_SMALL_OPENAI_MODEL,
  'claude-haiku-4-5-20250219': DEFAULT_SMALL_OPENAI_MODEL,
  
  // 1M context variants
  'claude-opus-4-6-1m': DEFAULT_OPENAI_MODEL,
  'claude-sonnet-4-6-1m': DEFAULT_OPENAI_MODEL,
  
  // Legacy Claude 4.5 models (deprecated but still supported)
  'claude-opus-4-5': DEFAULT_OPENAI_MODEL,
  'claude-opus-4-5-20250514': DEFAULT_OPENAI_MODEL,
  'claude-sonnet-4-5': DEFAULT_OPENAI_MODEL,
  'claude-sonnet-4-5-20250514': DEFAULT_OPENAI_MODEL,
  'claude-sonnet-4-20250514': DEFAULT_OPENAI_MODEL,
  'claude-haiku-4-20250514': DEFAULT_SMALL_OPENAI_MODEL,
  'claude-haiku-3-5-20250514': DEFAULT_SMALL_OPENAI_MODEL,
  
  // Legacy Claude 3.x models
  'claude-3-5-sonnet-20240620': DEFAULT_OPENAI_MODEL,
  'claude-3-opus-20240229': DEFAULT_OPENAI_MODEL,
  'claude-3-sonnet-20240229': DEFAULT_OPENAI_MODEL,
  'claude-3-haiku-20240307': DEFAULT_SMALL_OPENAI_MODEL,
  
  // Short aliases
  'sonnet': DEFAULT_OPENAI_MODEL,
  'opus': DEFAULT_OPENAI_MODEL,
  'haiku': DEFAULT_SMALL_OPENAI_MODEL,
  'codex': LATEST_CODEX_MODEL,
  'kilo': 'kilo',
  
  // Direct OpenAI models
  'gpt-5.5': 'gpt-5.5',
  'gpt-5.5-2026-04-23': 'gpt-5.5-2026-04-23',
  'gpt-5.4': 'gpt-5.4',
  'gpt-5.4-2026-03-05': 'gpt-5.4-2026-03-05',
  'gpt-5.4-mini': 'gpt-5.4-mini',
  'gpt-5.4-nano': 'gpt-5.4-nano',
  'gpt-5.3-codex': 'gpt-5.3-codex',
  'gpt-5.2-codex': 'gpt-5.2-codex',
  'gpt-5.1-codex-max': 'gpt-5.1-codex-max',
  'gpt-5.1-codex': 'gpt-5.1-codex',
  'gpt-5-codex': 'gpt-5-codex',
  'gpt-5.2': 'gpt-5.2',
  'gpt-5.1': 'gpt-5.1',
  'gpt-5': 'gpt-5',
  'gpt-5.1-codex-mini': 'gpt-5.1-codex-mini',
  'gpt-5-codex-mini': 'gpt-5-codex-mini'
};

/**
 * Normalizes persisted Claude alias mappings against supported GPT targets.
 * @param {Record<string, string>} modelMappings
 * @returns {{ opus: string, sonnet: string, haiku: string }}
 */
export function normalizeModelMappings(modelMappings = {}) {
  const normalized = { ...DEFAULT_MODEL_MAPPINGS };
  if (!modelMappings || typeof modelMappings !== 'object' || Array.isArray(modelMappings)) {
    return normalized;
  }

  for (const alias of CLAUDE_MODEL_ALIASES) {
    const candidate = modelMappings[alias];
    if (typeof candidate === 'string' && OPENAI_MODEL_IDS.has(candidate)) {
      normalized[alias] = candidate;
    }
  }

  return normalized;
}

/**
 * Normalizes persisted Claude alias reasoning mappings against supported efforts.
 * @param {Record<string, string>} reasoningMappings
 * @returns {{ opus: string, sonnet: string, haiku: string }}
 */
export function normalizeReasoningMappings(reasoningMappings = {}) {
  const normalized = { ...DEFAULT_REASONING_MAPPINGS };
  if (!reasoningMappings || typeof reasoningMappings !== 'object' || Array.isArray(reasoningMappings)) {
    return normalized;
  }

  for (const alias of CLAUDE_MODEL_ALIASES) {
    const candidate = reasoningMappings[alias];
    if (typeof candidate === 'string' && REASONING_LEVEL_IDS.has(candidate)) {
      normalized[alias] = candidate;
    }
  }

  return normalized;
}

function inferClaudeAlias(modelLower) {
  for (const alias of CLAUDE_MODEL_ALIASES) {
    if (modelLower === alias || modelLower.includes(alias)) {
      return alias;
    }
  }
  return null;
}

/**
 * Maps a Claude/Anthropic model name to the upstream model identifier.
 * Falls back to the current OpenAI flagship model for unknown models.
 * @param {string} model
 * @param {{ modelMappings?: Record<string, string> }} settings
 * @returns {string}
 */
export function mapClaudeModel(model, settings = getServerSettings()) {
  if (!model) return DEFAULT_OPENAI_MODEL;

  const modelLower = String(model).toLowerCase();

  if (modelLower.startsWith('gpt-')) {
    return modelLower;
  }

  if (modelLower === 'codex') {
    return LATEST_CODEX_MODEL;
  }

  if (modelLower === 'kilo') {
    return 'kilo';
  }

  const mappedAlias = inferClaudeAlias(modelLower);
  if (mappedAlias) {
    return normalizeModelMappings(settings?.modelMappings)[mappedAlias];
  }

  if (CLAUDE_MODEL_MAP[modelLower]) {
    return CLAUDE_MODEL_MAP[modelLower];
  }

  return DEFAULT_OPENAI_MODEL;
}

/**
 * Resolves the configured reasoning effort for Claude aliases.
 * Direct GPT, codex, kilo, and unknown model requests do not force a reasoning level.
 * @param {string} model
 * @param {{ reasoningMappings?: Record<string, string> }} settings
 * @returns {string|null}
 */
export function mapClaudeReasoningLevel(model, settings = getServerSettings()) {
  if (!model) return null;

  const modelLower = String(model).toLowerCase();
  if (modelLower.startsWith('gpt-') || modelLower === 'codex' || modelLower === 'kilo') {
    return null;
  }

  const mappedAlias = inferClaudeAlias(modelLower);
  if (!mappedAlias) return null;

  return normalizeReasoningMappings(settings?.reasoningMappings)[mappedAlias];
}

/**
 * Returns true if the mapped model should be routed through Kilo.
 * @param {string} mappedModel
 * @returns {boolean}
 */
export function isKiloModel(mappedModel) {
  return mappedModel === 'kilo';
}

export function isKiloEnabled() {
  return process.env[KILO_ENABLED_ENV] === 'true';
}

/**
 * Resolves the actual Kilo model identifier based on server settings.
 * The setting stores the full Kilo model ID (e.g. 'minimax/minimax-m2.5:free').
 * @returns {string}
 */
export function resolveKiloModel(settings = getServerSettings()) {
  return settings.haikuKiloModel || 'minimax/minimax-m2.5:free';
}

/**
 * Resolves all model routing info from a requested model name.
 * @param {string} requestedModel
 * @returns {{ mappedModel: string, isKilo: boolean, kiloTarget: string|null, upstreamModel: string, reasoningLevel: string|null }}
 */
export function resolveModelRouting(requestedModel, settings = getServerSettings()) {
  const mappedModel = mapClaudeModel(requestedModel || DEFAULT_OPENAI_MODEL, settings);
  const reasoningLevel = mapClaudeReasoningLevel(requestedModel, settings);
  const isKilo = isKiloModel(mappedModel);
  const kiloTarget = isKilo ? resolveKiloModel(settings) : null;
  const upstreamModel = isKilo ? kiloTarget : mappedModel;
  return { mappedModel, isKilo, kiloTarget, upstreamModel, reasoningLevel };
}

export {
  CLAUDE_MODEL_MAP,
  DEFAULT_OPENAI_MODEL,
  DEFAULT_SMALL_OPENAI_MODEL,
  DEFAULT_MODEL_MAPPINGS,
  DEFAULT_REASONING_MAPPINGS,
  CLAUDE_MODEL_ALIASES,
  OPENAI_MODEL_OPTIONS,
  REASONING_LEVEL_OPTIONS,
  LATEST_CODEX_MODEL,
  KILO_ENABLED_ENV
};

export default {
  mapClaudeModel,
  mapClaudeReasoningLevel,
  isKiloModel,
  resolveKiloModel,
  resolveModelRouting,
  CLAUDE_MODEL_MAP,
  DEFAULT_OPENAI_MODEL,
  DEFAULT_SMALL_OPENAI_MODEL,
  DEFAULT_MODEL_MAPPINGS,
  DEFAULT_REASONING_MAPPINGS,
  CLAUDE_MODEL_ALIASES,
  OPENAI_MODEL_OPTIONS,
  REASONING_LEVEL_OPTIONS,
  normalizeModelMappings,
  normalizeReasoningMappings,
  LATEST_CODEX_MODEL,
  KILO_ENABLED_ENV,
  isKiloEnabled
};
