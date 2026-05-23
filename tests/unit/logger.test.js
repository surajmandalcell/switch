import test from 'node:test';
import assert from 'node:assert/strict';

import { logger } from '../../src/utils/logger.js';

test('logger.response reports total, input, and output token counts from usage', () => {
  logger.clear();

  logger.response(200, {
    model: 'gpt-test',
    usage: {
      input_tokens: 10,
      output_tokens: 7,
      cache_read_input_tokens: 3
    },
    duration: 42
  });

  const [entry] = logger.getHistory();
  assert.equal(entry.level, 'SUCCESS');
  assert.match(entry.message, /tokens=17/);
  assert.match(entry.message, /input=10/);
  assert.match(entry.message, /output=7/);
  assert.match(entry.message, /cache=3/);
});
