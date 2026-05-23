import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';

const baseUrl = process.env.ROUTING_TEST_BASE_URL || 'http://localhost:8081';

// Tests expect the proxy server to already be running.
// Set ROUTING_TEST_BASE_URL to override the default.
const shouldSkip = false;

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
  return { status: response.status, json, text };
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
  return { status: response.status, json, text };
}

test('routes claude-haiku-4 through OpenAI account path by default', { skip: shouldSkip }, async () => {
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

test('kilo target settings are disabled by default', { skip: shouldSkip }, async () => {
  const setRes = await postJson('/settings/haiku-model', { haikuKiloModel: 'minimax-2.5' });
  assert.equal(setRes.status, 403);
  assert.equal(setRes.json?.success, false);
  assert.equal(setRes.json?.error.includes('Kilo routing is disabled'), true);

  const getRes = await getJson('/settings/haiku-model');
  assert.equal(getRes.status, 200);
  assert.equal(getRes.json?.kiloEnabled, false);
});

function startLogListener() {
  const url = new URL('/api/logs/stream?history=false', baseUrl);
  const req = http.get(url);
  const logs = [];

  req.on('response', (res) => {
    res.setEncoding('utf8');
    let buffer = '';
    res.on('data', (chunk) => {
      buffer += chunk;
      const parts = buffer.split('\n\n');
      buffer = parts.pop() || '';
      for (const part of parts) {
        if (!part.startsWith('data:')) continue;
        const data = part.slice(5).trim();
        if (!data) continue;
        try {
          logs.push(JSON.parse(data));
        } catch (_) {
          // ignore
        }
      }
    });
  });

  return { req, logs };
}

test('logs do not show implicit Kilo routing for haiku aliases', { skip: shouldSkip }, async () => {
  const listener = startLogListener();

  const haikuPayload = {
    model: 'claude-haiku-4',
    max_tokens: 8,
    messages: [{ role: 'user', content: 'ping' }],
    stream: false
  };
  await postJson('/v1/messages', haikuPayload);

  const opusPayload = {
    model: 'claude-opus-4-5',
    max_tokens: 8,
    messages: [{ role: 'user', content: 'ping' }],
    stream: false
  };
  await postJson('/v1/messages', opusPayload);

  await new Promise((resolve) => setTimeout(resolve, 500));
  listener.req.destroy();

  const messages = listener.logs
    .map((entry) => entry?.message)
    .filter(Boolean);

  assert.equal(
    messages.some((msg) => msg.includes('model=moonshotai/') || msg.includes('model=minimax/')),
    false,
    `Expected no implicit Kilo model log, got: ${messages.join(' | ')}`
  );
});
