import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { canonicalRequest } from '../../src/domain/protocol/canonical.js';
import { createAnthropicCompatibleAdapter } from '../../src/providers/anthropic-compatible.js';
import { createCommandAdapter } from '../../src/providers/command.js';
import { createExternalModuleAdapter } from '../../src/providers/external-module.js';
import { authHeaders, fetchWithTimeout } from '../../src/providers/fetch.js';
import { abortableDelay, createGeminiAdapter, interactionContent, interactionInput, interactionUsage, toDeepResearchRequest } from '../../src/providers/gemini.js';
import { createOpenAICompatibleAdapter } from '../../src/providers/openai-compatible.js';
import { parseSse, encodeSse } from '../../src/providers/sse.js';

const context = (overrides = {}) => ({
  provider: { type: 'x', baseUrl: 'https://example.test/v1/', headers: {}, adapter: {}, ...overrides.provider },
  account: { id: 'a' },
  secret: 'secret',
  timeoutMs: 1000,
  signal: undefined,
  logger: { debug() {} },
  ...overrides,
});

const richRequest = canonicalRequest({
  model: 'm',
  system: [{ type: 'text', text: 'rules' }, { type: 'image', data: 'abc', mediaType: 'image/png' }],
  messages: [
    { role: 'assistant', content: [{ type: 'tool-call', id: 'call', name: 'lookup', input: { x: 1 } }] },
    { role: 'tool', content: [{ type: 'tool-result', toolCallId: 'call', content: [{ type: 'text', text: 'result' }], isError: true }] },
    { role: 'user', content: [{ type: 'image', data: 'xyz', mediaType: 'image/jpeg' }, { type: 'text', text: 'hello' }] },
  ],
  tools: [{ name: 'lookup', description: 'Lookup', inputSchema: { type: 'object' } }],
  temperature: 0,
  topP: 0,
  stopSequences: ['stop'],
  maxOutputTokens: 2,
});

test('Anthropic adapter maps every content block and streamed tool delta', async () => {
  const previous = globalThis.fetch;
  let captured;
  let call = 0;
  globalThis.fetch = async (_url, options) => {
    captured = JSON.parse(options.body);
    if (call++ === 0) return Response.json({ id: 'r', content: [{ type: 'tool_use', id: 'c', name: 'lookup', input: { ok: true } }, { type: 'ignored' }], stop_reason: 'tool_use' });
    return new Response([
      'event: content_block_start\ndata: {"index":0,"content_block":{"type":"tool_use","id":"c","name":"lookup"}}\n\n',
      'event: content_block_delta\ndata: {"index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"x\\":1}"}}\n\n',
    ].join(''));
  };
  try {
    const adapter = createAnthropicCompatibleAdapter();
    const result = await adapter.execute(richRequest, context());
    assert.equal(result.content[0].type, 'tool-call');
    assert.equal(captured.max_tokens, 2);
    assert.equal(captured.messages[0].role, 'assistant');
    assert.equal(captured.messages[1].content[0].is_error, true);
    assert.equal(captured.messages[2].content[0].source.media_type, 'image/jpeg');
    const events = [];
    for await (const event of adapter.stream(richRequest, context())) events.push(event);
    assert.equal(events.at(-1).type, 'tool-call');
    assert.equal(events.at(-1).name, 'lookup');
  } finally { globalThis.fetch = previous; }
});

test('fetch helper covers default errors, timeout, and header omission', async () => {
  assert.deepEqual(authHeaders('', { headers: {} }), { 'content-type': 'application/json' });
  const previous = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: false, status: 500, headers: new Headers(), text: async () => { throw new Error('no body'); } });
  try { await assert.rejects(fetchWithTimeout('https://x'), (error) => error.status === 500 && error.retryable); } finally { globalThis.fetch = previous; }
  globalThis.fetch = async (_url, options) => new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true }));
  try { await assert.rejects(fetchWithTimeout('https://x', {}, 1), (error) => error.code === 'ETIMEDOUT'); } finally { globalThis.fetch = previous; }
});

test('command adapter covers invalid events, invalid tool JSON, and cancellation', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'spi-command-cover-'));
  const invalid = path.join(dir, 'invalid.mjs');
  await writeFile(invalid, `console.log(' '); console.log(JSON.stringify({text:'missing'}));`);
  await assert.rejects(createCommandAdapter().execute(canonicalRequest({ model: 'm' }), context({ provider: { type: 'command', adapter: { command: process.execPath, args: [invalid] } } })), /without type/);
  const tool = path.join(dir, 'tool.mjs');
  await writeFile(tool, `console.log(JSON.stringify({type:'tool-call',id:'c',name:'f',argumentsDelta:'not-json'})); console.log(JSON.stringify({type:'finish',stopReason:'stop'}));`);
  const response = await createCommandAdapter().execute(canonicalRequest({ model: 'm' }), context({ provider: { type: 'command', adapter: { command: process.execPath, args: [tool], environment: { EXTRA: '1' } } } }));
  assert.deepEqual(response.content[0].input, {});
  const slow = path.join(dir, 'slow.mjs');
  await writeFile(slow, `setTimeout(()=>{}, 10000);`);
  const controller = new AbortController();
  const promise = createCommandAdapter().execute(canonicalRequest({ model: 'm' }), context({ signal: controller.signal, provider: { type: 'command', adapter: { command: process.execPath, args: [slow] } } }));
  setTimeout(() => controller.abort(), 5);
  await assert.rejects(promise, (error) => error.code === 'CLIENT_ABORTED');
});

test('external module adapter validates exports, streams, and reload tokens', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'spi-module-cover-'));
  const trusted = path.join(dir, 'trusted');
  await mkdir(trusted);
  const invalid = path.join(trusted, 'invalid.mjs');
  await writeFile(invalid, 'export const value = 1;');
  const adapter = createExternalModuleAdapter({ trustedRoot: trusted });
  await assert.rejects(adapter.execute({}, context({ provider: { type: 'external-module', adapter: { modulePath: invalid } } })), /createAdapter/);
  const valid = path.join(trusted, 'valid.mjs');
  await writeFile(valid, `export function createAdapter(options){return {execute:async()=>options,stream:async function*(){yield options.value}}}`);
  const ctx = context({ provider: { type: 'external-module', adapter: { modulePath: valid, reloadToken: 'a', options: { value: 4 } } } });
  assert.equal((await adapter.execute({}, ctx)).value, 4);
  const streamed = [];
  for await (const item of adapter.stream({}, ctx)) streamed.push(item);
  assert.deepEqual(streamed, [4]);
  assert.equal((await adapter.execute({}, { ...ctx, provider: { ...ctx.provider, adapter: { ...ctx.provider.adapter, reloadToken: 'b' } } })).value, 4);
});

test('Gemini helper functions cover rich inputs, usage defaults, delay cancellation, and terminal failures', async () => {
  const request = canonicalRequest({
    model: 'deep-research-preview-04-2026',
    system: 'rules',
    messages: [
      { role: 'assistant', content: 'answer' },
      { role: 'tool', content: [{ type: 'tool-result', toolCallId: 'c', content: [{ type: 'text', text: 'result' }] }] },
      { role: 'user', content: [{ type: 'image', data: 'abc' }, { type: 'image', url: 'https://x/image.png' }] },
    ],
    metadata: { previous_interaction_id: 'old' },
  });
  const input = interactionInput(request);
  assert.ok(Array.isArray(input));
  assert.match(input[0].text, /System instructions/);
  assert.equal(toDeepResearchRequest(request).previous_interaction_id, 'old');
  assert.equal(interactionContent({ steps: [{ type: 'ignored' }, { type: 'model_output', content: [{ type: 'image', uri: 'https://x' }, { type: 'ignored' }] }] })[0].url, 'https://x');
  assert.equal(interactionUsage().totalTokens, 0);
  const controller = new AbortController();
  controller.abort(Object.assign(new Error('cancelled'), { name: 'AbortError' }));
  await assert.rejects(abortableDelay(10, controller.signal), /cancelled/);
  const later = new AbortController();
  const delayed = abortableDelay(1000, later.signal);
  later.abort();
  await assert.rejects(delayed, (error) => error.name === 'AbortError');
  const previous = globalThis.fetch;
  for (const [interaction, matcher] of [
    [{ id: 'x', status: 'failed', error: { message: 'research failed' } }, /research failed/],
    [{ id: 'x', status: 'cancelled' }, (error) => error.code === 'CLIENT_ABORTED'],
    [{ status: 'completed' }, (error) => error.code === 'INVALID_INTERACTION'],
  ]) {
    globalThis.fetch = async () => Response.json(interaction);
    try { await assert.rejects(createGeminiAdapter().execute(request, context({ provider: { type: 'gemini', baseUrl: 'https://gemini.test', adapter: { deepResearch: {} } } })), matcher); } finally { globalThis.fetch = previous; }
  }
});

test('Gemini stream emits images and cancels an aborted interaction', async () => {
  const request = canonicalRequest({ model: 'deep-research-preview-04-2026', messages: [{ role: 'user', content: 'research' }] });
  const previous = globalThis.fetch;
  globalThis.fetch = async () => Response.json({ id: 'x', status: 'completed', steps: [{ type: 'model_output', content: [{ type: 'image', data: 'abc' }] }] });
  try {
    const events = [];
    for await (const event of createGeminiAdapter().stream(request, context({ provider: { type: 'gemini', baseUrl: 'https://gemini.test', adapter: {} } }))) events.push(event);
    assert.ok(events.some((event) => event.type === 'image'));
  } finally { globalThis.fetch = previous; }
  const controller = new AbortController();
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    if (String(url).endsWith('/cancel')) return Response.json({});
    return Response.json({ id: 'abort-me', status: 'in_progress' });
  };
  setTimeout(() => controller.abort(), 5);
  try {
    await assert.rejects(createGeminiAdapter().execute(request, context({ signal: controller.signal, provider: { type: 'gemini', baseUrl: 'https://gemini.test', adapter: { deepResearch: { pollIntervalMs: 250 } } } })), (error) => error.name === 'AbortError');
    assert.ok(calls.some((url) => url.endsWith('/cancel')));
  } finally { globalThis.fetch = previous; }
});

test('OpenAI adapter covers empty content, invalid tool JSON, length stops, tool results, and no secret', async () => {
  const previous = globalThis.fetch;
  let captured;
  globalThis.fetch = async (_url, options) => {
    captured = { headers: options.headers, body: JSON.parse(options.body) };
    return Response.json({ choices: [{ message: { tool_calls: [{ id: 'c', function: { name: 'f', arguments: 'bad' } }] }, finish_reason: 'length' }] });
  };
  try {
    const adapter = createOpenAICompatibleAdapter();
    const result = await adapter.execute(canonicalRequest({ model: 'm', messages: [{ role: 'tool', content: [{ type: 'tool-result', toolCallId: 'c', content: 'done' }] }] }), context({ secret: '' }));
    assert.equal(result.stopReason, 'max_tokens');
    assert.deepEqual(result.content[0].input, {});
    assert.equal(captured.body.messages[0].tool_call_id, 'c');
    assert.equal(captured.headers.authorization, undefined);
  } finally { globalThis.fetch = previous; }
});

test('SSE parser covers comments, aborts, and string chunks', async () => {
  assert.match(encodeSse({ comment: 'one\ntwo' }), /^: one two/);
  const controller = new AbortController();
  async function* chunks() { yield 'data: one\n\n'; controller.abort(); yield 'data: two\n\n'; }
  const events = [];
  await assert.rejects(async () => { for await (const event of parseSse(chunks(), controller.signal)) events.push(event); }, (error) => error.code === 'CLIENT_ABORTED');
  assert.equal(events[0].data, 'one');
});
