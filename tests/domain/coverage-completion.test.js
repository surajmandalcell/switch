import test from 'node:test';
import assert from 'node:assert/strict';
import { fromOpenAIChat } from '../../src/domain/protocol/openai.js';
import { selectCandidate } from '../../src/domain/routing/strategies.js';

test('weighted routing covers its final fallback', () => {
  const items = [
    { provider: { id: 'p' }, account: { id: 'a', priority: 1, weight: 1 }, runtime: {} },
    { provider: { id: 'p' }, account: { id: 'b', priority: 2, weight: 1 }, runtime: {} },
  ];
  assert.equal(selectCandidate('weighted-random', items, { random: () => 2 }).account.id, 'b');
});

test('OpenAI content conversion ignores unsupported blocks', () => {
  const request = fromOpenAIChat({ model: 'm', messages: [{ role: 'user', content: [{ type: 'unknown' }] }] });
  assert.deepEqual(request.messages[0].content, []);
});
