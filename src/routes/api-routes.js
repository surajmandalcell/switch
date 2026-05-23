/**
 * API Routes
 * Thin registration layer — wires all route modules to the Express app.
 * Business logic lives in the individual route files under src/routes/.
 */

import express from 'express';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

import { getStatus, ACCOUNT_FILE } from '../account-manager.js';

// Route handlers
import { handleMessages } from './messages-route.js';
import { handleChatCompletion, handleCountTokens } from './chat-route.js';
import { handleListModels, handleAccountModels, handleAccountUsage } from './models-route.js';
import {
  handleGetHaikuModel,
  handleSetHaikuModel,
  handleGetKiloModels,
  handleGetModelMappings,
  handleSetModelMappings,
  handleGetClaudeProxySetting,
  handleSetClaudeProxySetting
} from './settings-route.js';
import { handleGetLogs, handleStreamLogs } from './logs-route.js';
import { handleGetMetricsRecent, handleGetMetricsStorage, handleGetMetricsSummary } from './metrics-route.js';
import { handleGetClaudeConfig, handleSetProxyMode, handleSetDirectMode, handleSetClaudeApiEndpoint } from './claude-config-route.js';
import {
  handleGetAccount,
  handleAccountStatus,
  handleOAuthCleanup,
  handleAddAccount,
  handleAddAccountManual,
  handleRefreshAccount,
  handleRemoveAccount,
  handleImportAccount,
  handleGetQuota
} from './account-route.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const alpineDistDir = dirname(require.resolve('alpinejs/dist/cdn.min.js'));

export function registerApiRoutes(app, { port }) {
  // ─── Static Web UI ─────────────────────────────────────────────────────────
  app.use('/vendor/alpine', express.static(alpineDistDir));
  app.use(express.static(join(__dirname, '..', '..', 'public')));

  // ─── Health ────────────────────────────────────────────────────────────────
  app.get('/health', (req, res) => {
    res.json({ status: 'ok', ...getStatus(), configPath: ACCOUNT_FILE });
  });

  // ─── Anthropic Messages API ────────────────────────────────────────────────
  app.post('/v1/messages', handleMessages);
  app.post('/v1/messages/count_tokens', handleCountTokens);

  // ─── OpenAI Chat Completions API ───────────────────────────────────────────
  app.post('/v1/chat/completions', handleChatCompletion);

  // ─── Models ────────────────────────────────────────────────────────────────
  app.get('/v1/models', handleListModels);
  app.get('/account/models', handleAccountModels);
  app.get('/account/usage', handleAccountUsage);

  // ─── Settings ──────────────────────────────────────────────────────────────
  app.get('/settings/haiku-model', handleGetHaikuModel);
  app.post('/settings/haiku-model', handleSetHaikuModel);
  app.get('/settings/kilo-models', handleGetKiloModels);
  app.get('/settings/model-mappings', handleGetModelMappings);
  app.post('/settings/model-mappings', handleSetModelMappings);
  app.get('/settings/claude-proxy', handleGetClaudeProxySetting);
  app.post('/settings/claude-proxy', handleSetClaudeProxySetting);

  // ─── Account Management ───────────────────────────────────────────────────
  app.get('/account', handleGetAccount);
  app.get('/account/status', handleAccountStatus);
  app.get('/account/quota', handleGetQuota);

  app.post('/account/add', handleAddAccount);
  app.post('/account/add/manual', handleAddAccountManual);
  app.post('/account/import', handleImportAccount);
  app.post('/account/refresh', handleRefreshAccount);
  app.post('/account/oauth/cleanup', handleOAuthCleanup);

  app.delete('/account', handleRemoveAccount);

  // ─── Claude CLI Configuration ──────────────────────────────────────────────
  app.get('/claude/config', handleGetClaudeConfig);
  app.post('/claude/config/proxy', (req, res) => handleSetProxyMode(req, res, { port }));
  app.post('/claude/config/direct', handleSetDirectMode);
  app.post('/claude/config/set', handleSetClaudeApiEndpoint);

  // ─── Logs ──────────────────────────────────────────────────────────────────
  app.get('/api/logs', handleGetLogs);
  app.get('/api/logs/stream', handleStreamLogs);

  // ─── Metrics ───────────────────────────────────────────────────────────────
  app.get('/api/metrics/summary', handleGetMetricsSummary);
  app.get('/api/metrics/recent', handleGetMetricsRecent);
  app.get('/api/metrics/storage', handleGetMetricsStorage);
}

export default { registerApiRoutes };
