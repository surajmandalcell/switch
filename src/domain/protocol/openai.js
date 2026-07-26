import { canonicalRequest, canonicalResponse, normalizeBlocks, normalizeUsage, streamEvent } from './canonical.js';

function openAIContentToBlocks(content) {
  if (content == null) return [];
  if (typeof content === 'string') return normalizeBlocks(content);
  return (content ?? []).flatMap((part) => {
    if (part.type === 'text' || part.type === 'input_text' || part.type === 'output_text') return [{ type: 'text', text: part.text ?? '' }];
    const imageUrl = part.image_url?.url ?? part.image_url ?? part.url;
    if (part.type === 'image_url' || part.type === 'input_image') return [{ type: 'image', url: imageUrl ?? null, mediaType: part.media_type ?? null, data: part.data ?? null }];
    return [];
  });
}

export function fromOpenAIChat(body = {}, headers = {}) {
  return canonicalRequest({
    model: body.model,
    stream: body.stream,
    system: (body.messages ?? []).filter((message) => ['system', 'developer'].includes(message.role)).flatMap((message) => openAIContentToBlocks(message.content)),
    messages: (body.messages ?? []).filter((message) => !['system', 'developer'].includes(message.role)).map((message) => {
      const blocks = openAIContentToBlocks(message.content);
      for (const call of message.tool_calls ?? []) blocks.push({ type: 'tool-call', id: call.id, name: call.function?.name, input: parseJson(call.function?.arguments, {}) });
      if (message.role === 'tool') blocks.push({ type: 'tool-result', toolCallId: message.tool_call_id, name: message.name ?? null, content: openAIContentToBlocks(message.content) });
      return { role: message.role, content: blocks };
    }),
    tools: (body.tools ?? []).map((tool) => ({ name: tool.function?.name, description: tool.function?.description, inputSchema: tool.function?.parameters })),
    toolChoice: body.tool_choice,
    temperature: body.temperature,
    topP: body.top_p,
    maxOutputTokens: body.max_completion_tokens ?? body.max_tokens,
    stopSequences: Array.isArray(body.stop) ? body.stop : body.stop ? [body.stop] : [],
    stickyKey: headers['x-session-id'] ?? headers['x-sticky-session'] ?? null,
    metadata: body.metadata ?? {},
  });
}

export function fromOpenAIResponses(body = {}, headers = {}) {
  const messages = [];
  for (const item of Array.isArray(body.input) ? body.input : [{ role: 'user', content: body.input ?? '' }]) {
    if (item.type === 'function_call_output') {
      messages.push({ role: 'tool', content: [{ type: 'tool-result', toolCallId: item.call_id, content: item.output }] });
    } else {
      messages.push({ role: item.role ?? 'user', content: openAIContentToBlocks(item.content) });
    }
  }
  return canonicalRequest({
    model: body.model,
    stream: body.stream,
    system: openAIContentToBlocks(body.instructions ?? ''),
    messages,
    tools: (body.tools ?? []).filter((tool) => tool.type === 'function').map((tool) => ({ name: tool.name, description: tool.description, inputSchema: tool.parameters })),
    toolChoice: body.tool_choice,
    temperature: body.temperature,
    topP: body.top_p,
    maxOutputTokens: body.max_output_tokens,
    stickyKey: headers['x-session-id'] ?? null,
    metadata: body.metadata ?? {},
  });
}

function parseJson(value, fallback) {
  try { return typeof value === 'string' ? JSON.parse(value) : value ?? fallback; } catch { return fallback; }
}

function blocksToOpenAI(blocks) {
  const text = blocks.filter((block) => block.type === 'text').map((block) => block.text).join('');
  const calls = blocks.filter((block) => block.type === 'tool-call').map((block) => ({ id: block.id, type: 'function', function: { name: block.name, arguments: JSON.stringify(block.input ?? {}) } }));
  return { text, calls };
}

export function toOpenAIChat(response) {
  const canonical = canonicalResponse(response);
  const { text, calls } = blocksToOpenAI(canonical.content);
  return {
    id: canonical.id,
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: canonical.model,
    choices: [{ index: 0, message: { role: 'assistant', content: text || null, ...(calls.length ? { tool_calls: calls } : {}) }, finish_reason: mapStop(canonical.stopReason) }],
    usage: { prompt_tokens: canonical.usage.inputTokens, completion_tokens: canonical.usage.outputTokens, total_tokens: canonical.usage.totalTokens, prompt_tokens_details: { cached_tokens: canonical.usage.cacheReadTokens } },
  };
}

export function toOpenAIResponse(response) {
  const canonical = canonicalResponse(response);
  const output = [];
  const text = canonical.content.filter((block) => block.type === 'text').map((block) => block.text).join('');
  if (text) output.push({ id: `${canonical.id}_message`, type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text, annotations: [] }] });
  for (const block of canonical.content.filter((item) => item.type === 'tool-call')) output.push({ id: block.id, type: 'function_call', call_id: block.id, name: block.name, arguments: JSON.stringify(block.input ?? {}), status: 'completed' });
  return { id: canonical.id, object: 'response', created_at: Math.floor(Date.now() / 1000), status: 'completed', model: canonical.model, output, usage: { input_tokens: canonical.usage.inputTokens, output_tokens: canonical.usage.outputTokens, total_tokens: canonical.usage.totalTokens, input_tokens_details: { cached_tokens: canonical.usage.cacheReadTokens } } };
}

export function openAIChatStream(event, context = {}) {
  const base = { id: context.id, object: 'chat.completion.chunk', created: context.created ?? Math.floor(Date.now() / 1000), model: context.model, choices: [{ index: 0, delta: {}, finish_reason: null }] };
  if (event.type === 'start') base.choices[0].delta = { role: 'assistant' };
  if (event.type === 'text-delta') base.choices[0].delta = { content: event.text };
  if (event.type === 'tool-call') base.choices[0].delta = { tool_calls: [{ index: event.index ?? 0, id: event.id, type: 'function', function: { name: event.name, arguments: event.argumentsDelta ?? '' } }] };
  if (event.type === 'finish') base.choices[0].finish_reason = mapStop(event.stopReason);
  if (event.type === 'usage') base.usage = { prompt_tokens: event.usage.inputTokens, completion_tokens: event.usage.outputTokens, total_tokens: event.usage.totalTokens };
  return base;
}

export function openAIResponseStream(event, context = {}) {
  if (event.type === 'start') return { type: 'response.created', response: { id: context.id, object: 'response', status: 'in_progress', model: context.model, output: [] } };
  if (event.type === 'text-delta') return { type: 'response.output_text.delta', item_id: `${context.id}_message`, output_index: 0, content_index: 0, delta: event.text };
  if (event.type === 'tool-call') return { type: 'response.function_call_arguments.delta', item_id: event.id, output_index: event.index ?? 0, delta: event.argumentsDelta ?? '' };
  if (event.type === 'finish') return { type: 'response.completed', response: { id: context.id, object: 'response', status: 'completed', model: context.model, output: [], usage: event.usage ?? undefined } };
  return { type: 'response.in_progress', response: { id: context.id, status: 'in_progress' } };
}

function mapStop(reason) {
  return ({ end_turn: 'stop', max_tokens: 'length', tool_use: 'tool_calls', stop_sequence: 'stop' })[reason] ?? 'stop';
}

export function openAIChunkToCanonical(chunk) {
  const choice = chunk.choices?.[0];
  const events = [];
  if (choice?.delta?.content) events.push(streamEvent('text-delta', { text: choice.delta.content }));
  for (const call of choice?.delta?.tool_calls ?? []) events.push(streamEvent('tool-call', { index: call.index, id: call.id, name: call.function?.name, argumentsDelta: call.function?.arguments ?? '' }));
  if (choice?.finish_reason) events.push(streamEvent('finish', { stopReason: choice.finish_reason === 'tool_calls' ? 'tool_use' : choice.finish_reason === 'length' ? 'max_tokens' : 'end_turn' }));
  if (chunk.usage) events.push(streamEvent('usage', { usage: normalizeUsage(chunk.usage) }));
  return events;
}
