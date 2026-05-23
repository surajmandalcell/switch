import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { existsSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { stopAutoRefresh } from '../../src/account-manager.js';
import { getServerSettings, setServerSettings, SETTINGS_FILE } from '../../src/server-settings.js';
import { configureClaudeOnStartup, DEFAULT_HOST, startServer } from '../../src/server.js';

test('startServer: binds to loopback by default', async (t) => {
  const originalClaudeConfigPath = process.env.CLAUDE_CONFIG_PATH;
  const hadSettingsFile = existsSync(SETTINGS_FILE);
  const originalSettingsText = hadSettingsFile ? readFileSync(SETTINGS_FILE, 'utf8') : null;
  const claudeConfigDir = mkdtempSync(join(tmpdir(), 'codex-proxy-claude-start-'));

  process.env.CLAUDE_CONFIG_PATH = claudeConfigDir;
  setServerSettings({ ...getServerSettings(), configureClaudeOnStartup: false });

  const server = startServer({ port: 0 });
  t.after(() => {
    stopAutoRefresh();
    server.close();
    if (originalClaudeConfigPath === undefined) {
      delete process.env.CLAUDE_CONFIG_PATH;
    } else {
      process.env.CLAUDE_CONFIG_PATH = originalClaudeConfigPath;
    }
    if (hadSettingsFile) {
      writeFileSync(SETTINGS_FILE, originalSettingsText, { mode: 0o600 });
    } else if (existsSync(SETTINGS_FILE)) {
      unlinkSync(SETTINGS_FILE);
    }
    rmSync(claudeConfigDir, { recursive: true, force: true });
  });
  await once(server, 'listening');

  assert.equal(DEFAULT_HOST, '127.0.0.1');
  assert.equal(server.address().address, '127.0.0.1');
});

test('configureClaudeOnStartup: writes Claude proxy config when enabled', async (t) => {
  const originalClaudeConfigPath = process.env.CLAUDE_CONFIG_PATH;
  const hadSettingsFile = existsSync(SETTINGS_FILE);
  const originalSettingsText = hadSettingsFile ? readFileSync(SETTINGS_FILE, 'utf8') : null;
  const claudeConfigDir = mkdtempSync(join(tmpdir(), 'codex-proxy-claude-'));

  t.after(() => {
    if (originalClaudeConfigPath === undefined) {
      delete process.env.CLAUDE_CONFIG_PATH;
    } else {
      process.env.CLAUDE_CONFIG_PATH = originalClaudeConfigPath;
    }

    if (hadSettingsFile) {
      writeFileSync(SETTINGS_FILE, originalSettingsText, { mode: 0o600 });
    } else if (existsSync(SETTINGS_FILE)) {
      unlinkSync(SETTINGS_FILE);
    }

    rmSync(claudeConfigDir, { recursive: true, force: true });
  });

  process.env.CLAUDE_CONFIG_PATH = claudeConfigDir;
  const originalSettings = getServerSettings();
  setServerSettings({ ...originalSettings, configureClaudeOnStartup: true });

  const result = await configureClaudeOnStartup({ port: 38123 });
  const claudeConfig = JSON.parse(readFileSync(join(claudeConfigDir, 'settings.json'), 'utf8'));

  assert.equal(result.configured, true);
  assert.equal(claudeConfig.env.ANTHROPIC_BASE_URL, 'http://localhost:38123');
  assert.equal(claudeConfig.env.ANTHROPIC_API_KEY, 'sk-ant-proxy');
});
