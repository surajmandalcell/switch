import { canonicalRequest, canonicalResponse, normalizeUsage } from './canonical.js';

export function fromAnthropicMessages(body = {}, headers = {}) {
  return canonicalRequest({
    model: body.model,
    stream: body.stream,
    system: anthropicBlocks(body.system),
    messages: (body.messages ?? []).map((message) => ({ role: message.role, content: anthropicBlocks(message.content) })),
    tools: (body.tools ?? []).map((tool) => ({ name: tool.name, description: tool.description, inputSchema: tool.input_schema })),
    toolChoice: body.tool_choice,
    temperature: body.temperature,
    topP: body.top_p,
    maxOutputTokens: body.max_tokens,
    stopSequences: body.stop_sequences,
    stickyKey: headers['x-session-id'] ?? headers['anthropic-session-id'] ?? null,
    metadata: body.metadata ?? {},
  });
}

function anthropicBlocks(content) {
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  if (!Array.isArray(content)) return [];
  return content.flatMap((block) => {
    if (block.type === 'text') return [{ type: 'text', text: block.text ?? '' }];
    if (block.type === 'image') return [{ type: 'image', mediaType: block.source?.media_type, data: block.source?.data, url: block.source?.url }];
    if (block.type === 'tool_use') return [{ type: 'tool-call', id: block.id, name: block.name, input: block.input ?? {} }];
    if (block.type === 'tool_result') return [{ type: 'tool-result', toolCallId: block.tool_use_id, content: anthropicBlocks(block.content), isError: block.is_error }];
    return [];
  });
}

export function toAnthropicMessage(response) {
  const canonical = canonicalResponse(response);
  return {
    id: canonical.id,
    type: 'message',
    role: 'assistant',
    model: canonical.model,
    content: canonical.content.flatMap((block) => {
      if (block.type === 'text') return [{ type: 'text', text: block.text }];
      if (block.type === 'tool-call') return [{ type: 'tool_use', id: block.id, name: block.name, input: block.input }];
      return [];
    }),
    stop_reason: ({ end_turn: 'end_turn', max_tokens: 'max_tokens', tool_use: 'tool_use', stop_sequence: 'stop_sequence' })[canonical.stopReason] ?? 'end_turn',
    stop_sequence: null,
    usage: { input_tokens: canonical.usage.inputTokens, output_tokens: canonical.usage.outputTokens, cache_read_input_tokens: canonical.usage.cacheReadTokens, cache_creation_input_tokens: canonical.usage.cacheWriteTokens },
  };
}

export class AnthropicStreamState {
  constructor(context) {
    this.context = context;
    this.nextIndex = 0;
    this.toolIndexes = new Map();
  }

  serialize(event) {
    if (event.type === 'start') return [{ event: 'message_start', data: { type: 'message_start', message: { id: this.context.id, type: 'message', role: 'assistant', model: this.context.model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0 } } } }];
    if (event.type === 'text-delta') {
      const index = this.nextIndex;
      if (!this.toolIndexes.has('__text__')) { this.toolIndexes.set('__text__', index); this.nextIndex += 1; return [
        { event: 'content_block_start', data: { type: 'content_block_start', index, content_block: { type: 'text', text: '' } } },
        { event: 'content_block_delta', data: { type: 'content_block_delta', index, delta: { type: 'text_delta', text: event.text } } },
      ]; }
      return [{ event: 'content_block_delta', data: { type: 'content_block_delta', index: this.toolIndexes.get('__text__'), delta: { type: 'text_delta', text: event.text } } }];
    }
    if (event.type === 'tool-call') {
      let index = this.toolIndexes.get(event.id);
      const output = [];
      if (index === undefined) { index = this.nextIndex++; this.toolIndexes.set(event.id, index); output.push({ event: 'content_block_start', data: { type: 'content_block_start', index, content_block: { type: 'tool_use', id: event.id, name: event.name, input: {} } } }); }
      if (event.argumentsDelta) output.push({ event: 'content_block_delta', data: { type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: event.argumentsDelta } } });
      return output;
    }
    if (event.type === 'usage') return [{ event: 'message_delta', data: { type: 'message_delta', delta: { stop_reason: null, stop_sequence: null }, usage: { output_tokens: event.usage.outputTokens } } }];
    if (event.type === 'finish') return [
      ...[...this.toolIndexes.values()].map((index) => ({ event: 'content_block_stop', data: { type: 'content_block_stop', index } })),
      { event: 'message_delta', data: { type: 'message_delta', delta: { stop_reason: event.stopReason ?? 'end_turn', stop_sequence: null }, usage: { output_tokens: event.usage?.outputTokens ?? 0 } } },
      { event: 'message_stop', data: { type: 'message_stop' } },
    ];
    return [];
  }
}

export function anthropicUsageToCanonical(usage) {
  return normalizeUsage({ inputTokens: usage?.input_tokens, outputTokens: usage?.output_tokens, cacheReadTokens: usage?.cache_read_input_tokens, cacheWriteTokens: usage?.cache_creation_input_tokens });
}
