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
  OPENAI_MODEL_OPTIONS,
  isKiloEnabled,
  normalizeModelMappings
} from '../model-mapper.js';

const VALID_STRATEGIES = ['sticky', 'round-robin'];
const VALID_OPENAI_MODEL_IDS = new Set(OPENAI_MODEL_OPTIONS.map((model) => model.id));

function modelMappingsPayload(modelMappings) {
  return {
    success: true,
    aliases: CLAUDE_MODEL_ALIASES,
    models: OPENAI_MODEL_OPTIONS,
    defaults: DEFAULT_MODEL_MAPPINGS,
    modelMappings: normalizeModelMappings(modelMappings)
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
  res.json(modelMappingsPayload(settings.modelMappings));
}

/**
 * POST /settings/model-mappings
 * Updates one or more Claude alias mappings.
 */
export function handleSetModelMappings(req, res) {
  const { modelMappings } = req.body || {};

  if (!modelMappings || typeof modelMappings !== 'object' || Array.isArray(modelMappings)) {
    return res.status(400).json({
      success: false,
      error: 'modelMappings is required and must be an object'
    });
  }

  const unknownAliases = Object.keys(modelMappings).filter((alias) => !CLAUDE_MODEL_ALIASES.includes(alias));
  if (unknownAliases.length > 0) {
    return res.status(400).json({
      success: false,
      error: `Invalid model mapping alias. Use one of: ${CLAUDE_MODEL_ALIASES.join(', ')}`
    });
  }

  for (const [alias, model] of Object.entries(modelMappings)) {
    if (typeof model !== 'string' || !VALID_OPENAI_MODEL_IDS.has(model)) {
      return res.status(400).json({
        success: false,
        error: `Invalid model for ${alias}. Use one of: ${OPENAI_MODEL_OPTIONS.map((option) => option.id).join(', ')}`
      });
    }
  }

  const settings = getServerSettings();
  const nextMappings = {
    ...normalizeModelMappings(settings.modelMappings),
    ...modelMappings
  };
  const nextSettings = setServerSettings({ modelMappings: nextMappings });
  res.json(modelMappingsPayload(nextSettings.modelMappings));
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
