import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeRepositoryPath } from '../../scripts/path-utils.mjs';

test('normalizes Windows repository paths to stable POSIX separators', () => {
  assert.equal(normalizeRepositoryPath('scripts\\verify.mjs'), 'scripts/verify.mjs');
  assert.equal(normalizeRepositoryPath('tests\\infrastructure\\path-utils.test.js'), 'tests/infrastructure/path-utils.test.js');
});

test('keeps already-normalized repository paths unchanged', () => {
  assert.equal(normalizeRepositoryPath('scripts/verify.mjs'), 'scripts/verify.mjs');
});
