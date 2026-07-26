import { canonicalResponse, normalizeUsage, streamEvent } from './canonical.js';

export function toGeminiRequest(request) {
  const contents = [];
  for (const message of request.messages) {
    const parts = [];
    for (const block of message.content) {
      if (block.type === 'text') parts.push({ text: block.text });
      if (block.type === 'image') {
        if (block.data) parts.push({ inlineData: { mimeType: block.mediaType ?? 'image/png', data: block.data } });
        else if (block.url) parts.push({ fileData: { mimeType: block.mediaType ?? 'application/octet-stream', fileUri: block.url } });
      }
      if (block.type === 'tool-call') parts.push({ functionCall: { name: block.name, args: block.input ?? {} }, thoughtSignature: block.thoughtSignature });
      if (block.type === 'tool-result') parts.push({ functionResponse: { name: block.name ?? 'tool', response: { result: block.content, isError: block.isError } } });
    }
    contents.push({ role: message.role === 'assistant' ? 'model' : 'user', parts });
  }
  const payload = { contents };
  if (request.system.length) payload.systemInstruction = { parts: request.system.map((block) => ({ text: block.text ?? '' })) };
  if (request.tools.length) payload.tools = [{ functionDeclarations: request.tools.map((tool) => ({ name: tool.name, description: tool.description, parameters: tool.inputSchema })) }];
  payload.generationConfig = Object.fromEntries(Object.entries({ temperature: request.temperature, topP: request.topP, maxOutputTokens: request.maxOutputTokens, stopSequences: request.stopSequences.length ? request.stopSequences : undefined }).filter(([, value]) => value !== null && value !== undefined));
  return payload;
}

export function fromGeminiResponse(payload, model) {
  const candidate = payload.candidates?.[0] ?? {};
  const content = [];
  for (const part of candidate.content?.parts ?? []) {
    if (part.text) content.push({ type: 'text', text: part.text });
    if (part.functionCall) content.push({ type: 'tool-call', id: part.functionCall.id ?? `${model}-tool-${content.length}`, name: part.functionCall.name, input: part.functionCall.args ?? {}, thoughtSignature: part.thoughtSignature });
  }
  return canonicalResponse({ model, content, stopReason: mapFinish(candidate.finishReason), usage: normalizeUsage({ inputTokens: payload.usageMetadata?.promptTokenCount, outputTokens: payload.usageMetadata?.candidatesTokenCount, cacheReadTokens: payload.usageMetadata?.cachedContentTokenCount }) });
}

export function geminiChunkToCanonical(payload) {
  const candidate = payload.candidates?.[0] ?? {};
  const events = [];
  for (const part of candidate.content?.parts ?? []) {
    if (part.text) events.push(streamEvent('text-delta', { text: part.text }));
    if (part.functionCall) events.push(streamEvent('tool-call', { id: part.functionCall.id ?? `gemini-tool-${events.length}`, name: part.functionCall.name, argumentsDelta: JSON.stringify(part.functionCall.args ?? {}), thoughtSignature: part.thoughtSignature }));
  }
  if (payload.usageMetadata) events.push(streamEvent('usage', { usage: normalizeUsage({ inputTokens: payload.usageMetadata.promptTokenCount, outputTokens: payload.usageMetadata.candidatesTokenCount, cacheReadTokens: payload.usageMetadata.cachedContentTokenCount }) }));
  if (candidate.finishReason) events.push(streamEvent('finish', { stopReason: mapFinish(candidate.finishReason) }));
  return events;
}

function mapFinish(reason) {
  if (reason === 'MAX_TOKENS') return 'max_tokens';
  if (reason === 'STOP') return 'end_turn';
  if (reason === 'MALFORMED_FUNCTION_CALL') return 'tool_use';
  return 'end_turn';
}
