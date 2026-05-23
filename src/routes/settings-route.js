/**
 * Settings Route
 * Handles server settings endpoints:
 *   GET  /settings/haiku-model
 *   POST /settings/haiku-model
 *   GET  /settings/account-strategy
 *   POST /settings/account-strategy
 *   GET  /settings/kilo-models
 */

import { getServerSettings, isMultiAccountRotationEnabled, setServerSettings } from '../server-settings.js';
import { fetchFreeModels } from '../kilo-models.js';
import {
  CLAUDE_MODEL_ALIASES,
  DEFAULT_MODEL_MAPPINGS,
  DEFAULT_REASONING_MAPPINGS,
  OPENAI_MODEL_OPTIONS,
  REASONING_LEVEL_OPTIONS,
  isKiloEnabled,
  normalizeModelMappings,
  normalizeReasoningMappings
} from '../model-mapper.js';

const VALID_STRATEGIES = ['sticky', 'round-robin'];
const VALID_OPENAI_MODEL_IDS = new Set(OPENAI_MODEL_OPTIONS.map((model) => model.id));
const VALID_REASONING_LEVEL_IDS = new Set(REASONING_LEVEL_OPTIONS.map((level) => level.id));

function modelMappingsPayload(modelMappings, reasoningMappings) {
  return {
    success: true,
    aliases: CLAUDE_MODEL_ALIASES,
    models: OPENAI_MODEL_OPTIONS,
    reasoningLevels: REASONING_LEVEL_OPTIONS,
    defaults: DEFAULT_MODEL_MAPPINGS,
    reasoningDefaults: DEFAULT_REASONING_MAPPINGS,
    modelMappings: normalizeModelMappings(modelMappings),
    reasoningMappings: normalizeReasoningMappings(reasoningMappings)
  };
}

/**
 * GET /settings/haiku-model
 * Returns the current explicit Kilo target selection.
 */
export function handleGetHaikuModel(req, res) {
  const settings = getServerSettings();
  res.json({
    success: true,
    haikuKiloModel: settings.haikuKiloModel,
    kiloEnabled: isKiloEnabled()
  });
}

/**
 * POST /settings/haiku-model
 * Updates the explicit Kilo target selection.
 * Accepts any model ID string — the UI filters to only show free models.
 */
export async function handleSetHaikuModel(req, res) {
  const { haikuKiloModel } = req.body || {};

  if (!haikuKiloModel || typeof haikuKiloModel !== 'string') {
    return res.status(400).json({
      success: false,
      error: 'haikuKiloModel is required and must be a string'
    });
  }

  if (!isKiloEnabled()) {
    return res.status(403).json({
      success: false,
      error: 'Kilo routing is disabled. Set CODEX_CLAUDE_PROXY_ENABLE_KILO=true to enable third-party Kilo model routing.'
    });
  }

  // Validate against live free models from Kilo API
  try {
    const freeModels = await fetchFreeModels();
    const validIds = freeModels.map(m => m.id);
    if (!validIds.includes(haikuKiloModel)) {
      return res.status(400).json({
        success: false,
        error: `Model "${haikuKiloModel}" is not a free model. Available: ${validIds.join(', ')}`
      });
    }
  } catch (err) {
    // If API is unreachable, allow any value (user may know what they're doing)
    console.warn(`[Settings] Could not validate model against Kilo API: ${err.message}`);
  }

  const settings = setServerSettings({ haikuKiloModel });
  res.json({ success: true, haikuKiloModel: settings.haikuKiloModel, kiloEnabled: true });
}

/**
 * GET /settings/kilo-models
 * Returns the list of free Kilo models from the API.
 */
export async function handleGetKiloModels(req, res) {
  const settings = getServerSettings();
  if (!isKiloEnabled()) {
    return res.json({
      success: true,
      enabled: false,
      models: [],
      current: settings.haikuKiloModel
    });
  }

  try {
    const freeModels = await fetchFreeModels();
    res.json({
      success: true,
      enabled: true,
      models: freeModels,
      current: settings.haikuKiloModel
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: `Failed to fetch models: ${error.message}`
    });
  }
}

/**
 * GET /settings/model-mappings
 * Returns editable Claude alias -> upstream GPT model mappings.
 */
export function handleGetModelMappings(req, res) {
  const settings = getServerSettings();
  res.json(modelMappingsPayload(settings.modelMappings, settings.reasoningMappings));
}

/**
 * POST /settings/model-mappings
 * Updates one or more Claude alias mappings.
 */
export function handleSetModelMappings(req, res) {
  const { modelMappings, reasoningMappings } = req.body || {};
  const hasModelMappings = modelMappings !== undefined;
  const hasReasoningMappings = reasoningMappings !== undefined;

  if (!hasModelMappings && !hasReasoningMappings) {
    return res.status(400).json({
      success: false,
      error: 'modelMappings or reasoningMappings is required'
    });
  }

  if (hasModelMappings && (!modelMappings || typeof modelMappings !== 'object' || Array.isArray(modelMappings))) {
    return res.status(400).json({
      success: false,
      error: 'modelMappings is required and must be an object'
    });
  }

  if (hasReasoningMappings && (!reasoningMappings || typeof reasoningMappings !== 'object' || Array.isArray(reasoningMappings))) {
    return res.status(400).json({
      success: false,
      error: 'reasoningMappings must be an object'
    });
  }

  const modelAliases = hasModelMappings ? Object.keys(modelMappings) : [];
  const reasoningAliases = hasReasoningMappings ? Object.keys(reasoningMappings) : [];
  const unknownAliases = [...modelAliases, ...reasoningAliases].filter((alias) => !CLAUDE_MODEL_ALIASES.includes(alias));
  if (unknownAliases.length > 0) {
    return res.status(400).json({
      success: false,
      error: `Invalid model mapping alias. Use one of: ${CLAUDE_MODEL_ALIASES.join(', ')}`
    });
  }

  for (const [alias, model] of Object.entries(modelMappings || {})) {
    if (typeof model !== 'string' || !VALID_OPENAI_MODEL_IDS.has(model)) {
      return res.status(400).json({
        success: false,
        error: `Invalid model for ${alias}. Use one of: ${OPENAI_MODEL_OPTIONS.map((option) => option.id).join(', ')}`
      });
    }
  }

  for (const [alias, reasoning] of Object.entries(reasoningMappings || {})) {
    if (typeof reasoning !== 'string' || !VALID_REASONING_LEVEL_IDS.has(reasoning)) {
      return res.status(400).json({
        success: false,
        error: `Invalid reasoning level for ${alias}. Use one of: ${REASONING_LEVEL_OPTIONS.map((option) => option.id).join(', ')}`
      });
    }
  }

  const settings = getServerSettings();
  const nextMappings = {
    ...normalizeModelMappings(settings.modelMappings),
    ...(modelMappings || {})
  };
  const nextReasoningMappings = {
    ...normalizeReasoningMappings(settings.reasoningMappings),
    ...(reasoningMappings || {})
  };
  const nextSettings = setServerSettings({
    modelMappings: nextMappings,
    reasoningMappings: nextReasoningMappings
  });
  res.json(modelMappingsPayload(nextSettings.modelMappings, nextSettings.reasoningMappings));
}

/**
 * GET /settings/account-strategy
 * Returns the current account selection strategy.
 */
export function handleGetAccountStrategy(req, res) {
  const settings = getServerSettings();
  res.json({
    success: true,
    accountStrategy: settings.accountStrategy,
    rotationEnabled: isMultiAccountRotationEnabled()
  });
}

/**
 * POST /settings/account-strategy
 * Updates the account selection strategy.
 */
export function handleSetAccountStrategy(req, res) {
  const { accountStrategy } = req.body || {};

  if (!VALID_STRATEGIES.includes(accountStrategy)) {
    return res.status(400).json({
      success: false,
      error: `Invalid accountStrategy. Use one of: ${VALID_STRATEGIES.join(', ')}`
    });
  }

  const settings = setServerSettings({ accountStrategy });
  res.json({
    success: true,
    accountStrategy: settings.accountStrategy,
    rotationEnabled: isMultiAccountRotationEnabled()
  });
}

export default { 
  handleGetHaikuModel, 
  handleSetHaikuModel,
  handleGetKiloModels,
  handleGetModelMappings,
  handleSetModelMappings,
  handleGetAccountStrategy,
  handleSetAccountStrategy
};
