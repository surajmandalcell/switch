import test from 'node:test';
import assert from 'node:assert/strict';
import { asFiniteNumber, clamp, deepClone, globToRegExp, matchesGlob, stableStringify } from '../../src/domain/shared.js';
import { canonicalRequest, normalizeBlocks } from '../../src/domain/protocol/canonical.js';
import { fromOpenAIChat, fromOpenAIResponses, openAIChatStream, openAIResponseStream, openAIChunkToCanonical, toOpenAIChat } from '../../src/domain/protocol/openai.js';
import { fromAnthropicMessages, toAnthropicMessage, AnthropicStreamState } from '../../src/domain/protocol/anthropic.js';
import { toGeminiRequest, fromGeminiResponse, geminiChunkToCanonical } from '../../src/domain/protocol/gemini.js';
import { evaluateAccountLimits } from '../../src/domain/routing/limits.js';
import { StrategyState, selectCandidate } from '../../src/domain/routing/strategies.js';
import { classifyUpstreamError, parseRetryAfter } from '../../src/domain/routing/errors.js';
import { UsageService } from '../../src/application/usage-service.js';
import { RoutingService } from '../../src/application/routing-service.js';
import { ProviderRegistry } from '../../src/application/provider-registry.js';
import { RuntimeState } from '../../src/application/runtime-state.js';
import { createDefaultConfig, createProvider, createAccount } from '../../src/domain/config.js';

test('shared helpers cover finite, clone, glob, clamp, and stable ordering branches', () => {
  assert.equal(clamp(20, 0, 10), 10); assert.equal(clamp(-1, 0, 10), 0); assert.equal(clamp(5, 0, 10), 5);
  assert.equal(asFiniteNumber('4'), 4); assert.equal(asFiniteNumber('bad', 9), 9);
  assert.equal(deepClone(undefined), undefined); const copy = deepClone({ b: [1] }); copy.b.push(2);
  assert.ok(globToRegExp('gpt-?.*').test('gpt-5.x')); assert.equal(matchesGlob('Claude-4', 'claude-*'), true); assert.equal(matchesGlob('x', 'y'), false);
  assert.equal(stableStringify({ z: 1, a: [2, { y: true, x: null }] }), '{"a":[2,{"x":null,"y":true}],"z":1}');
});

test('canonical block normalization ignores unknown and non-object values', () => {
  assert.deepEqual(normalizeBlocks([null, 4, { type: 'unknown' }]), []);
  assert.deepEqual(normalizeBlocks({ custom: true }), [{ type: 'text', text: '[object Object]' }]);
});

test('OpenAI conversion covers image variants, invalid arguments, stop arrays, and tool choice', () => {
  const request = fromOpenAIChat({ model: 'm', stop: 'END', tool_choice: 'auto', messages: [{ role: 'user', content: [{ type: 'input_image', image_url: 'https://x' }] }, { role: 'assistant', tool_calls: [{ id: 'c', function: { name: 'f', arguments: '{bad' } }] }] });
  assert.equal(request.messages[0].content[0].url, 'https://x'); assert.deepEqual(request.messages[1].content[0].input, {}); assert.deepEqual(request.stopSequences, ['END']); assert.equal(request.toolChoice, 'auto');
  const arrayStop = fromOpenAIChat({ model: 'm', stop: ['A','B'], messages: [] }); assert.deepEqual(arrayStop.stopSequences, ['A','B']);
});

test('OpenAI Responses covers string input and ignored non-function tools', () => {
  const request = fromOpenAIResponses({ model: 'm', input: 'hello', tools: [{ type: 'web_search' }, { type: 'function', name: 'f' }] });
  assert.equal(request.messages[0].content[0].text, 'hello'); assert.equal(request.tools.length, 1);
});

test('OpenAI stream serializers cover start, tool, usage, finish, and fallback events', () => {
  assert.equal(openAIChatStream({ type: 'start' }, { id: 'r', model: 'm' }).choices[0].delta.role, 'assistant');
  assert.equal(openAIChatStream({ type: 'tool-call', id: 'c', name: 'f', argumentsDelta: '{', index: 2 }, { id: 'r', model: 'm' }).choices[0].delta.tool_calls[0].index, 2);
  assert.equal(openAIChatStream({ type: 'usage', usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3 } }, { id: 'r', model: 'm' }).usage.total_tokens, 3);
  assert.equal(openAIResponseStream({ type: 'start' }, { id: 'r', model: 'm' }).type, 'response.created');
  assert.equal(openAIResponseStream({ type: 'tool-call', id: 'c', argumentsDelta: 'x' }, { id: 'r', model: 'm' }).type, 'response.function_call_arguments.delta');
  assert.equal(openAIResponseStream({ type: 'finish' }, { id: 'r', model: 'm' }).type, 'response.completed');
  assert.equal(openAIResponseStream({ type: 'usage' }, { id: 'r', model: 'm' }).type, 'response.in_progress');
});

test('OpenAI response and chunk fallbacks cover empty content and length finish', () => {
  const response = toOpenAIChat({ model: 'm', content: [], stopReason: 'other' }); assert.equal(response.choices[0].message.content, null); assert.equal(response.choices[0].finish_reason, 'stop');
  const events = openAIChunkToCanonical({ choices: [{ delta: {}, finish_reason: 'length' }] }); assert.equal(events[0].stopReason, 'max_tokens');
});

test('Anthropic conversion covers empty content, tool errors, unknown blocks, and fallback stops', () => {
  const request = fromAnthropicMessages({ model: 'm', system: null, messages: [{ role: 'user', content: [{ type: 'tool_result', tool_use_id: 'c', is_error: true, content: [{ type: 'text', text: 'bad' }] }, { type: 'unknown' }] }] });
  assert.equal(request.system.length, 0); assert.equal(request.messages[0].content[0].isError, true);
  const response = toAnthropicMessage({ model: 'm', content: [{ type: 'image', url: 'x' }], stopReason: 'unknown' }); assert.equal(response.content.length, 0); assert.equal(response.stop_reason, 'end_turn');
});

test('Anthropic stream covers start, first tool without delta, usage, and ignored events', () => {
  const state = new AnthropicStreamState({ id: 'r', model: 'm' });
  assert.equal(state.serialize({ type: 'start' })[0].event, 'message_start');
  assert.equal(state.serialize({ type: 'tool-call', id: 'c', name: 'f' }).length, 1);
  assert.equal(state.serialize({ type: 'usage', usage: { outputTokens: 3 } })[0].data.usage.output_tokens, 3);
  assert.deepEqual(state.serialize({ type: 'unknown' }), []);
});

test('Gemini payload covers URL images, assistant tools, absent generation values, and stop sequences', () => {
  const request = canonicalRequest({ model: 'm', messages: [{ role: 'assistant', content: [{ type: 'image', url: 'gs://x', mediaType: 'image/jpeg' }, { type: 'tool-call', id: 'c', name: 'f', input: {}, thoughtSignature: 'sig' }] }], stopSequences: ['STOP'] });
  const payload = toGeminiRequest(request); assert.equal(payload.contents[0].role, 'model'); assert.equal(payload.contents[0].parts[0].fileData.fileUri, 'gs://x'); assert.equal(payload.contents[0].parts[1].thoughtSignature, 'sig'); assert.deepEqual(payload.generationConfig.stopSequences, ['STOP']);
});

test('Gemini response covers unknown finish and no candidates', () => {
  assert.equal(fromGeminiResponse({}, 'm').content.length, 0);
  assert.equal(fromGeminiResponse({ candidates: [{ finishReason: 'OTHER', content: { parts: [] } }] }, 'm').stopReason, 'end_turn');
  assert.equal(fromGeminiResponse({ candidates: [{ finishReason: 'MALFORMED_FUNCTION_CALL', content: { parts: [] } }] }, 'm').stopReason, 'tool_use');
  assert.deepEqual(geminiChunkToCanonical({}), []);
});

test('account limits use callback-backed observations and period boundaries', () => {
  const account = createAccount({ id: 'a', limits: { requestsPerMinute: 3, tokensPerDay: 4, tokensPerMonth: 5, costPerMonthUsd: 6 } });
  const calls = []; const usage = { requestsSince(id, since) { calls.push(['r', id, since]); return 1; }, tokensSince(id, since) { calls.push(['t', id, since]); return 2; }, costSince(id, since) { calls.push(['c', id, since]); return 3; } };
  const result = evaluateAccountLimits(account, usage, new Date('2026-02-03T04:05:06Z').getTime()); assert.equal(result.allowed, true); assert.equal(calls.length, 4);
});

test('strategy branches cover sticky without key, prune, and weighted final fallback', () => {
  const state = new StrategyState(); const items = [{ provider: { id: 'p' }, account: { id: 'a', priority: 2, weight: 1 }, runtime: {}, estimatedCostUsd: 0 }, { provider: { id: 'p' }, account: { id: 'b', priority: 1, weight: 1 }, runtime: {}, estimatedCostUsd: 0 }];
  assert.equal(selectCandidate('sticky', items, {}, state).account.id, 'b');
  state.sticky.set('expired', { providerId: 'p', accountId: 'a', expiresAt: 0 }); state.pruneSticky(1); assert.equal(state.sticky.has('expired'), false);
  assert.ok(selectCandidate('weighted-random', items, { random: () => 1 }).account.id);
});

test('error classification covers quota, retry-after clamp, network status, and invalid retry dates', () => {
  assert.equal(classifyUpstreamError({ status: 402, message: 'billing' }, { maxCooldownMs: 50 }).code, 'quota_exhausted');
  assert.equal(classifyUpstreamError({ status: 409, message: 'conflict', failureCount: 8 }, { baseCooldownMs: 10, maxCooldownMs: 20 }).cooldownMs, 20);
  assert.equal(classifyUpstreamError({ status: 418, message: 'teapot' }).code, 'invalid_request');
  assert.equal(classifyUpstreamError({ message: 'unknown' }).code, 'upstream_error');
  assert.equal(parseRetryAfter(null), null); assert.equal(parseRetryAfter(-5), 0);
});

test('usage service uses repository fallbacks when summary and csv are absent', () => {
  const records = [{ id: 'r', startedAt: '2026-01-01', status: 'success' }]; const repository = { insert: (x) => x, list: () => records, prune: () => 7 };
  const service = new UsageService(repository, createDefaultConfig); assert.equal(service.summary().requests, 1); assert.match(service.csv(), /"r"/); assert.equal(service.prune(1), 7);
});

test('routing stream reports no route when every provider is disabled', async () => {
  const config = createDefaultConfig(); config.providers = [createProvider({ id: 'p', name: 'P', type: 'x', enabled: false, accounts: [createAccount({ id: 'a' })] })];
  const service = new RoutingService({ registry: new ProviderRegistry([{ type: 'x', execute: async () => ({}), stream: async function* () {} }]), runtime: new RuntimeState(), usage: {} });
  await assert.rejects(async () => { for await (const event of service.stream({ model: 'm' }, { config, resolveSecret: () => null })) void event; }, (error) => error.code === 'no_route');
});
