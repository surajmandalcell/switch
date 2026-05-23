import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { CONFIG_DIR } from './account-manager.js';

const SETTINGS_FILE = join(CONFIG_DIR, 'settings.json');
const MULTI_ACCOUNT_ROTATION_ENV = 'CODEX_CLAUDE_PROXY_ENABLE_MULTI_ACCOUNT_ROTATION';

const DEFAULT_SETTINGS = {
    haikuKiloModel: 'minimax/minimax-m2.5:free',
    accountStrategy: 'sticky'
};

function ensureConfigDir() {
    if (!existsSync(CONFIG_DIR)) {
        mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
    }
}

export function getServerSettings() {
    ensureConfigDir();

    if (!existsSync(SETTINGS_FILE)) {
        return { ...DEFAULT_SETTINGS };
    }

    try {
        const data = JSON.parse(readFileSync(SETTINGS_FILE, 'utf8'));
        return { ...DEFAULT_SETTINGS, ...data };
    } catch (error) {
        console.error('[ServerSettings] Failed to read settings:', error.message);
        return { ...DEFAULT_SETTINGS };
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
