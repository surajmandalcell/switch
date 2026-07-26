import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { mkdtemp, writeFile, mkdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { parseSse, encodeSse } from '../../src/providers/sse.js';
import { fetchWithTimeout, authHeaders } from '../../src/providers/fetch.js';
import { createOpenAICompatibleAdapter } from '../../src/providers/openai-compatible.js';
import { createAnthropicCompatibleAdapter } from '../../src/providers/anthropic-compatible.js';
import { createGeminiAdapter } from '../../src/providers/gemini.js';
import { createCommandAdapter } from '../../src/providers/command.js';
import { createExternalModuleAdapter } from '../../src/providers/external-module.js';
import { createProviderRegistry, PROVIDER_PRESETS } from '../../src/providers/index.js';
import { canonicalRequest } from '../../src/domain/protocol/canonical.js';

const request = canonicalRequest({ model: 'm', system: 'rules', messages: [{ role: 'user', content: 'hello' }], tools: [{ name: 'f', inputSchema: { type: 'object' } }] });
const context = (overrides = {}) => ({ provider: { type: 'x', baseUrl: 'https://example.test/v1', headers: {}, adapter: {}, ...overrides.provider }, account: { id: 'a' }, secret: 'secret', timeoutMs: 1000, signal: undefined, ...overrides });

test('SSE encoder and parser support event names and multiline data', async () => {
  const encoded = encodeSse({ event: 'delta', data: { text: 'a' } }) + 'data: one\ndata: two\n\n';
  const events = []; for await (const event of parseSse(Readable.from([Buffer.from(encoded)]))) events.push(event);
  assert.equal(events[0].event, 'delta'); assert.equal(JSON.parse(events[0].data).text, 'a'); assert.equal(events[1].data, 'one\ntwo');
});
test('SSE parser flushes a final unterminated frame', async () => {
  const events = []; for await (const event of parseSse(Readable.from(['data: tail']))) events.push(event); assert.equal(events[0].data, 'tail');
});
test('auth headers place secrets only in authorization', () => assert.deepEqual(authHeaders('x', { headers: { 'x-trace': '1' } }), { 'content-type': 'application/json', 'x-trace': '1', authorization: 'Bearer x' }));

test('fetch helper returns successful responses', async () => {
  const original = global.fetch; global.fetch = async () => new Response('ok'); try { assert.equal(await (await fetchWithTimeout('https://x')).text(), 'ok'); } finally { global.fetch = original; }
});
test('fetch helper maps upstream status and retry-after', async () => {
  const original = global.fetch; global.fetch = async () => new Response('limited', { status: 429, headers: { 'retry-after': '2' } });
  try { await assert.rejects(fetchWithTimeout('https://x'), (error) => error.status === 429 && error.details.retryAfter === '2'); } finally { global.fetch = original; }
});
test('fetch helper maps client cancellation distinctly', async () => {
  const controller = new AbortController(); const original = global.fetch; global.fetch = async (_url, options) => new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => reject(new DOMException('Aborted','AbortError'))));
  const promise = fetchWithTimeout('https://x', { signal: controller.signal }, 1000); controller.abort();
  try { await assert.rejects(promise, (error) => error.code === 'CLIENT_ABORTED'); } finally { global.fetch = original; }
});

test('OpenAI adapter executes chat completions', async () => {
  const original = global.fetch; let captured;
  global.fetch = async (_url, options) => { captured = JSON.parse(options.body); return Response.json({ id: 'r', model: 'm', choices: [{ message: { content: 'ok', tool_calls: [{ id: 'c', function: { name: 'f', arguments: '{"x":1}' } }] }, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 2, completion_tokens: 3 } }); };
  try { const response = await createOpenAICompatibleAdapter().execute(request, context()); assert.equal(response.content[0].text, 'ok'); assert.equal(response.content[1].input.x, 1); assert.equal(captured.messages[0].role, 'system'); assert.equal(captured.tools[0].function.name, 'f'); } finally { global.fetch = original; }
});
test('OpenAI adapter streams canonical events', async () => {
  const original = global.fetch; const stream = 'data: {"choices":[{"delta":{"content":"a"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\ndata: [DONE]\n\n'; global.fetch = async () => new Response(stream, { headers: { 'content-type': 'text/event-stream' } });
  try { const events = []; for await (const event of createOpenAICompatibleAdapter().stream(request, context())) events.push(event); assert.deepEqual(events.map((e) => e.type), ['start','text-delta','finish','usage']); } finally { global.fetch = original; }
});

test('Anthropic adapter executes native message payloads', async () => {
  const original = global.fetch; let captured; global.fetch = async (_url, options) => { captured = JSON.parse(options.body); return Response.json({ id: 'r', model: 'm', content: [{ type: 'text', text: 'ok' }], stop_reason: 'end_turn', usage: { input_tokens: 1, output_tokens: 2 } }); };
  try { const response = await createAnthropicCompatibleAdapter().execute(request, context()); assert.equal(response.content[0].text, 'ok'); assert.equal(captured.system[0].text, 'rules'); assert.equal(captured.tools[0].input_schema.type, 'object'); } finally { global.fetch = original; }
});
test('Anthropic adapter streams text and usage', async () => {
  const original = global.fetch; const stream = 'event: content_block_delta\ndata: {"index":0,"delta":{"type":"text_delta","text":"a"}}\n\nevent: message_delta\ndata: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'; global.fetch = async () => new Response(stream);
  try { const events = []; for await (const event of createAnthropicCompatibleAdapter().stream(request, context())) events.push(event); assert.deepEqual(events.map((e) => e.type), ['start','text-delta','usage','finish']); } finally { global.fetch = original; }
});

test('Gemini adapter uses key query and native response conversion', async () => {
  const original = global.fetch; let url; global.fetch = async (value) => { url = value; return Response.json({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: 'ok' }] } }], usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1 } }); };
  try { const response = await createGeminiAdapter().execute(request, context({ provider: { type: 'gemini', baseUrl: 'https://gemini.test' } })); assert.match(url, /key=secret/); assert.equal(response.content[0].text, 'ok'); } finally { global.fetch = original; }
});
test('Gemini adapter streams SSE chunks', async () => {
  const original = global.fetch; global.fetch = async () => new Response('data: {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"ok"}]}}]}\n\n');
  try { const events = []; for await (const event of createGeminiAdapter().stream(request, context({ provider: { type: 'gemini', baseUrl: 'https://gemini.test' } }))) events.push(event); assert.deepEqual(events.map((e) => e.type), ['start','text-delta','finish']); } finally { global.fetch = original; }
});

test('command adapter exchanges JSON lines and secret environment', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'spi-command-')); const script = path.join(dir, 'provider.mjs');
  await writeFile(script, `let body=''; for await (const c of process.stdin) body+=c; const r=JSON.parse(body); console.log(JSON.stringify({type:'text-delta',text:r.model+':'+process.env.SPI_ACCOUNT_SECRET})); console.log(JSON.stringify({type:'usage',usage:{inputTokens:1,outputTokens:1}})); console.log(JSON.stringify({type:'finish',stopReason:'end_turn'}));`);
  const adapter = createCommandAdapter(); const ctx = context({ provider: { type: 'command', adapter: { command: process.execPath, args: [script] } } });
  const response = await adapter.execute(request, ctx); assert.equal(response.content[0].text, 'm:secret'); assert.equal(response.usage.totalTokens, 2);
});
test('command adapter reports nonzero exits', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'spi-command-')); const script = path.join(dir, 'fail.mjs'); await writeFile(script, `console.error('failed'); process.exit(4);`);
  await assert.rejects(createCommandAdapter().execute(request, context({ provider: { type: 'command', adapter: { command: process.execPath, args: [script] } } })), /failed/);
});
test('command adapter requires an explicit executable', async () => await assert.rejects(createCommandAdapter().execute(request, context({ provider: { type: 'command', adapter: {} } })), /no command/));

test('external modules are restricted to trusted root and cached', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'spi-module-')); const trusted = path.join(dir, 'trusted'); await mkdir(trusted); const modulePath = path.join(trusted, 'adapter.mjs');
  await writeFile(modulePath, `globalThis.__spiLoads=(globalThis.__spiLoads??0)+1; export function createAdapter(){return {execute:async()=>({model:'m',content:[],usage:{}}),stream:async function*(){}}}`);
  const adapter = createExternalModuleAdapter({ trustedRoot: trusted }); const ctx = context({ provider: { type: 'external-module', adapter: { modulePath, reloadToken: 'one' } } });
  await adapter.execute(request, ctx); await adapter.execute(request, ctx); assert.equal(globalThis.__spiLoads, 1);
  await assert.rejects(adapter.execute(request, context({ provider: { type: 'external-module', adapter: { modulePath: path.join(dir, 'outside.mjs') } } })), /trusted/);
});

test('built-in registry contains every provider architecture type', () => {
  const registry = createProviderRegistry({ trustedModulesRoot: os.tmpdir() });
  assert.deepEqual(registry.list(), ['anthropic','anthropic-compatible','command','external-module','gemini','grok','openai','openai-compatible']);
  assert.deepEqual(PROVIDER_PRESETS.map((item) => item.type), ['openai','anthropic','gemini','grok','openai-compatible','anthropic-compatible','command']);
});

import { isDeepResearchModel, toDeepResearchRequest, interactionToCanonical } from '../../src/providers/gemini.js';

test('Gemini Deep Research request uses Interactions API agent options', () => {
  const request = canonicalRequest({ model: 'deep-research-preview-04-2026', system: 'Be precise', messages: [{ role: 'user', content: 'Research TPUs' }], metadata: { previousInteractionId: 'prior' } });
  const body = toDeepResearchRequest(request, { deepResearch: { thinkingSummaries: 'none', visualization: 'auto', collaborativePlanning: true, tools: [{ type: 'google_search' }] } });
  assert.equal(body.agent, 'deep-research-preview-04-2026');
  assert.equal(body.background, true);
  assert.equal(body.previous_interaction_id, 'prior');
  assert.equal(body.agent_config.visualization, 'auto');
  assert.equal(body.agent_config.collaborative_planning, true);
  assert.deepEqual(body.tools, [{ type: 'google_search' }]);
  assert.equal(isDeepResearchModel('deep-research-max-preview-04-2026'), true);
  assert.equal(isDeepResearchModel('gemini-3.6-flash'), false);
});

test('Gemini Deep Research completed interaction converts cited text, images, and usage', () => {
  const response = interactionToCanonical({ id: 'i', agent: 'deep-research-preview-04-2026', status: 'completed', steps: [{ type: 'model_output', content: [{ type: 'text', text: 'Report [1]' }, { type: 'image', data: 'abc', mime_type: 'image/png' }] }], usage: { total_input_tokens: 20, total_output_tokens: 1000, total_cached_tokens: 4 } }, 'fallback');
  assert.equal(response.id, 'i'); assert.equal(response.content[0].text, 'Report [1]'); assert.equal(response.content[1].type, 'image'); assert.equal(response.usage.inputTokens, 20); assert.equal(response.usage.cacheReadTokens, 4);
});

test('Gemini adapter executes completed Deep Research interactions', async () => {
  const calls = [];
  const previous = globalThis.fetch;
  globalThis.fetch = async (url, options) => { calls.push({ url, options }); return Response.json({ id: 'interaction-1', agent: 'deep-research-preview-04-2026', status: 'completed', steps: [{ type: 'model_output', content: [{ type: 'text', text: 'Research report' }] }], usage: { total_input_tokens: 2, total_output_tokens: 5 } }); };
  try {
    const adapter = createGeminiAdapter();
    const result = await adapter.execute(canonicalRequest({ model: 'deep-research-preview-04-2026', messages: [{ role: 'user', content: 'Research' }] }), context({ provider: { type: 'gemini', baseUrl: 'https://gemini.example/v1beta' } }));
    assert.equal(result.content[0].text, 'Research report');
    assert.equal(calls[0].url, 'https://gemini.example/v1beta/interactions');
    assert.equal(calls[0].options.headers['x-goog-api-key'], 'secret');
    assert.equal(JSON.parse(calls[0].options.body).background, true);
  } finally { globalThis.fetch = previous; }
});

test('Gemini Deep Research compatibility stream emits safe heartbeats before final report', async () => {
  const previous = globalThis.fetch;
  let count = 0;
  globalThis.fetch = async () => Response.json(count++ === 0 ? { id: 'interaction-2', status: 'in_progress' } : { id: 'interaction-2', status: 'completed', steps: [{ type: 'model_output', content: [{ type: 'text', text: 'Done' }] }], usage: { total_input_tokens: 1, total_output_tokens: 1 } });
  try {
    const adapter = createGeminiAdapter();
    const deepContext = context({ provider: { type: 'gemini', baseUrl: 'https://gemini.example/v1beta', adapter: { deepResearch: { pollIntervalMs: 1 } } } });
    const events = [];
    for await (const event of adapter.stream(canonicalRequest({ model: 'deep-research-preview-04-2026', messages: [{ role: 'user', content: 'Research' }] }), deepContext)) events.push(event);
    assert.deepEqual(events.map((event) => event.type), ['start','heartbeat','text-delta','usage','finish']);
  } finally { globalThis.fetch = previous; }
});

test('Grok adapter forwards sticky conversation ids and service tiers', async () => {
  const original = global.fetch;
  let captured;
  global.fetch = async (_url, options) => {
    captured = { headers: options.headers, body: JSON.parse(options.body) };
    return Response.json({ id: 'grok-response', model: 'grok-4', choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }], usage: { prompt_tokens: 1, completion_tokens: 2, cost_in_usd_ticks: 125000000 } });
  };
  try {
    const adapter = createOpenAICompatibleAdapter({ type: 'grok', defaultBaseUrl: 'https://api.x.ai/v1' });
    const result = await adapter.execute(canonicalRequest({ model: 'grok-4', stickyKey: 'conversation-7', messages: [{ role: 'user', content: 'hello' }] }), context({ provider: { type: 'grok', baseUrl: 'https://api.x.ai/v1', adapter: { serviceTier: 'priority' } } }));
    assert.equal(captured.headers['x-grok-conv-id'], 'conversation-7');
    assert.equal(captured.body.service_tier, 'priority');
    assert.equal(result.usage.reportedCostUsd, 0.0125);
  } finally { global.fetch = original; }
});
