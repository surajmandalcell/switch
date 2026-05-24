import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

function mockRes() {
  return {
    _status: 200,
    _body: null,
    status(code) { this._status = code; return this; },
    json(body) { this._body = body; return this; }
  };
}

test('account-route handlers operate on the single configured account', async (t) => {
  const configDir = mkdtempSync(join(tmpdir(), 'codex-proxy-account-route-'));
  const originalConfigDir = process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR;
  process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR = configDir;

  t.after(() => {
    if (originalConfigDir === undefined) {
      delete process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR;
    } else {
      process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR = originalConfigDir;
    }
    rmSync(configDir, { recursive: true, force: true });
  });

  const routeUrl = pathToFileURL(join(process.cwd(), 'src/routes/account-route.js'));
  routeUrl.search = `?route-single-account-test=${Date.now()}-${Math.random()}`;
  const accountRoute = await import(routeUrl.href);
  const accountManager = await import('../../src/account-manager.js');

  const quotaRes = mockRes();
  await accountRoute.handleGetQuota({ query: {} }, quotaRes);
  assert.equal(quotaRes._status, 404);
  assert.equal(quotaRes._body.success, false);
  assert.equal(quotaRes._body.error, 'No account configured');

  const refreshRes = mockRes();
  await accountRoute.handleRefreshAccount({}, refreshRes);
  assert.equal(refreshRes._status, 200);
  assert.equal(refreshRes._body.success, false);
  assert.equal(refreshRes._body.message, 'No account configured');

  accountManager.setConfiguredAccount({
    email: 'route@example.com',
    accountId: 'acc_route',
    accessToken: 'route.token.value',
    refreshToken: 'route-refresh',
    expiresAt: Date.now() + 3600000
  });

  const deleteRes = mockRes();
  accountRoute.handleRemoveAccount({}, deleteRes);
  assert.equal(deleteRes._status, 200);
  assert.equal(deleteRes._body.success, true);
  assert.equal(accountManager.listAccounts().total, 0);
});
