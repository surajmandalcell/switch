/**
 * Model Mapper
 * Maps Anthropic/Claude model names to upstream OpenAI/Kilo model identifiers.
 */

import { getServerSettings } from './server-settings.js';

const DEFAULT_OPENAI_MODEL = 'gpt-5.5';
const DEFAULT_SMALL_OPENAI_MODEL = 'gpt-5.4-mini';
const LATEST_CODEX_MODEL = 'gpt-5.3-codex';
const KILO_ENABLED_ENV = 'CODEX_CLAUDE_PROXY_ENABLE_KILO';

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
 * Maps a Claude/Anthropic model name to the upstream model identifier.
 * Falls back to the current OpenAI flagship model for unknown models.
 * @param {string} model
 * @returns {string}
 */
export function mapClaudeModel(model) {
  if (!model) return DEFAULT_OPENAI_MODEL;

  if (CLAUDE_MODEL_MAP[model]) {
    return CLAUDE_MODEL_MAP[model];
  }

  const modelLower = model.toLowerCase();

  if (modelLower.startsWith('gpt-')) {
    return modelLower;
  }

  if (modelLower.startsWith('claude-')) {
    const cleanModel = modelLower.replace(/^claude-/, '');
    if (cleanModel.includes('opus')) return DEFAULT_OPENAI_MODEL;
    if (cleanModel.includes('sonnet')) return DEFAULT_OPENAI_MODEL;
    if (cleanModel.includes('haiku')) return DEFAULT_SMALL_OPENAI_MODEL;
  }

  for (const [key, value] of Object.entries(CLAUDE_MODEL_MAP)) {
    if (modelLower.includes(key.toLowerCase())) {
      return value;
    }
  }

  return DEFAULT_OPENAI_MODEL;
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
export function resolveKiloModel() {
  const settings = getServerSettings();
  return settings.haikuKiloModel || 'minimax/minimax-m2.5:free';
}

/**
 * Resolves all model routing info from a requested model name.
 * @param {string} requestedModel
 * @returns {{ mappedModel: string, isKilo: boolean, kiloTarget: string|null, upstreamModel: string }}
 */
export function resolveModelRouting(requestedModel) {
  const mappedModel = mapClaudeModel(requestedModel || DEFAULT_OPENAI_MODEL);
  const isKilo = isKiloModel(mappedModel);
  const kiloTarget = isKilo ? resolveKiloModel() : null;
  const upstreamModel = isKilo ? kiloTarget : mappedModel;
  return { mappedModel, isKilo, kiloTarget, upstreamModel };
}

export {
  CLAUDE_MODEL_MAP,
  DEFAULT_OPENAI_MODEL,
  DEFAULT_SMALL_OPENAI_MODEL,
  LATEST_CODEX_MODEL,
  KILO_ENABLED_ENV
};

export default {
  mapClaudeModel,
  isKiloModel,
  resolveKiloModel,
  resolveModelRouting,
  CLAUDE_MODEL_MAP,
  DEFAULT_OPENAI_MODEL,
  DEFAULT_SMALL_OPENAI_MODEL,
  LATEST_CODEX_MODEL,
  KILO_ENABLED_ENV,
  isKiloEnabled
};
