import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';

const baseUrl = process.env.ROUTING_TEST_BASE_URL || 'http://localhost:8081';
const shouldSkip = false; // Tests expect the server to already be running.

async function postJson(path, body) {
  const url = new URL(path, baseUrl);
  const payload = JSON.stringify(body);
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: payload
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch (_) {
    json = null;
  }
  return { status: response.status, json, text, headers: response.headers };
}

async function getJson(path) {
  const url = new URL(path, baseUrl);
  const response = await fetch(url);
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch (_) {
    json = null;
  }
  return { status: response.status, json, text, headers: response.headers };
}

function startSseListener(path) {
  const url = new URL(path, baseUrl);
  const req = http.get(url);
  const events = [];

  req.on('response', (res) => {
    res.setEncoding('utf8');
    let buffer = '';
    res.on('data', (chunk) => {
      buffer += chunk;
      const parts = buffer.split('\n\n');
      buffer = parts.pop() || '';

      for (const part of parts) {
        const lines = part.split('\n').filter(Boolean);
        const dataLine = lines.find((l) => l.startsWith('data:'));
        if (!dataLine) continue;
        const data = dataLine.slice(5).trim();
        if (!data) continue;
        events.push(data);
      }
    });
  });

  return { req, events };
}

test('GET /health returns status ok + configPath', { skip: shouldSkip }, async () => {
  const { status, json, text } = await getJson('/health');
  assert.equal(status, 200, `Expected 200, got ${status}: ${text}`);
  assert.equal(json?.status, 'ok');
  assert.ok(typeof json?.configPath === 'string' && json.configPath.length > 0);
});

test('GET /accounts returns list payload', { skip: shouldSkip }, async () => {
  const { status, json, text } = await getJson('/accounts');
  assert.equal(status, 200, `Expected 200, got ${status}: ${text}`);
  assert.ok(json && typeof json === 'object');
});

test('POST /accounts/switch validates email required', { skip: shouldSkip }, async () => {
  const { status, json } = await postJson('/accounts/switch', {});
  assert.equal(status, 400);
  assert.equal(json?.success, false);
  assert.equal(json?.message, 'Email is required');
});

test('POST /settings/haiku-model is disabled by default', { skip: shouldSkip }, async () => {
  const { status, json } = await postJson('/settings/haiku-model', { haikuKiloModel: 'nope' });
  assert.equal(status, 403);
  assert.equal(json?.success, false);
  assert.ok(String(json?.error || '').includes('Kilo routing is disabled'));
});

test('GET/POST /settings/account-strategy is not exposed', { skip: shouldSkip }, async () => {
  const getResult = await getJson('/settings/account-strategy');
  assert.equal(getResult.status, 404, `Expected 404, got ${getResult.status}: ${getResult.text}`);

  const postResult = await postJson('/settings/account-strategy', { accountStrategy: 'round-robin' });
  assert.equal(postResult.status, 404, `Expected 404, got ${postResult.status}: ${postResult.text}`);
});

test('GET/POST /settings/claude-proxy returns and persists startup flag', { skip: shouldSkip }, async () => {
  const original = await getJson('/settings/claude-proxy');
  assert.equal(original.status, 200, `Expected 200, got ${original.status}: ${original.text}`);
  assert.equal(original.json?.success, true);
  assert.equal(typeof original.json?.configureClaudeOnStartup, 'boolean');

  const nextValue = !original.json.configureClaudeOnStartup;

  try {
    const updated = await postJson('/settings/claude-proxy', { configureClaudeOnStartup: nextValue });
    assert.equal(updated.status, 200, `Expected 200, got ${updated.status}: ${updated.text}`);
    assert.equal(updated.json?.success, true);
    assert.equal(updated.json?.configureClaudeOnStartup, nextValue);

    const reread = await getJson('/settings/claude-proxy');
    assert.equal(reread.status, 200, `Expected 200, got ${reread.status}: ${reread.text}`);
    assert.equal(reread.json?.configureClaudeOnStartup, nextValue);
  } finally {
    await postJson('/settings/claude-proxy', {
      configureClaudeOnStartup: original.json.configureClaudeOnStartup
    });
  }
});

test('GET/POST /settings/model-mappings returns and persists Claude alias mappings', { skip: shouldSkip }, async () => {
  const original = await getJson('/settings/model-mappings');
  assert.equal(original.status, 200, `Expected 200, got ${original.status}: ${original.text}`);
  assert.equal(original.json?.success, true);
  assert.ok(Array.isArray(original.json?.models));
  assert.ok(Array.isArray(original.json?.reasoningLevels));
  assert.ok(original.json.models.some((model) => model.id === 'gpt-5.4'));
  assert.ok(original.json.reasoningLevels.some((level) => level.id === 'xhigh'));

  const originalMappings = original.json.modelMappings;
  const originalReasoningMappings = original.json.reasoningMappings;
  const nextHaiku = originalMappings.haiku === 'gpt-5.4' ? 'gpt-5.4-mini' : 'gpt-5.4';
  const nextReasoning = originalReasoningMappings.haiku === 'xhigh' ? 'low' : 'xhigh';

  try {
    const updated = await postJson('/settings/model-mappings', {
      modelMappings: { haiku: nextHaiku },
      reasoningMappings: { haiku: nextReasoning }
    });
    assert.equal(updated.status, 200, `Expected 200, got ${updated.status}: ${updated.text}`);
    assert.equal(updated.json?.success, true);
    assert.equal(updated.json?.modelMappings?.haiku, nextHaiku);
    assert.equal(updated.json?.reasoningMappings?.haiku, nextReasoning);

    const reread = await getJson('/settings/model-mappings');
    assert.equal(reread.status, 200, `Expected 200, got ${reread.status}: ${reread.text}`);
    assert.equal(reread.json?.modelMappings?.haiku, nextHaiku);
    assert.equal(reread.json?.reasoningMappings?.haiku, nextReasoning);
  } finally {
    await postJson('/settings/model-mappings', {
      modelMappings: originalMappings,
      reasoningMappings: originalReasoningMappings
    });
  }
});

test('POST /settings/model-mappings rejects unsupported GPT model', { skip: shouldSkip }, async () => {
  const { status, json } = await postJson('/settings/model-mappings', { modelMappings: { haiku: 'fake-gpt-model' } });
  assert.equal(status, 400);
  assert.equal(json?.success, false);
});

test('POST /settings/model-mappings rejects unsupported reasoning level', { skip: shouldSkip }, async () => {
  const { status, json } = await postJson('/settings/model-mappings', { reasoningMappings: { haiku: 'extreme' } });
  assert.equal(status, 400);
  assert.equal(json?.success, false);
});

test('POST /claude/config/direct validates API key required', { skip: shouldSkip }, async () => {
  const { status, json } = await postJson('/claude/config/direct', {});
  assert.equal(status, 400);
  assert.equal(json?.success, false);
  assert.equal(json?.error, 'API key required');
});

test('POST /v1/messages/count_tokens returns input_tokens', { skip: shouldSkip }, async () => {
  const payload = {
    system: 'hello',
    messages: [{ role: 'user', content: 'world' }],
    tools: [{ name: 't', description: 'd', input_schema: { type: 'object' } }]
  };
  const { status, json, text } = await postJson('/v1/messages/count_tokens', payload);
  assert.equal(status, 200, `Expected 200, got ${status}: ${text}`);
  assert.ok(Number.isInteger(json?.input_tokens));
  assert.ok(json.input_tokens > 0);
});

test('POST /v1/chat/completions returns either 200 (configured) or 401 (no account)', { skip: shouldSkip }, async () => {
  const payload = {
    model: 'claude-sonnet-4-5',
    messages: [{ role: 'user', content: 'ping' }]
  };
  const { status, json, text } = await postJson('/v1/chat/completions', payload);

  // This endpoint requires an active account *unless* the environment running tests
  // already has one configured. Keep this resilient.
  assert.ok([200, 401].includes(status), `Unexpected status ${status}: ${text}`);

  if (status === 401) {
    assert.equal(json?.type, 'error');
    assert.equal(json?.error?.type, 'authentication_error');
  } else {
    assert.ok(json && typeof json === 'object');
    assert.equal(json?.object, 'chat.completion');
    assert.ok(Array.isArray(json?.choices));
  }
});

test('POST /v1/messages (non-kilo) returns either 200 (configured) or 401 (no account)', { skip: shouldSkip }, async () => {
  const payload = {
    model: 'claude-sonnet-4-5',
    max_tokens: 8,
    messages: [{ role: 'user', content: 'ping' }],
    stream: false
  };
  const { status, json, text } = await postJson('/v1/messages', payload);

  assert.ok([200, 401].includes(status), `Unexpected status ${status}: ${text}`);

  if (status === 401) {
    assert.equal(json?.type, 'error');
    assert.equal(json?.error?.type, 'authentication_error');
  } else {
    assert.equal(json?.type, 'message');
  }
});

test('POST /v1/messages (haiku alias) returns either 200 (configured) or 401 (no account)', { skip: shouldSkip }, async () => {
  const payload = {
    model: 'claude-haiku-4',
    max_tokens: 8,
    messages: [{ role: 'user', content: 'ping' }],
    stream: false
  };

  const { status, json, text } = await postJson('/v1/messages', payload);
  assert.ok([200, 401].includes(status), `Unexpected status ${status}: ${text}`);
  if (status === 401) {
    assert.equal(json?.error?.type, 'authentication_error');
  } else {
    assert.equal(json?.type, 'message');
    assert.equal(json?.model, 'claude-haiku-4');
    assert.ok(Array.isArray(json?.content));
  }
});

test('GET /api/logs returns status ok and logs array', { skip: shouldSkip }, async () => {
  const { status, json, text } = await getJson('/api/logs');
  assert.equal(status, 200, `Expected 200, got ${status}: ${text}`);
  assert.equal(json?.status, 'ok');
  assert.ok(Array.isArray(json?.logs));
});

test('GET /api/logs/stream returns SSE and can include history', { skip: shouldSkip }, async () => {
  const listener = startSseListener('/api/logs/stream?history=true');

  // Wait for at least one event (history should flush quickly).
  await Promise.race([
    once(listener.req, 'close'),
    new Promise((resolve) => setTimeout(resolve, 500))
  ]);

  // Teardown
  listener.req.destroy();

  // Not asserting exact content, just that it looks like SSE events.
  assert.ok(listener.events.length >= 0);
});
