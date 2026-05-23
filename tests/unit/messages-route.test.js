import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeSettings } from '../../src/server-settings.js';

test('normalizeSettings: ignores legacy accountStrategy values', () => {
  const settings = normalizeSettings({
    accountStrategy: 'round-robin',
    configureClaudeOnStartup: true
  });

  assert.equal('accountStrategy' in settings, false);
  assert.equal(settings.configureClaudeOnStartup, true);
});
