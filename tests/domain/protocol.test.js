import test from 'node:test';
import assert from 'node:assert/strict';
import { canonicalRequest, canonicalResponse, normalizeBlocks, normalizeUsage } from '../../src/domain/protocol/canonical.js';
import { fromOpenAIChat, fromOpenAIResponses, toOpenAIChat, toOpenAIResponse, openAIChatStream, openAIResponseStream, openAIChunkToCanonical } from '../../src/domain/protocol/openai.js';
import { fromAnthropicMessages, toAnthropicMessage, AnthropicStreamState, anthropicUsageToCanonical } from '../../src/domain/protocol/anthropic.js';
import { toGeminiRequest, fromGeminiResponse, geminiChunkToCanonical } from '../../src/domain/protocol/gemini.js';

test('canonical request requires model', () => assert.throws(() => canonicalRequest({}), /model/));
test('canonical request normalizes strings and roles', () => {
  const request = canonicalRequest({ model: 'm', system: 's', messages: [{ role: 'weird', content: 'hello' }] });
  assert.deepEqual(request.system, [{ type: 'text', text: 's' }]); assert.equal(request.messages[0].role, 'user');
});
test('normalize blocks preserves tools and images', () => {
  const blocks = normalizeBlocks([{ type: 'image', url: 'https://x' }, { type: 'tool-call', id: '1', name: 'go', input: { x: 1 } }, { type: 'tool-result', toolCallId: '1', name: 'go', content: 'ok' }]);
  assert.deepEqual(blocks.map((block) => block.type), ['image','tool-call','tool-result']);
  assert.equal(blocks[2].name, 'go');
});
test('usage supports OpenAI fields and cache', () => assert.deepEqual(normalizeUsage({ prompt_tokens: 3, completion_tokens: 4, cached_tokens: 2 }), { inputTokens: 3, outputTokens: 4, cacheReadTokens: 2, cacheWriteTokens: 0, totalTokens: 7 }));
test('canonical response supplies stable defaults', () => {
  const response = canonicalResponse({ model: 'm', content: 'ok' }); assert.equal(response.stopReason, 'end_turn'); assert.equal(response.content[0].text, 'ok');
});

test('OpenAI Chat request separates system and tools', () => {
  const request = fromOpenAIChat({ model: 'gpt-x', messages: [{ role: 'system', content: 'rules' }, { role: 'user', content: [{ type: 'text', text: 'go' }, { type: 'image_url', image_url: { url: 'https://image' } }] }], tools: [{ type: 'function', function: { name: 'search', description: 'd', parameters: { type: 'object' } } }] }, { 'x-session-id': 's' });
  assert.equal(request.system[0].text, 'rules'); assert.equal(request.messages[0].content[1].url, 'https://image'); assert.equal(request.tools[0].name, 'search'); assert.equal(request.stickyKey, 's');
});
test('OpenAI Chat tool calls and results normalize', () => {
  const request = fromOpenAIChat({ model: 'm', messages: [{ role: 'assistant', content: null, tool_calls: [{ id: 'c', function: { name: 'f', arguments: '{"x":1}' } }] }, { role: 'tool', tool_call_id: 'c', name: 'f', content: 'done' }] });
  assert.equal(request.messages[0].content[0].input.x, 1); assert.equal(request.messages[1].content.at(-1).toolCallId, 'c');
});
test('OpenAI Responses input and function output normalize', () => {
  const request = fromOpenAIResponses({ model: 'm', instructions: 'rules', input: [{ role: 'user', content: [{ type: 'input_text', text: 'hi' }] }, { type: 'function_call_output', call_id: 'c', output: 'ok' }], tools: [{ type: 'function', name: 'f', parameters: {} }] });
  assert.equal(request.system[0].text, 'rules'); assert.equal(request.messages[1].content[0].toolCallId, 'c'); assert.equal(request.tools[0].name, 'f');
});
test('OpenAI chat response serializes text, tools, usage', () => {
  const wire = toOpenAIChat({ id: 'r', model: 'm', content: [{ type: 'text', text: 'hi' }, { type: 'tool-call', id: 'c', name: 'f', input: { x: 1 } }], stopReason: 'tool_use', usage: { inputTokens: 2, outputTokens: 3, cacheReadTokens: 1 } });
  assert.equal(wire.choices[0].message.content, 'hi'); assert.equal(wire.choices[0].message.tool_calls[0].function.name, 'f'); assert.equal(wire.choices[0].finish_reason, 'tool_calls'); assert.equal(wire.usage.prompt_tokens_details.cached_tokens, 1);
});
test('OpenAI Responses response serializes output items', () => {
  const wire = toOpenAIResponse({ id: 'r', model: 'm', content: [{ type: 'text', text: 'hi' }, { type: 'tool-call', id: 'c', name: 'f', input: {} }] });
  assert.deepEqual(wire.output.map((item) => item.type), ['message','function_call']);
});
test('OpenAI chat stream maps visible and finish events', () => {
  assert.equal(openAIChatStream({ type: 'text-delta', text: 'a' }, { id: 'r', model: 'm' }).choices[0].delta.content, 'a');
  assert.equal(openAIChatStream({ type: 'finish', stopReason: 'max_tokens' }, { id: 'r', model: 'm' }).choices[0].finish_reason, 'length');
});
test('OpenAI Responses stream maps deltas', () => assert.equal(openAIResponseStream({ type: 'text-delta', text: 'a' }, { id: 'r', model: 'm' }).delta, 'a'));
test('OpenAI chunk parsing emits text, tool, finish, usage', () => {
  const events = openAIChunkToCanonical({ choices: [{ delta: { content: 'x', tool_calls: [{ index: 0, id: 'c', function: { name: 'f', arguments: '{}' } }] }, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 1, completion_tokens: 2 } });
  assert.deepEqual(events.map((event) => event.type), ['text-delta','tool-call','finish','usage']);
});

test('Anthropic request supports images and tool results', () => {
  const request = fromAnthropicMessages({ model: 'claude', system: 'rules', max_tokens: 9, messages: [{ role: 'user', content: [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'abc' } }, { type: 'tool_result', tool_use_id: 'c', content: 'ok' }] }], tools: [{ name: 'f', input_schema: { type: 'object' } }] });
  assert.equal(request.messages[0].content[0].data, 'abc'); assert.equal(request.messages[0].content[1].toolCallId, 'c'); assert.equal(request.maxOutputTokens, 9);
});
test('Anthropic response serializes content and cache usage', () => {
  const wire = toAnthropicMessage({ id: 'r', model: 'm', content: [{ type: 'text', text: 'a' }, { type: 'tool-call', id: 'c', name: 'f', input: {} }], stopReason: 'tool_use', usage: { inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4 } });
  assert.equal(wire.content[1].type, 'tool_use'); assert.equal(wire.stop_reason, 'tool_use'); assert.equal(wire.usage.cache_creation_input_tokens, 4);
});
test('Anthropic stream maintains stable block indexes', () => {
  const state = new AnthropicStreamState({ id: 'r', model: 'm' });
  assert.equal(state.serialize({ type: 'text-delta', text: 'a' })[0].data.index, 0);
  assert.equal(state.serialize({ type: 'text-delta', text: 'b' })[0].data.index, 0);
  assert.equal(state.serialize({ type: 'tool-call', id: 'c', name: 'f', argumentsDelta: '{' })[0].data.index, 1);
  const finish = state.serialize({ type: 'finish', stopReason: 'tool_use' });
  assert.deepEqual(finish.slice(0, 2).map((item) => item.data.index), [0,1]);
});
test('Anthropic usage normalizes all cache counters', () => assert.deepEqual(anthropicUsageToCanonical({ input_tokens: 1, output_tokens: 2, cache_read_input_tokens: 3, cache_creation_input_tokens: 4 }), { inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4, totalTokens: 3 }));

test('Gemini payload uses native system instructions, images, tools, and parameters', () => {
  const request = canonicalRequest({ model: 'gemini', system: 'rules', messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }, { type: 'image', mediaType: 'image/png', data: 'abc' }] }], tools: [{ name: 'f', description: 'd', inputSchema: { type: 'object', properties: { x: { type: 'string' } } } }], maxOutputTokens: 99 });
  const payload = toGeminiRequest(request);
  assert.equal(payload.systemInstruction.parts[0].text, 'rules'); assert.equal(payload.contents[0].parts[1].inlineData.data, 'abc'); assert.deepEqual(payload.tools[0].functionDeclarations[0].parameters, request.tools[0].inputSchema); assert.equal(payload.generationConfig.maxOutputTokens, 99);
});
test('Gemini payload preserves tool result names', () => {
  const request = canonicalRequest({ model: 'm', messages: [{ role: 'tool', content: [{ type: 'tool-result', toolCallId: 'c', name: 'weather', content: 'sunny' }] }] });
  assert.equal(toGeminiRequest(request).contents[0].parts[0].functionResponse.name, 'weather');
});
test('Gemini response maps text, functions, usage, and stop reason', () => {
  const response = fromGeminiResponse({ candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [{ text: 'a' }, { functionCall: { id: 'c', name: 'f', args: { x: 1 } }, thoughtSignature: 'sig' }] } }], usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 3, cachedContentTokenCount: 1 } }, 'gemini');
  assert.equal(response.stopReason, 'max_tokens'); assert.equal(response.content[1].thoughtSignature, 'sig'); assert.equal(response.usage.cacheReadTokens, 1);
});
test('Gemini stream emits canonical events', () => {
  const events = geminiChunkToCanonical({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: 'a' }, { functionCall: { name: 'f', args: {} } }] } }], usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 } });
  assert.deepEqual(events.map((event) => event.type), ['text-delta','tool-call','usage','finish']);
});
