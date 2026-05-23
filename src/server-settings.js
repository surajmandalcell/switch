import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { CONFIG_DIR } from './account-manager.js';

const SETTINGS_FILE = join(CONFIG_DIR, 'settings.json');
const MULTI_ACCOUNT_ROTATION_ENV = 'CODEX_CLAUDE_PROXY_ENABLE_MULTI_ACCOUNT_ROTATION';

const DEFAULT_SETTINGS = {
    haikuKiloModel: 'minimax/minimax-m2.5:free',
    accountStrategy: 'sticky',
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

function ensureConfigDir() {
    if (!existsSync(CONFIG_DIR)) {
        mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
    }
}

export function getServerSettings() {
    ensureConfigDir();

    if (!existsSync(SETTINGS_FILE)) {
        return {
            ...DEFAULT_SETTINGS,
            modelMappings: { ...DEFAULT_SETTINGS.modelMappings },
            reasoningMappings: { ...DEFAULT_SETTINGS.reasoningMappings }
        };
    }

    try {
        const data = JSON.parse(readFileSync(SETTINGS_FILE, 'utf8'));
        const modelMappings = data?.modelMappings && typeof data.modelMappings === 'object' && !Array.isArray(data.modelMappings)
            ? data.modelMappings
            : {};
        const reasoningMappings = data?.reasoningMappings && typeof data.reasoningMappings === 'object' && !Array.isArray(data.reasoningMappings)
            ? data.reasoningMappings
            : {};
        return {
            ...DEFAULT_SETTINGS,
            ...data,
            modelMappings: {
                ...DEFAULT_SETTINGS.modelMappings,
                ...modelMappings
            },
            reasoningMappings: {
                ...DEFAULT_SETTINGS.reasoningMappings,
                ...reasoningMappings
            }
        };
    } catch (error) {
        console.error('[ServerSettings] Failed to read settings:', error.message);
        return {
            ...DEFAULT_SETTINGS,
            modelMappings: { ...DEFAULT_SETTINGS.modelMappings },
            reasoningMappings: { ...DEFAULT_SETTINGS.reasoningMappings }
        };
    }
}

export function setServerSettings(patch = {}) {
    const current = getServerSettings();
    const next = { ...current, ...patch };

    ensureConfigDir();
    writeFileSync(SETTINGS_FILE, JSON.stringify(next, null, 2), { mode: 0o600 });
    return next;
}

export function isMultiAccountRotationEnabled(env = process.env) {
    return env[MULTI_ACCOUNT_ROTATION_ENV] === 'true';
}

export { SETTINGS_FILE, MULTI_ACCOUNT_ROTATION_ENV };

export default {
    getServerSettings,
    setServerSettings,
    isMultiAccountRotationEnabled,
    MULTI_ACCOUNT_ROTATION_ENV,
    SETTINGS_FILE
};
