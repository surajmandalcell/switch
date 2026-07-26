import { fromGeminiResponse, geminiChunkToCanonical, toGeminiRequest } from '../domain/protocol/gemini.js';
import { canonicalResponse, normalizeUsage, streamEvent } from '../domain/protocol/canonical.js';
import { fetchWithTimeout } from './fetch.js';
import { parseSse } from './sse.js';

const DEEP_RESEARCH_MODEL = /^deep-research(?:-max|-pro)?-/;
const TERMINAL_INTERACTION_STATES = new Set(['completed', 'failed', 'cancelled']);

export function createGeminiAdapter() {
  return {
    type: 'gemini',
    async execute(request, context) {
      if (isDeepResearchModel(request.model)) return executeDeepResearch(request, context);
      const base = geminiBase(context);
      const url = `${base}/models/${encodeURIComponent(request.model)}:generateContent?key=${encodeURIComponent(context.secret)}`;
      const response = await fetchWithTimeout(url, { method: 'POST', headers: { 'content-type': 'application/json', ...context.provider.headers }, body: JSON.stringify(toGeminiRequest(request)), signal: context.signal }, context.timeoutMs);
      return fromGeminiResponse(await response.json(), request.model);
    },
    async *stream(request, context) {
      if (isDeepResearchModel(request.model)) { yield* streamDeepResearch(request, context); return; }
      const base = geminiBase(context);
      const url = `${base}/models/${encodeURIComponent(request.model)}:streamGenerateContent?alt=sse&key=${encodeURIComponent(context.secret)}`;
      const response = await fetchWithTimeout(url, { method: 'POST', headers: { 'content-type': 'application/json', ...context.provider.headers }, body: JSON.stringify(toGeminiRequest(request)), signal: context.signal }, context.timeoutMs);
      yield streamEvent('start', { model: request.model });
      for await (const wire of parseSse(response.body, context.signal)) for (const event of geminiChunkToCanonical(JSON.parse(wire.data))) yield event;
    },
  };
}

function geminiBase(context) {
  return (context.provider.baseUrl || 'https://generativelanguage.googleapis.com/v1beta').replace(/\/$/, '');
}

export function isDeepResearchModel(model) {
  return DEEP_RESEARCH_MODEL.test(String(model ?? ''));
}

export function toDeepResearchRequest(request, adapter = {}) {
  const research = adapter.deepResearch ?? {};
  const body = {
    input: interactionInput(request),
    agent: request.model,
    background: true,
    agent_config: {
      type: 'deep-research',
      thinking_summaries: research.thinkingSummaries ?? 'auto',
      visualization: research.visualization ?? 'off',
      collaborative_planning: Boolean(research.collaborativePlanning),
    },
  };
  const previous = request.metadata?.previousInteractionId ?? request.metadata?.previous_interaction_id;
  if (previous) body.previous_interaction_id = previous;
  if (Array.isArray(research.tools) && research.tools.length) body.tools = structuredClone(research.tools);
  return body;
}

function interactionInput(request) {
  const content = [];
  const systemText = request.system.filter((block) => block.type === 'text').map((block) => block.text).join('\n');
  if (systemText) content.push({ type: 'text', text: `System instructions:\n${systemText}` });
  for (const message of request.messages) {
    const prefix = message.role === 'assistant' ? 'Assistant' : message.role === 'tool' ? 'Tool result' : 'User';
    for (const block of message.content) {
      if (block.type === 'text') content.push({ type: 'text', text: `${prefix}: ${block.text}` });
      if (block.type === 'image' && block.data) content.push({ type: 'image', data: block.data, mime_type: block.mediaType ?? 'image/png' });
      if (block.type === 'image' && block.url) content.push({ type: 'text', text: `${prefix} image URL: ${block.url}` });
      if (block.type === 'tool-result') content.push({ type: 'text', text: `${prefix}: ${block.content.map((item) => item.text ?? '').join('')}` });
    }
  }
  if (content.length === 1 && content[0].type === 'text') return content[0].text;
  return content;
}

async function executeDeepResearch(request, context) {
  const state = await createInteraction(request, context);
  const interaction = await pollInteraction(state, context);
  return interactionToCanonical(interaction, request.model);
}

async function* streamDeepResearch(request, context) {
  yield streamEvent('start', { model: request.model });
  const state = await createInteraction(request, context);
  let interaction = state.interaction;
  try {
    while (!TERMINAL_INTERACTION_STATES.has(interaction.status)) {
      if (Date.now() >= state.deadline) throw Object.assign(new Error('Gemini Deep Research exceeded its configured timeout.'), { code: 'ETIMEDOUT' });
      context.logger?.debug('Gemini Deep Research still running', { interactionId: interaction.id, status: interaction.status });
      yield streamEvent('heartbeat', { interactionId: interaction.id, status: interaction.status });
      await abortableDelay(state.intervalMs, context.signal);
      interaction = await getInteraction(state, context);
    }
  } catch (error) {
    if (context.signal?.aborted || error.name === 'AbortError') await cancelInteraction(state.base, interaction.id, state.headers);
    throw error;
  }
  assertInteractionSucceeded(interaction);
  for (const block of interactionContent(interaction)) {
    if (block.type === 'text' && block.text) yield streamEvent('text-delta', { text: block.text });
    if (block.type === 'image') yield streamEvent('image', block);
  }
  yield streamEvent('usage', { usage: interactionUsage(interaction.usage) });
  yield streamEvent('finish', { stopReason: 'end_turn' });
}

async function createInteraction(request, context) {
  const base = geminiBase(context);
  const headers = { 'content-type': 'application/json', 'x-goog-api-key': context.secret, ...context.provider.headers };
  const response = await fetchWithTimeout(`${base}/interactions`, { method: 'POST', headers, body: JSON.stringify(toDeepResearchRequest(request, context.provider.adapter)), signal: context.signal }, Math.min(context.timeoutMs, 60_000));
  const interaction = await response.json();
  if (!interaction.id) throw Object.assign(new Error('Gemini Deep Research did not return an interaction id.'), { status: 502, code: 'INVALID_INTERACTION' });
  const research = context.provider.adapter?.deepResearch ?? {};
  return {
    base,
    headers,
    interaction,
    intervalMs: Math.min(60_000, Math.max(250, Number(research.pollIntervalMs ?? 5_000))),
    deadline: Date.now() + Math.max(Number(context.timeoutMs ?? 120_000), Number(research.timeoutMs ?? 1_800_000)),
  };
}

async function pollInteraction(state, context) {
  let interaction = state.interaction;
  try {
    while (!TERMINAL_INTERACTION_STATES.has(interaction.status)) {
      if (Date.now() >= state.deadline) throw Object.assign(new Error('Gemini Deep Research exceeded its configured timeout.'), { code: 'ETIMEDOUT' });
      await abortableDelay(state.intervalMs, context.signal);
      interaction = await getInteraction(state, context);
    }
  } catch (error) {
    if (context.signal?.aborted || error.name === 'AbortError') await cancelInteraction(state.base, interaction.id, state.headers);
    throw error;
  }
  assertInteractionSucceeded(interaction);
  return interaction;
}

async function getInteraction(state, context) {
  const response = await fetchWithTimeout(`${state.base}/interactions/${encodeURIComponent(state.interaction.id)}`, { headers: state.headers, signal: context.signal }, Math.min(context.timeoutMs, 60_000));
  return response.json();
}

function assertInteractionSucceeded(interaction) {
  if (interaction.status === 'failed') throw Object.assign(new Error(interaction.error?.message ?? interaction.error ?? 'Gemini Deep Research failed.'), { status: 502, code: 'DEEP_RESEARCH_FAILED' });
  if (interaction.status === 'cancelled') throw Object.assign(new Error('Gemini Deep Research was cancelled.'), { name: 'AbortError', code: 'CLIENT_ABORTED' });
}

function interactionToCanonical(interaction, model) {
  return canonicalResponse({ id: interaction.id, model: interaction.agent ?? interaction.model ?? model, content: interactionContent(interaction), usage: interactionUsage(interaction.usage), stopReason: 'end_turn' });
}

function interactionContent(interaction) {
  const blocks = [];
  for (const step of interaction.steps ?? []) {
    if (step.type !== 'model_output') continue;
    for (const item of step.content ?? []) {
      if (item.type === 'text' && item.text) blocks.push({ type: 'text', text: item.text });
      if (item.type === 'image' && (item.data || item.uri)) blocks.push({ type: 'image', data: item.data ?? null, url: item.uri ?? null, mediaType: item.mime_type ?? 'image/png' });
    }
  }
  return blocks;
}

function interactionUsage(usage = {}) {
  return normalizeUsage({ inputTokens: usage.total_input_tokens, outputTokens: usage.total_output_tokens, cacheReadTokens: usage.total_cached_tokens });
}

async function cancelInteraction(base, id, headers) {
  if (!id) return;
  try { await fetch(`${base}/interactions/${encodeURIComponent(id)}/cancel`, { method: 'POST', headers }); } catch {}
}

function abortableDelay(ms, signal) {
  if (signal?.aborted) return Promise.reject(signal.reason ?? Object.assign(new Error('Cancelled'), { name: 'AbortError' }));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, ms);
    const abort = () => { clearTimeout(timer); reject(signal.reason ?? Object.assign(new Error('Cancelled'), { name: 'AbortError' })); };
    signal?.addEventListener('abort', abort, { once: true });
  });
}

export { interactionContent, interactionUsage, interactionToCanonical, abortableDelay, interactionInput };
