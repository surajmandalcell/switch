import { invariant, newId } from '../shared.js';

export function canonicalRequest(input = {}) {
  invariant(input.model, 'A model is required.');
  return {
    id: input.id ?? newId('request'),
    model: String(input.model),
    stream: Boolean(input.stream),
    system: normalizeBlocks(input.system),
    messages: (input.messages ?? []).map((message) => ({
      role: normalizeRole(message.role),
      content: normalizeBlocks(message.content),
    })),
    tools: (input.tools ?? []).map((tool) => ({
      name: String(tool.name),
      description: String(tool.description ?? ''),
      inputSchema: tool.inputSchema ?? { type: 'object', properties: {} },
    })),
    toolChoice: input.toolChoice ?? null,
    temperature: finiteOrNull(input.temperature),
    topP: finiteOrNull(input.topP),
    maxOutputTokens: finiteOrNull(input.maxOutputTokens),
    stopSequences: Array.isArray(input.stopSequences) ? input.stopSequences.map(String) : [],
    metadata: input.metadata ?? {},
    stickyKey: input.stickyKey ?? null,
  };
}

function normalizeRole(role) {
  if (role === 'assistant') return 'assistant';
  if (role === 'tool') return 'tool';
  return 'user';
}

export function normalizeBlocks(content) {
  if (content === null || content === undefined) return [];
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  if (!Array.isArray(content)) return [{ type: 'text', text: String(content) }];
  return content.flatMap((block) => {
    if (typeof block === 'string') return [{ type: 'text', text: block }];
    if (!block || typeof block !== 'object') return [];
    if (block.type === 'text') return [{ type: 'text', text: String(block.text ?? '') }];
    if (block.type === 'image') return [{ type: 'image', mediaType: block.mediaType ?? 'image/png', data: block.data ?? null, url: block.url ?? null }];
    if (block.type === 'tool-call') return [{ type: 'tool-call', id: block.id ?? newId('tool'), name: String(block.name), input: block.input ?? {}, ...(block.thoughtSignature ? { thoughtSignature: block.thoughtSignature } : {}) }];
    if (block.type === 'tool-result') return [{ type: 'tool-result', toolCallId: String(block.toolCallId), name: block.name ?? null, content: normalizeBlocks(block.content), isError: Boolean(block.isError) }];
    return [];
  });
}

function finiteOrNull(value) {
  return Number.isFinite(Number(value)) ? Number(value) : null;
}

export function canonicalResponse(input = {}) {
  return {
    id: input.id ?? newId('response'),
    model: input.model ?? 'unknown',
    content: normalizeBlocks(input.content),
    stopReason: input.stopReason ?? 'end_turn',
    usage: normalizeUsage(input.usage),
    provider: input.provider ?? null,
    account: input.account ?? null,
  };
}

export function normalizeUsage(input = {}) {
  const inputTokens = Math.max(0, Number(input.inputTokens ?? input.prompt_tokens ?? 0) || 0);
  const outputTokens = Math.max(0, Number(input.outputTokens ?? input.completion_tokens ?? 0) || 0);
  const cacheReadTokens = Math.max(0, Number(input.cacheReadTokens ?? input.cached_tokens ?? 0) || 0);
  const cacheWriteTokens = Math.max(0, Number(input.cacheWriteTokens ?? 0) || 0);
  const directCost = Number(input.reportedCostUsd);
  const costTicks = Number(input.cost_in_usd_ticks);
  const reportedCostUsd = Number.isFinite(directCost)
    ? directCost
    : Number.isFinite(costTicks) ? costTicks / 10_000_000_000 : undefined;
  return {
    inputTokens,
    outputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    totalTokens: inputTokens + outputTokens,
    ...(reportedCostUsd === undefined ? {} : { reportedCostUsd }),
  };
}

export function streamEvent(type, data = {}) {
  return { type, ...data };
}
