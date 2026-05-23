/**
 * Account Route
 * Handles single-account management endpoints.
 */

import {
  getActiveAccount,
  removeAccount,
  listAccounts,
  refreshActiveAccount,
  importFromCodex,
  updateAccountQuota,
  getAccountQuota,
  loadAccounts,
  saveAccounts,
  updateAccountAuth
} from '../account-manager.js';

import {
  getAuthorizationUrl,
  generatePKCE,
  generateState,
  startCallbackServer,
  exchangeCodeForTokens,
  OAUTH_CONFIG,
  extractCodeFromInput,
  extractAccountInfo,
  getPKCEData
} from '../oauth.js';

import {
  getAccountQuota as fetchAccountQuota
} from '../model-api.js';

import { logger } from '../utils/logger.js';

const activeCallbackServers = new Map();

export function handleGetAccount(req, res) {
  res.json(listAccounts());
}

export function handleAccountStatus(req, res) {
  res.json(listAccounts());
}

export function handleOAuthCleanup(req, res) {
  for (const [, callback] of activeCallbackServers) {
    try { callback.abort(); } catch { /* ignore */ }
  }
  activeCallbackServers.clear();
  res.json({ success: true, message: 'OAuth server cleaned up' });
}

export async function handleAddAccount(req, res) {
  const { port } = req.body || {};
  const callbackPort = port || OAUTH_CONFIG.callbackPort;
  const { verifier } = generatePKCE();
  const state = generateState();

  if (activeCallbackServers.has(callbackPort)) {
    const existing = activeCallbackServers.get(callbackPort);
    if (existing.abort) existing.abort();
    activeCallbackServers.delete(callbackPort);
  }

  let serverResult;
  let actualPort;
  try {
    serverResult = startCallbackServer(state, 120000, { port: callbackPort });
    actualPort = await serverResult.ready;
  } catch (err) {
    return res.status(500).json({
      error: 'Failed to start OAuth callback server',
      message: err.message,
      status: 'error'
    });
  }

  const oauthUrl = getAuthorizationUrl(verifier, state, actualPort);
  activeCallbackServers.set(actualPort, serverResult);

  serverResult.promise
    .then(result => {
      activeCallbackServers.delete(actualPort);
      if (result?.code) {
        return exchangeCodeForTokens(result.code, verifier, actualPort)
          .then(async tokens => {
            const accountInfo = _buildAccountInfo(tokens);
            await _replaceAccount(accountInfo);
            logger.info(`Configured account: ${accountInfo.email}`);
          });
      }
    })
    .catch(err => {
      activeCallbackServers.delete(actualPort);
      logger.error(`OAuth token exchange failed: ${err.message}`);
    });

  res.json({
    status: 'oauth_url',
    oauth_url: oauthUrl,
    callback_port: actualPort
  });
}

export async function handleAddAccountManual(req, res) {
  const { code, verifier, port } = req.body || {};

  if (!code) {
    return res.status(400).json({ success: false, error: 'Code is required' });
  }

  try {
    const { code: extractedCode, state, port: callbackUrlPort } = extractCodeFromInput(code);
    const pkceData = state ? getPKCEData(state) : null;
    const codeVerifier = verifier || pkceData?.verifier;
    const callbackPort = port || callbackUrlPort || pkceData?.port || OAUTH_CONFIG.callbackPort;

    if (!codeVerifier) {
      return res.status(400).json({
        success: false,
        error: 'Verifier is required unless a callback URL with a valid state is provided'
      });
    }

    const tokens = await exchangeCodeForTokens(extractedCode, codeVerifier, callbackPort);
    const accountInfo = _buildAccountInfo(tokens);

    await _replaceAccount(accountInfo);
    const callback = activeCallbackServers.get(callbackPort);
    if (callback?.abort) callback.abort();
    activeCallbackServers.delete(callbackPort);
    logger.info(`Configured account via manual OAuth: ${accountInfo.email}`);
    res.json({ success: true, message: `Account ${accountInfo.email} configured successfully` });
  } catch (err) {
    logger.error(`Manual OAuth failed: ${err.message}`);
    res.status(400).json({ success: false, error: err.message });
  }
}

export async function handleRefreshAccount(req, res) {
  const result = await refreshActiveAccount();
  if (result.success) {
    logger.info(result.message);
  }
  res.json(result);
}

export function handleRemoveAccount(req, res) {
  const result = removeAccount();
  if (result.success) {
    logger.info(result.message);
  }
  res.json(result);
}

export function handleImportAccount(req, res) {
  const result = importFromCodex();
  res.json(result);
}

export async function handleGetQuota(req, res) {
  const { refresh } = req.query;
  const account = getActiveAccount();

  if (!account) {
    return res.status(404).json({
      success: false,
      error: 'No account configured'
    });
  }

  const cachedQuota = getAccountQuota(account.email);
  const isStale = !cachedQuota ||
    (Date.now() - new Date(cachedQuota.lastChecked).getTime() > 5 * 60 * 1000);

  if (refresh === 'true' || isStale) {
    try {
      const quotaData = await fetchAccountQuota(account.accessToken, account.accountId);
      updateAccountQuota(account.email, quotaData);
      res.json({ success: true, email: account.email, quota: quotaData, cached: false });
    } catch (error) {
      logger.error(`Failed to fetch quota: ${error.message}`);
      if (cachedQuota) {
        res.json({
          success: true,
          email: account.email,
          quota: cachedQuota,
          cached: true,
          warning: 'Using cached data due to fetch error'
        });
      } else {
        res.status(500).json({ success: false, error: error.message });
      }
    }
  } else {
    res.json({ success: true, email: account.email, quota: cachedQuota, cached: true });
  }
}

async function _replaceAccount(accountInfo) {
  if (!accountInfo?.email) {
    throw new Error('OAuth response did not include account email');
  }

  const data = loadAccounts();
  data.accounts = [accountInfo];
  data.activeAccount = accountInfo.email;
  saveAccounts(data);
  updateAccountAuth(accountInfo);

  try {
    const quotaData = await fetchAccountQuota(accountInfo.accessToken, accountInfo.accountId);
    updateAccountQuota(accountInfo.email, quotaData);
    logger.info(`Initial quota fetched for: ${accountInfo.email}`);
  } catch (err) {
    logger.warn(`Failed to fetch initial quota for ${accountInfo.email}: ${err.message}`);
  }
}

function _buildAccountInfo(tokens) {
  const tokenInfo = extractAccountInfo(tokens.accessToken);
  return {
    email: tokenInfo?.email || 'unknown',
    accountId: tokenInfo?.accountId,
    planType: tokenInfo?.planType || 'free',
    userId: tokenInfo?.userId,
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    idToken: tokens.idToken,
    expiresAt: tokenInfo?.expiresAt || (Date.now() + tokens.expiresIn * 1000),
    addedAt: new Date().toISOString(),
    lastUsed: null
  };
}

export default {
  handleGetAccount,
  handleAccountStatus,
  handleOAuthCleanup,
  handleAddAccount,
  handleAddAccountManual,
  handleRefreshAccount,
  handleRemoveAccount,
  handleImportAccount,
  handleGetQuota
};
