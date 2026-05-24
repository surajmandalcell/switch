import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

async function importAccountManagerForConfig(configDir) {
  const originalConfigDir = process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR;
  process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR = configDir;

  const moduleUrl = pathToFileURL(join(process.cwd(), 'src/account-manager.js'));
  moduleUrl.search = `?single-account-test=${Date.now()}-${Math.random()}`;
  const accountManager = await import(moduleUrl.href);

  return {
    accountManager,
    restoreEnv() {
      if (originalConfigDir === undefined) {
        delete process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR;
      } else {
        process.env.CODEX_CLAUDE_PROXY_CONFIG_DIR = originalConfigDir;
      }
    }
  };
}

test('account-manager: migrates legacy registry to the selected account only', async (t) => {
  const configDir = mkdtempSync(join(tmpdir(), 'codex-proxy-single-account-'));
  const { accountManager, restoreEnv } = await importAccountManagerForConfig(configDir);

  t.after(() => {
    restoreEnv();
    rmSync(configDir, { recursive: true, force: true });
  });

  assert.equal(accountManager.CONFIG_DIR, configDir);

  accountManager.saveAccounts({
    version: 1,
    activeAccount: 'second@example.com',
    accounts: [
      {
        email: 'first@example.com',
        accountId: 'acc_first',
        accessToken: 'first.token.value',
        refreshToken: 'first-refresh',
        idToken: 'first-id',
        expiresAt: Date.now() + 3600000
      },
      {
        email: 'second@example.com',
        accountId: 'acc_second',
        accessToken: 'second.token.value',
        refreshToken: 'second-refresh',
        idToken: 'second-id',
        expiresAt: Date.now() + 3600000
      }
    ]
  });

  const data = accountManager.loadAccounts();
  const listed = accountManager.listAccounts();
  const raw = JSON.parse(readFileSync(accountManager.ACCOUNT_FILE, 'utf8'));

  assert.equal(data.accounts.length, 1);
  assert.equal(data.activeAccount, 'second@example.com');
  assert.equal(data.accounts[0].email, 'second@example.com');
  assert.equal(raw.account.email, 'second@example.com');
  assert.equal(raw.accounts, undefined);
  assert.equal(listed.total, 1);
  assert.equal(listed.account.email, 'second@example.com');
  assert.equal(listed.accounts, undefined);
});

test('account-manager: setting a new account replaces the existing account', async (t) => {
  const configDir = mkdtempSync(join(tmpdir(), 'codex-proxy-single-account-'));
  const { accountManager, restoreEnv } = await importAccountManagerForConfig(configDir);

  t.after(() => {
    restoreEnv();
    rmSync(configDir, { recursive: true, force: true });
  });

  accountManager.setConfiguredAccount({
    email: 'first@example.com',
    accountId: 'acc_first',
    accessToken: 'first.token.value',
    refreshToken: 'first-refresh',
    expiresAt: Date.now() + 3600000
  });

  const result = accountManager.setConfiguredAccount({
    email: 'second@example.com',
    accountId: 'acc_second',
    accessToken: 'second.token.value',
    refreshToken: 'second-refresh',
    expiresAt: Date.now() + 3600000
  });

  const data = accountManager.loadAccounts();
  const listed = accountManager.listAccounts();
  const raw = JSON.parse(readFileSync(accountManager.ACCOUNT_FILE, 'utf8'));
  const auth = JSON.parse(readFileSync(accountManager.ACCOUNT_AUTH_FILE, 'utf8'));

  assert.equal(result.success, true);
  assert.equal(data.accounts.length, 1);
  assert.equal(data.activeAccount, 'second@example.com');
  assert.equal(data.accounts[0].email, 'second@example.com');
  assert.equal(listed.total, 1);
  assert.equal(listed.account.email, 'second@example.com');
  assert.equal(raw.account.email, 'second@example.com');
  assert.equal(raw.accounts, undefined);
  assert.equal(auth.tokens.access_token, 'second.token.value');
});

test('account-manager: removeAccount clears the configured account and auth file', async (t) => {
  const configDir = mkdtempSync(join(tmpdir(), 'codex-proxy-single-account-'));
  const { accountManager, restoreEnv } = await importAccountManagerForConfig(configDir);

  t.after(() => {
    restoreEnv();
    rmSync(configDir, { recursive: true, force: true });
  });

  accountManager.setConfiguredAccount({
    email: 'configured@example.com',
    accountId: 'acc_configured',
    accessToken: 'configured.token.value',
    refreshToken: 'configured-refresh',
    expiresAt: Date.now() + 3600000
  });

  assert.equal(existsSync(accountManager.ACCOUNT_AUTH_FILE), true);

  const result = accountManager.removeAccount();
  const data = accountManager.loadAccounts();
  const listed = accountManager.listAccounts();
  const raw = JSON.parse(readFileSync(accountManager.ACCOUNT_FILE, 'utf8'));

  assert.equal(result.success, true);
  assert.equal(data.accounts.length, 0);
  assert.equal(data.activeAccount, null);
  assert.equal(listed.total, 0);
  assert.equal(listed.account, null);
  assert.equal(raw.account, null);
  assert.equal(raw.activeAccount, null);
  assert.equal(raw.accounts, undefined);
  assert.equal(existsSync(accountManager.ACCOUNT_AUTH_FILE), false);
});

test('account-manager: quota helpers only operate on the configured account', async (t) => {
  const configDir = mkdtempSync(join(tmpdir(), 'codex-proxy-single-account-'));
  const { accountManager, restoreEnv } = await importAccountManagerForConfig(configDir);

  t.after(() => {
    restoreEnv();
    rmSync(configDir, { recursive: true, force: true });
  });

  accountManager.setConfiguredAccount({
    email: 'quota@example.com',
    accountId: 'acc_quota',
    accessToken: 'quota.token.value',
    refreshToken: 'quota-refresh',
    expiresAt: Date.now() + 3600000
  });

  const wrongResult = accountManager.updateAccountQuota('other@example.com', { percentage: 99 });
  const rightResult = accountManager.updateAccountQuota('quota@example.com', { percentage: 42 });

  assert.equal(wrongResult.success, false);
  assert.equal(rightResult.success, true);
  assert.equal(accountManager.getAccountQuota('other@example.com'), null);
  assert.equal(accountManager.getAccountQuota('quota@example.com').percentage, 42);
});
