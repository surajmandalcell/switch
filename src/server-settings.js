import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { CONFIG_DIR } from './account-manager.js';

const SETTINGS_FILE = join(CONFIG_DIR, 'settings.json');

const DEFAULT_SETTINGS = {
    haikuKiloModel: 'minimax/minimax-m2.5:free',
    configureClaudeOnStartup: false,
    modelMappings: {
        opus: 'gpt-5.5',
        sonnet: 'gpt-5.5',
        haiku: 'gpt-5.4-mini'
    },
    reasoningMappings: {
        opus: 'high',
        sonnet: 'medium',
        haiku: 'low'
    }
};

export function normalizeSettings(data = {}) {
    const modelMappings = data?.modelMappings && typeof data.modelMappings === 'object' && !Array.isArray(data.modelMappings)
        ? data.modelMappings
        : {};
    const reasoningMappings = data?.reasoningMappings && typeof data.reasoningMappings === 'object' && !Array.isArray(data.reasoningMappings)
        ? data.reasoningMappings
        : {};

    return {
        haikuKiloModel: typeof data.haikuKiloModel === 'string'
            ? data.haikuKiloModel
            : DEFAULT_SETTINGS.haikuKiloModel,
        configureClaudeOnStartup: data.configureClaudeOnStartup === true,
        modelMappings: {
            ...DEFAULT_SETTINGS.modelMappings,
            ...modelMappings
        },
        reasoningMappings: {
            ...DEFAULT_SETTINGS.reasoningMappings,
            ...reasoningMappings
        }
    };
}

function ensureConfigDir() {
    if (!existsSync(CONFIG_DIR)) {
        mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
    }
}

export function getServerSettings() {
    ensureConfigDir();

    if (!existsSync(SETTINGS_FILE)) {
        return normalizeSettings();
    }

    try {
        const data = JSON.parse(readFileSync(SETTINGS_FILE, 'utf8'));
        return normalizeSettings(data);
    } catch (error) {
        console.error('[ServerSettings] Failed to read settings:', error.message);
        return normalizeSettings();
    }
}

export function setServerSettings(patch = {}) {
    const current = getServerSettings();
    const next = normalizeSettings({ ...current, ...patch });

    ensureConfigDir();
    writeFileSync(SETTINGS_FILE, JSON.stringify(next, null, 2), { mode: 0o600 });
    return next;
}

export { SETTINGS_FILE };

export default {
    getServerSettings,
    setServerSettings,
    normalizeSettings,
    SETTINGS_FILE
};
