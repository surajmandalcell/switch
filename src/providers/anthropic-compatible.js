import { canonicalResponse, streamEvent } from '../domain/protocol/canonical.js';
import { anthropicUsageToCanonical } from '../domain/protocol/anthropic.js';
import { fetchWithTimeout } from './fetch.js';
import { parseSse } from './sse.js';

function headers(context) {
  return { 'content-type': 'application/json', 'anthropic-version': context.provider.adapter?.anthropicVersion ?? '2023-06-01', 'x-api-key': context.secret, ...context.provider.headers };
}

function payload(request, stream) {
  const content = (blocks) => blocks.flatMap((block) => {
    if (block.type === 'text') return [{ type: 'text', text: block.text }];
    if (block.type === 'tool-call') return [{ type: 'tool_use', id: block.id, name: block.name, input: block.input }];
    if (block.type === 'tool-result') return [{ type: 'tool_result', tool_use_id: block.toolCallId, content: block.content.map((item) => item.text ?? '').join(''), is_error: block.isError }];
    if (block.type === 'image' && block.data) return [{ type: 'image', source: { type: 'base64', media_type: block.mediaType, data: block.data } }];
    return [];
  });
  return { model: request.model, stream, max_tokens: request.maxOutputTokens ?? 4096, system: content(request.system), messages: request.messages.map((message) => ({ role: message.role === 'assistant' ? 'assistant' : 'user', content: content(message.content) })), tools: request.tools.length ? request.tools.map((tool) => ({ name: tool.name, description: tool.description, input_schema: tool.inputSchema })) : undefined, temperature: request.temperature ?? undefined, top_p: request.topP ?? undefined, stop_sequences: request.stopSequences.length ? request.stopSequences : undefined };
}

export function createAnthropicCompatibleAdapter({ type = 'anthropic-compatible', defaultBaseUrl = 'https://api.anthropic.com/v1' } = {}) {
  return {
    type,
    async execute(request, context) {
      const response = await fetchWithTimeout(`${(context.provider.baseUrl || defaultBaseUrl).replace(/\/$/, '')}/messages`, { method: 'POST', headers: headers(context), body: JSON.stringify(payload(request, false)), signal: context.signal }, context.timeoutMs);
      const data = await response.json();
      return canonicalResponse({ id: data.id, model: data.model ?? request.model, content: (data.content ?? []).flatMap((block) => block.type === 'text' ? [{ type: 'text', text: block.text }] : block.type === 'tool_use' ? [{ type: 'tool-call', id: block.id, name: block.name, input: block.input }] : []), stopReason: data.stop_reason, usage: anthropicUsageToCanonical(data.usage) });
    },
    async *stream(request, context) {
      const response = await fetchWithTimeout(`${(context.provider.baseUrl || defaultBaseUrl).replace(/\/$/, '')}/messages`, { method: 'POST', headers: headers(context), body: JSON.stringify(payload(request, true)), signal: context.signal }, context.timeoutMs);
      const tools = new Map();
      yield streamEvent('start', { model: request.model });
      for await (const wire of parseSse(response.body, context.signal)) {
        const data = JSON.parse(wire.data);
        if (wire.event === 'content_block_start' && data.content_block?.type === 'tool_use') tools.set(data.index, data.content_block);
        if (wire.event === 'content_block_delta' && data.delta?.type === 'text_delta') yield streamEvent('text-delta', { text: data.delta.text });
        if (wire.event === 'content_block_delta' && data.delta?.type === 'input_json_delta') { const tool = tools.get(data.index); yield streamEvent('tool-call', { id: tool?.id, name: tool?.name, argumentsDelta: data.delta.partial_json }); }
        if (wire.event === 'message_delta' && data.usage) yield streamEvent('usage', { usage: anthropicUsageToCanonical(data.usage) });
        if (wire.event === 'message_delta' && data.delta?.stop_reason) yield streamEvent('finish', { stopReason: data.delta.stop_reason });
      }
    },
  };
}
