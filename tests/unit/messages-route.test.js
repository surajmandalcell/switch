import test from 'node:test';
import assert from 'node:assert/strict';

import { isMultiAccountRotationEnabled, normalizeSettings } from '../../src/server-settings.js';

test('isMultiAccountRotationEnabled: defaults to false for personal local use', () => {
  assert.equal(isMultiAccountRotationEnabled({}), false);
});

test('isMultiAccountRotationEnabled: requires explicit true opt-in', () => {
  assert.equal(isMultiAccountRotationEnabled({
    CODEX_CLAUDE_PROXY_ENABLE_MULTI_ACCOUNT_ROTATION: 'true'
  }), true);
  assert.equal(isMultiAccountRotationEnabled({
    CODEX_CLAUDE_PROXY_ENABLE_MULTI_ACCOUNT_ROTATION: '1'
  }), false);
});

test('normalizeSettings: ignores legacy accountStrategy values', () => {
  const settings = normalizeSettings({
    accountStrategy: 'round-robin',
    configureClaudeOnStartup: true
  });

  assert.equal('accountStrategy' in settings, false);
  assert.equal(settings.configureClaudeOnStartup, true);
});
