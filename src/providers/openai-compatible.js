import { canonicalResponse, normalizeUsage, streamEvent } from '../domain/protocol/canonical.js';
import { openAIChunkToCanonical } from '../domain/protocol/openai.js';
import { fetchWithTimeout, authHeaders } from './fetch.js';
import { parseSse } from './sse.js';

function toPayload(request, stream, provider = {}) {
  const messages = [];
  if (request.system.length) messages.push({ role: 'system', content: request.system.map((block) => block.text ?? '').join('\n') });
  for (const message of request.messages) {
    const content = message.content.filter((block) => block.type === 'text').map((block) => block.text).join('');
    const wire = { role: message.role === 'tool' ? 'tool' : message.role, content };
    const calls = message.content.filter((block) => block.type === 'tool-call');
    if (calls.length) wire.tool_calls = calls.map((block) => ({ id: block.id, type: 'function', function: { name: block.name, arguments: JSON.stringify(block.input ?? {}) } }));
    const result = message.content.find((block) => block.type === 'tool-result');
    if (result) { wire.role = 'tool'; wire.tool_call_id = result.toolCallId; wire.content = result.content.map((block) => block.text ?? '').join(''); }
    messages.push(wire);
  }
  return Object.fromEntries(Object.entries({ model: request.model, messages, stream, stream_options: stream ? { include_usage: true } : undefined, service_tier: provider.adapter?.serviceTier ?? undefined, tools: request.tools.length ? request.tools.map((tool) => ({ type: 'function', function: { name: tool.name, description: tool.description, parameters: tool.inputSchema } })) : undefined, tool_choice: request.toolChoice ?? undefined, temperature: request.temperature ?? undefined, top_p: request.topP ?? undefined, max_completion_tokens: request.maxOutputTokens ?? undefined, stop: request.stopSequences.length ? request.stopSequences : undefined }).filter(([, value]) => value !== undefined));
}

export function createOpenAICompatibleAdapter({ type = 'openai-compatible', defaultBaseUrl = 'https://api.openai.com/v1' } = {}) {
  return {
    type,
    async execute(request, context) {
      const baseUrl = (context.provider.baseUrl || defaultBaseUrl).replace(/\/$/, '');
      const response = await fetchWithTimeout(`${baseUrl}/chat/completions`, { method: 'POST', headers: requestHeaders(request, context), body: JSON.stringify(toPayload(request, false, context.provider)), signal: context.signal }, context.timeoutMs);
      const payload = await response.json();
      const choice = payload.choices?.[0] ?? {};
      const blocks = [];
      if (choice.message?.content) blocks.push({ type: 'text', text: choice.message.content });
      for (const call of choice.message?.tool_calls ?? []) blocks.push({ type: 'tool-call', id: call.id, name: call.function?.name, input: parseJson(call.function?.arguments) });
      return canonicalResponse({ id: payload.id, model: payload.model ?? request.model, content: blocks, stopReason: choice.finish_reason === 'tool_calls' ? 'tool_use' : choice.finish_reason === 'length' ? 'max_tokens' : 'end_turn', usage: normalizeUsage(payload.usage) });
    },
    async *stream(request, context) {
      const baseUrl = (context.provider.baseUrl || defaultBaseUrl).replace(/\/$/, '');
      const response = await fetchWithTimeout(`${baseUrl}/chat/completions`, { method: 'POST', headers: requestHeaders(request, context), body: JSON.stringify(toPayload(request, true, context.provider)), signal: context.signal }, context.timeoutMs);
      yield streamEvent('start', { model: request.model });
      for await (const event of parseSse(response.body, context.signal)) {
        if (event.data === '[DONE]') break;
        const chunk = JSON.parse(event.data);
        for (const canonical of openAIChunkToCanonical(chunk)) yield canonical;
      }
    },
  };
}

function requestHeaders(request, context) {
  const headers = authHeaders(context.secret, context.provider);
  if (context.provider.type === 'grok' && request.stickyKey) headers['x-grok-conv-id'] = request.stickyKey;
  return headers;
}

function parseJson(value) { try { return JSON.parse(value ?? '{}'); } catch { return {}; } }
