import { fromAnthropicMessages, toAnthropicMessage, AnthropicStreamState } from '../domain/protocol/anthropic.js';
import { fromOpenAIChat, fromOpenAIResponses, toOpenAIChat, toOpenAIResponse, openAIChatStream, openAIResponseStream } from '../domain/protocol/openai.js';
import { newId } from '../domain/shared.js';

export class ProxyService {
  constructor({ routing, getConfig, resolveSecret, logger, usageService, clock = () => Date.now() }) {
    this.routing = routing;
    this.getConfig = getConfig;
    this.resolveSecret = resolveSecret;
    this.logger = logger;
    this.usageService = usageService;
    this.clock = clock;
  }

  normalize(protocol, body, headers = {}) {
    if (protocol === 'openai-chat') return fromOpenAIChat(body, headers);
    if (protocol === 'openai-responses') return fromOpenAIResponses(body, headers);
    if (protocol === 'anthropic') return fromAnthropicMessages(body, headers);
    throw Object.assign(new Error(`Unsupported protocol: ${protocol}`), { status: 404, code: 'unsupported_protocol' });
  }

  prepare(protocol, body, headers) {
    const request = this.normalize(protocol, body, headers);
    request.estimatedCosts = this.usageService?.estimateRouteCosts?.(request) ?? {};
    return request;
  }

  async execute(protocol, body, headers = {}, signal) {
    const request = this.prepare(protocol, body, headers);
    const startedMs = this.clock();
    const startedAt = new Date(startedMs).toISOString();
    try {
      const result = await this.routing.execute(request, this.context(signal));
      const output = protocol === 'anthropic' ? toAnthropicMessage(result.response) : protocol === 'openai-responses' ? toOpenAIResponse(result.response) : toOpenAIChat(result.response);
      this.record({ id: request.id, startedAt, status: 'success', protocol, requestedModel: request.model, upstreamModel: result.response.model, providerId: result.candidate.provider.id, accountId: result.candidate.account.id, latencyMs: this.clock() - startedMs, ...result.response.usage });
      return output;
    } catch (error) {
      const last = error.failures?.at(-1);
      this.record({ id: request.id, startedAt, status: error.code === 'client_cancelled' ? 'cancelled' : 'error', protocol, requestedModel: request.model, upstreamModel: last?.upstreamModel ?? request.model, providerId: last?.providerId ?? null, accountId: last?.accountId ?? null, latencyMs: this.clock() - startedMs, errorCode: error.code ?? 'upstream_error' });
      throw error;
    }
  }

  async *stream(protocol, body, headers = {}, signal) {
    const request = this.prepare(protocol, body, headers);
    const startedMs = this.clock();
    const startedAt = new Date(startedMs).toISOString();
    const id = newId('response');
    const wireContext = { id, model: request.model };
    const anthropic = protocol === 'anthropic' ? new AnthropicStreamState(wireContext) : null;
    let usage = null;
    let firstTokenLatencyMs = null;
    let route = null;
    const observer = {
      attemptSucceeded: ({ candidate, upstreamRequest }) => { route = { providerId: candidate.provider.id, accountId: candidate.account.id, upstreamModel: upstreamRequest.model }; },
      attemptFailed: ({ candidate, upstreamRequest }) => { route = { providerId: candidate.provider.id, accountId: candidate.account.id, upstreamModel: upstreamRequest.model }; },
    };
    try {
      for await (const event of this.routing.stream(request, this.context(signal, observer))) {
        if (event.type === 'heartbeat') { yield { comment: 'keep-alive' }; continue; }
        if (event.type === 'usage') usage = event.usage;
        if (firstTokenLatencyMs === null && isVisible(event)) firstTokenLatencyMs = this.clock() - startedMs;
        if (protocol === 'anthropic') {
          for (const serialized of anthropic.serialize(event)) yield serialized;
        } else if (protocol === 'openai-responses') {
          const serialized = openAIResponseStream(event, wireContext);
          yield { event: serialized.type, data: serialized };
        } else {
          yield { data: openAIChatStream(event, wireContext) };
        }
      }
      if (protocol !== 'anthropic' && protocol !== 'openai-responses') yield { data: '[DONE]' };
      this.record({ id: request.id, startedAt, status: 'success', protocol, requestedModel: request.model, upstreamModel: route?.upstreamModel ?? request.model, providerId: route?.providerId ?? null, accountId: route?.accountId ?? null, latencyMs: this.clock() - startedMs, firstTokenLatencyMs, ...(usage ?? {}) });
    } catch (error) {
      const last = error.failures?.at(-1);
      this.record({ id: request.id, startedAt, status: error.code === 'client_cancelled' ? 'cancelled' : 'error', protocol, requestedModel: request.model, upstreamModel: last?.upstreamModel ?? route?.upstreamModel ?? request.model, providerId: last?.providerId ?? route?.providerId ?? null, accountId: last?.accountId ?? route?.accountId ?? null, latencyMs: this.clock() - startedMs, firstTokenLatencyMs, ...(usage ?? {}), errorCode: error.code ?? 'upstream_error' });
      throw error;
    }
  }

  record(value) {
    try { return this.usageService?.record(value); }
    catch (error) { this.logger?.error('Failed to persist usage record', { requestId: value.id, message: error.message }); return null; }
  }

  context(signal, observer = undefined) {
    return { config: this.getConfig(), resolveSecret: this.resolveSecret, logger: this.logger, signal, observer };
  }
}

function isVisible(event) {
  return event?.type === 'tool-call' || (event?.type === 'text-delta' && Boolean(event.text));
}
