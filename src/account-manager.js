/**
 * Account Manager
 * Manages one local ChatGPT account for personal proxy use.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { refreshAccessToken, extractAccountInfo } from './oauth.js';
import { getAccountQuota as fetchQuota } from './model-api.js';

const CONFIG_DIR_ENV = 'CODEX_CLAUDE_PROXY_CONFIG_DIR';
const CONFIG_DIR = process.env[CONFIG_DIR_ENV] || join(homedir(), '.codex-claude-proxy');
const ACCOUNT_FILE = join(CONFIG_DIR, 'account.json');
const LEGACY_ACCOUNTS_FILE = join(CONFIG_DIR, 'accounts.json');
const ACCOUNT_AUTH_FILE = join(CONFIG_DIR, 'auth.json');

const TOKEN_REFRESH_INTERVAL_MS = 55 * 60 * 1000;
const TOKEN_EXPIRY_BUFFER_MS = 5 * 60 * 1000;

const DEFAULT_STATE = {
    accounts: [],
    activeAccount: null,
    version: 2
};

let autoRefreshIntervalId = null;
let startupRefreshTimeoutId = null;
const tokenCache = new Map();
let accountsData = null;

function ensureConfigDir() {
    if (!existsSync(CONFIG_DIR)) {
        mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
    }
}

function normalizeAccount(account) {
    if (!account || typeof account !== 'object' || !account.email) {
        return null;
    }

    return {
        ...account,
        lastUsed: account.lastUsed || null
    };
}

function pickConfiguredAccount(data = {}) {
    const directAccount = normalizeAccount(data.account);
    if (directAccount) return directAccount;

    if (!Array.isArray(data.accounts) || data.accounts.length === 0) {
        return null;
    }

    const active = data.accounts.find((account) => account?.email === data.activeAccount);
    return normalizeAccount(active || data.accounts[0]);
}

function normalizeState(data = {}) {
    const account = pickConfiguredAccount(data);
    return {
        accounts: account ? [account] : [],
        activeAccount: account?.email || null,
        version: 2
    };
}

function serializeState(state) {
    const account = state.accounts[0] || null;
    return {
        account,
        activeAccount: account?.email || null,
        version: 2
    };
}

function readJsonFile(path) {
    return JSON.parse(readFileSync(path, 'utf8'));
}

function writeState(data) {
    ensureConfigDir();
    accountsData = normalizeState(data);
    writeFileSync(ACCOUNT_FILE, JSON.stringify(serializeState(accountsData), null, 2), { mode: 0o600 });
    return accountsData;
}

function loadAccounts() {
    if (accountsData !== null) {
        return accountsData;
    }

    ensureConfigDir();

    try {
        if (existsSync(ACCOUNT_FILE)) {
            accountsData = normalizeState(readJsonFile(ACCOUNT_FILE));
            return accountsData;
        }

        if (existsSync(LEGACY_ACCOUNTS_FILE)) {
            return writeState(readJsonFile(LEGACY_ACCOUNTS_FILE));
        }
    } catch (error) {
        console.error('[AccountManager] Error loading account:', error.message);
    }

    accountsData = { ...DEFAULT_STATE };
    return accountsData;
}

function saveAccounts(data) {
    return writeState(data);
}

function save() {
    return writeState(accountsData || loadAccounts());
}

function getAccount(email) {
    const account = getActiveAccount();
    if (!email) return account;
    return account?.email === email ? account : null;
}

function getActiveAccount() {
    const data = loadAccounts();
    return data.accounts[0] || null;
}

function updateAccountAuth(account) {
    if (!account) return;

    const authData = {
        auth_mode: 'chatgpt',
        OPENAI_API_KEY: null,
        tokens: {
            id_token: account.idToken,
            access_token: account.accessToken,
            refresh_token: account.refreshToken,
            account_id: account.accountId
        },
        last_refresh: new Date().toISOString()
    };

    try {
        ensureConfigDir();
        writeFileSync(ACCOUNT_AUTH_FILE, JSON.stringify(authData, null, 2), { mode: 0o600 });
        console.log(`[AccountManager] Updated auth for: ${account.email}`);
    } catch (error) {
        console.error('[AccountManager] Failed to update auth:', error.message);
    }
}

function setConfiguredAccount(account) {
    const normalized = normalizeAccount(account);
    if (!normalized) {
        return { success: false, message: 'No valid account provided' };
    }

    const state = saveAccounts({
        accounts: [normalized],
        activeAccount: normalized.email,
        version: 2
    });
    updateAccountAuth(state.accounts[0]);
    return { success: true, message: `Configured account: ${normalized.email}` };
}

function removeAccount() {
    const account = getActiveAccount();
    if (!account) {
        return { success: false, message: 'No account configured' };
    }

    try {
        if (existsSync(ACCOUNT_AUTH_FILE)) {
            rmSync(ACCOUNT_AUTH_FILE, { force: true });
        }
    } catch (error) {
        console.error('[AccountManager] Failed to remove auth file:', error.message);
    }

    saveAccounts(DEFAULT_STATE);
    tokenCache.clear();
    return { success: true, message: `Account removed: ${account.email}` };
}

function listAccounts() {
    const account = getActiveAccount();
    const info = account ? extractAccountInfo(account.accessToken) : null;
    const publicAccount = account ? {
        email: account.email,
        accountId: account.accountId,
        planType: info?.planType || account.planType || 'unknown',
        addedAt: account.addedAt,
        lastUsed: account.lastUsed,
        isActive: true,
        tokenExpired: info?.expiresAt ? info.expiresAt < Date.now() : false,
        quota: account.quota || null
    } : null;

    return {
        account: publicAccount,
        activeAccount: publicAccount?.email || null,
        total: publicAccount ? 1 : 0
    };
}

function updateAccountQuota(email, quotaData) {
    const data = loadAccounts();
    const account = data.accounts[0];

    if (!account || (email && account.email !== email)) {
        return { success: false, message: email ? `Account not found: ${email}` : 'No account configured' };
    }

    account.quota = {
        ...quotaData,
        lastChecked: new Date().toISOString()
    };

    saveAccounts(data);
    return { success: true, message: `Quota updated for: ${account.email}` };
}

function getAccountQuota(email) {
    const account = getActiveAccount();
    if (!account || (email && account.email !== email)) {
        return null;
    }
    return account.quota || null;
}

function isTokenExpiredOrExpiringSoon(account) {
    if (!account?.expiresAt) return true;
    return Date.now() >= (account.expiresAt - TOKEN_EXPIRY_BUFFER_MS);
}

async function refreshAccountToken(email) {
    const account = getActiveAccount();

    if (!account || (email && account.email !== email)) {
        return { success: false, message: email ? `Account not found: ${email}` : 'No account configured' };
    }

    if (!account.refreshToken) {
        return { success: false, message: 'No refresh token available' };
    }

    try {
        const tokens = await refreshAccessToken(account.refreshToken);
        const accountInfo = extractAccountInfo(tokens.accessToken);
        const updatedAccount = {
            ...account,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken || account.refreshToken,
            idToken: tokens.idToken || account.idToken,
            expiresAt: accountInfo?.expiresAt || (Date.now() + tokens.expiresIn * 1000),
            planType: accountInfo?.planType || account.planType
        };

        setConfiguredAccount(updatedAccount);
        tokenCache.set(updatedAccount.email, {
            token: updatedAccount.accessToken,
            extractedAt: Date.now()
        });

        console.log(`[AccountManager] Token refreshed for: ${updatedAccount.email}`);

        try {
            const quotaData = await fetchQuota(updatedAccount.accessToken, updatedAccount.accountId);
            updateAccountQuota(updatedAccount.email, quotaData);
            console.log(`[AccountManager] Quota refreshed for: ${updatedAccount.email}`);
        } catch (error) {
            console.warn(`[AccountManager] Failed to auto-fetch quota for ${updatedAccount.email}: ${error.message}`);
        }

        return { success: true, message: `Token refreshed for: ${updatedAccount.email}` };
    } catch (error) {
        console.error(`[AccountManager] Token refresh failed for ${account.email}:`, error.message);
        return { success: false, message: `Token refresh failed: ${error.message}` };
    }
}

function startAutoRefresh() {
    if (autoRefreshIntervalId) {
        clearInterval(autoRefreshIntervalId);
    }
    if (startupRefreshTimeoutId) {
        clearTimeout(startupRefreshTimeoutId);
    }

    startupRefreshTimeoutId = setTimeout(async () => {
        const account = getActiveAccount();
        if (account?.refreshToken) {
            console.log(`[AccountManager] Startup refresh for ${account.email}`);
            await refreshAccountToken(account.email);
        }
    }, 2000);
    startupRefreshTimeoutId.unref?.();

    autoRefreshIntervalId = setInterval(async () => {
        const account = getActiveAccount();
        if (account?.refreshToken) {
            console.log(`[AccountManager] Periodic refresh for ${account.email}`);
            await refreshAccountToken(account.email);
        }
    }, TOKEN_REFRESH_INTERVAL_MS);
    autoRefreshIntervalId.unref?.();

    console.log('[AccountManager] Auto-refresh started (every 55 minutes)');
}

function stopAutoRefresh() {
    if (startupRefreshTimeoutId) {
        clearTimeout(startupRefreshTimeoutId);
        startupRefreshTimeoutId = null;
    }
    if (autoRefreshIntervalId) {
        clearInterval(autoRefreshIntervalId);
        autoRefreshIntervalId = null;
        console.log('[AccountManager] Auto-refresh stopped');
    }
}

function getCachedToken(email) {
    const cached = tokenCache.get(email);
    if (cached && (Date.now() - cached.extractedAt) < TOKEN_REFRESH_INTERVAL_MS) {
        return cached.token;
    }
    return null;
}

function setCachedToken(email, token) {
    tokenCache.set(email, { token, extractedAt: Date.now() });
}

async function refreshActiveAccount() {
    const account = getActiveAccount();
    if (!account) {
        return { success: false, message: 'No account configured' };
    }
    return refreshAccountToken(account.email);
}

function importFromCodex() {
    const codexAuthFile = join(homedir(), '.codex', 'auth.json');

    try {
        if (!existsSync(codexAuthFile)) {
            return { success: false, message: 'No Codex auth.json found' };
        }

        const codexAuth = readJsonFile(codexAuthFile);

        if (!codexAuth.tokens?.access_token) {
            return { success: false, message: 'No valid tokens in Codex auth.json' };
        }

        const info = extractAccountInfo(codexAuth.tokens.access_token);
        const account = {
            email: info?.email || 'imported@unknown.com',
            accountId: codexAuth.tokens.account_id,
            planType: info?.planType || 'unknown',
            accessToken: codexAuth.tokens.access_token,
            refreshToken: codexAuth.tokens.refresh_token,
            idToken: codexAuth.tokens.id_token,
            expiresAt: info?.expiresAt,
            addedAt: new Date().toISOString(),
            lastUsed: new Date().toISOString(),
            source: 'imported'
        };

        setConfiguredAccount(account);

        return {
            success: true,
            message: `Imported account: ${account.email} (${account.planType})`
        };
    } catch (error) {
        return { success: false, message: `Import failed: ${error.message}` };
    }
}

function getStatus() {
    const { account, activeAccount, total } = listAccounts();
    return {
        total,
        active: activeAccount,
        account
    };
}

function ensureAccountsPersist() {
    const account = getActiveAccount();
    if (account) {
        updateAccountAuth(account);
        console.log(`[AccountManager] Restored account: ${account.email}`);
    }
}

export {
    loadAccounts,
    saveAccounts,
    save,
    getAccount,
    getActiveAccount,
    setConfiguredAccount,
    removeAccount,
    listAccounts,
    refreshActiveAccount,
    refreshAccountToken,
    importFromCodex,
    getStatus,
    updateAccountAuth,
    ensureAccountsPersist,
    updateAccountQuota,
    getAccountQuota,
    startAutoRefresh,
    stopAutoRefresh,
    isTokenExpiredOrExpiringSoon,
    getCachedToken,
    setCachedToken,
    TOKEN_REFRESH_INTERVAL_MS,
    ACCOUNT_FILE,
    LEGACY_ACCOUNTS_FILE,
    ACCOUNT_AUTH_FILE,
    CONFIG_DIR
};

export default {
    getActiveAccount,
    setConfiguredAccount,
    removeAccount,
    listAccounts,
    refreshActiveAccount,
    refreshAccountToken,
    importFromCodex,
    getStatus,
    ensureAccountsPersist,
    updateAccountQuota,
    getAccountQuota
};
