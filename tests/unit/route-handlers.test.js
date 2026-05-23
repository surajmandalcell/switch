/**
 * Unit tests for route handlers (no server required).
 * Uses lightweight mock req/res objects to test handler logic in isolation.
 *
 * Covers:
 *  - settings-route.js  (GET/POST /settings/haiku-model)
 *  - claude-config-route.js (POST /claude/config/direct validation)
 *  - accounts-route.js  (POST /accounts/switch validation)
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';

import { SETTINGS_FILE } from '../../src/server-settings.js';

// ─── Mock helpers ─────────────────────────────────────────────────────────────

function mockRes() {
  const res = {
    _status: 200,
    _body: null,
    status(code) { this._status = code; return this; },
    json(body) { this._body = body; return this; }
  };
  return res;
}

function mockReq(body = {}, params = {}, query = {}) {
  return { body, params, query };
}

function snapshotSettingsFile() {
  return existsSync(SETTINGS_FILE)
    ? { exists: true, text: readFileSync(SETTINGS_FILE, 'utf8') }
    : { exists: false, text: null };
}

function restoreSettingsFile(snapshot) {
  if (snapshot.exists) {
    writeFileSync(SETTINGS_FILE, snapshot.text, { mode: 0o600 });
  } else if (existsSync(SETTINGS_FILE)) {
    unlinkSync(SETTINGS_FILE);
  }
}

// ─── settings-route ───────────────────────────────────────────────────────────

import {
  handleGetHaikuModel,
  handleSetHaikuModel,
  handleGetModelMappings,
  handleSetModelMappings,
  handleGetClaudeProxySetting,
  handleSetClaudeProxySetting
} from '../../src/routes/settings-route.js';

test('handleGetHaikuModel: returns current haikuKiloModel', () => {
  const req = mockReq();
  const res = mockRes();
  handleGetHaikuModel(req, res);
  assert.ok(res._body !== null);
  assert.ok('haikuKiloModel' in res._body);
  // Default is now the full model ID
  assert.ok(typeof res._body.haikuKiloModel === 'string');
});

test('handleSetHaikuModel: rejects empty body with 400', async () => {
  const req = mockReq({});
  const res = mockRes();
  await handleSetHaikuModel(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
});

test('handleSetHaikuModel: rejects null body gracefully', async () => {
  const req = { body: null };
  const res = mockRes();
  await handleSetHaikuModel(req, res);
  assert.equal(res._status, 400);
});

test('handleSetHaikuModel: rejects non-string model with 400', async () => {
  const req = mockReq({ haikuKiloModel: 123 });
  const res = mockRes();
  await handleSetHaikuModel(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
});

test('handleGetModelMappings: returns aliases, defaults, models, and current mappings', () => {
  const req = mockReq();
  const res = mockRes();
  handleGetModelMappings(req, res);
  assert.equal(res._status, 200);
  assert.equal(res._body.success, true);
  assert.ok(res._body.aliases.includes('opus'));
  assert.ok(res._body.aliases.includes('sonnet'));
  assert.ok(res._body.aliases.includes('haiku'));
  assert.ok(Array.isArray(res._body.models));
  assert.ok(Array.isArray(res._body.reasoningLevels));
  assert.ok(typeof res._body.modelMappings.haiku === 'string');
  assert.ok(typeof res._body.reasoningMappings.haiku === 'string');
});

test('handleSetModelMappings: rejects unknown alias with 400', () => {
  const req = mockReq({ modelMappings: { wrong: 'gpt-5.5' } });
  const res = mockRes();
  handleSetModelMappings(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
});

test('handleSetModelMappings: rejects unsupported model ID with 400', () => {
  const req = mockReq({ modelMappings: { haiku: 'not-a-real-gpt-model' } });
  const res = mockRes();
  handleSetModelMappings(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
});

test('handleSetModelMappings: rejects unsupported reasoning level with 400', () => {
  const req = mockReq({ reasoningMappings: { haiku: 'extreme' } });
  const res = mockRes();
  handleSetModelMappings(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
});

test('settings-route: does not expose account strategy handlers', async () => {
  const settingsRoute = await import('../../src/routes/settings-route.js');
  assert.equal('handleGetAccountStrategy' in settingsRoute, false);
  assert.equal('handleSetAccountStrategy' in settingsRoute, false);
});

test('handleGetClaudeProxySetting: returns startup configuration flag', () => {
  const req = mockReq();
  const res = mockRes();
  handleGetClaudeProxySetting(req, res);
  assert.equal(res._status, 200);
  assert.equal(res._body.success, true);
  assert.equal(typeof res._body.configureClaudeOnStartup, 'boolean');
});

test('handleSetClaudeProxySetting: persists startup configuration flag', (t) => {
  const settingsSnapshot = snapshotSettingsFile();
  t.after(() => restoreSettingsFile(settingsSnapshot));

  const req = mockReq({ configureClaudeOnStartup: true });
  const res = mockRes();
  handleSetClaudeProxySetting(req, res);
  assert.equal(res._status, 200);
  assert.equal(res._body.success, true);
  assert.equal(res._body.configureClaudeOnStartup, true);
});

test('handleSetClaudeProxySetting: rejects non-boolean startup flag', () => {
  const req = mockReq({ configureClaudeOnStartup: 'true' });
  const res = mockRes();
  handleSetClaudeProxySetting(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
});

// ─── claude-config-route ──────────────────────────────────────────────────────

import { handleSetDirectMode } from '../../src/routes/claude-config-route.js';

test('handleSetDirectMode: rejects missing apiKey with 400', async () => {
  const req = mockReq({});
  const res = mockRes();
  await handleSetDirectMode(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
  assert.equal(res._body.error, 'API key required');
});

test('handleSetDirectMode: rejects null body with 400', async () => {
  const req = { body: null };
  const res = mockRes();
  await handleSetDirectMode(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.error, 'API key required');
});

// ─── accounts-route ───────────────────────────────────────────────────────────

import { handleSwitchAccount } from '../../src/routes/accounts-route.js';

test('handleSwitchAccount: rejects missing email with 400', () => {
  const req = mockReq({});
  const res = mockRes();
  handleSwitchAccount(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
  assert.equal(res._body.message, 'Email is required');
});

test('handleSwitchAccount: rejects null body with 400', () => {
  const req = { body: null };
  const res = mockRes();
  handleSwitchAccount(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.message, 'Email is required');
});

test('handleSwitchAccount: returns result for non-existent email (graceful)', () => {
  // The account doesn't exist, but the handler should still return a JSON response
  const req = mockReq({ email: 'nonexistent@example.com' });
  const res = mockRes();
  handleSwitchAccount(req, res);
  // Should return a response (success or failure) but not throw
  assert.ok(res._body !== null);
  assert.ok('success' in res._body);
});

import { handleAddAccountManual } from '../../src/routes/accounts-route.js';

test('handleAddAccountManual: rejects missing code with 400', async () => {
  const req = mockReq({});
  const res = mockRes();
  await handleAddAccountManual(req, res);
  assert.equal(res._status, 400);
  assert.equal(res._body.success, false);
  assert.equal(res._body.error, 'Code is required');
});
