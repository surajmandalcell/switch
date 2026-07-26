import { RoutingEngine } from '../domain/routing/router.js';
import { classifyUpstreamError, UpstreamError } from '../domain/routing/errors.js';
import { resolveModelAlias } from '../domain/config.js';
import { newId } from '../domain/shared.js';

const VISIBLE_EVENTS = new Set(['text-delta', 'tool-call']);

export class RoutingService {
  constructor({ registry, runtime, usage, engine = new RoutingEngine(), clock = () => Date.now(), hooks = {} }) {
    this.registry = registry;
    this.runtime = runtime;
    this.usage = usage;
    this.engine = engine;
    this.clock = clock;
    this.hooks = hooks;
  }

  async execute(request, context) {
    const plan = this.engine.plan(context.config, request, this.runtime.snapshot(), this.usage);
    const failures = [];
    for (let candidate = plan.next(); candidate; candidate = plan.next()) {
      const startedAt = this.clock();
      const attemptId = newId('attempt');
      const upstreamRequest = { ...request, model: resolveModelAlias(context.config, request.model, candidate.provider.id) };
      this.runtime.begin(candidate.account.id);
      this.notify(context, 'attemptStarted', { attemptId, candidate, request, upstreamRequest, startedAt });
      try {
        const adapter = this.registry.get(candidate.provider.type);
        const response = await adapter.execute(upstreamRequest, this.adapterContext(candidate, context));
        const latencyMs = this.clock() - startedAt;
        this.runtime.succeed(candidate.account.id, latencyMs);
        this.notify(context, 'attemptSucceeded', { attemptId, candidate, request, upstreamRequest, response, latencyMs, startedAt });
        return { response, candidate, failures };
      } catch (cause) {
        const error = classifyUpstreamError({ message: cause?.message, status: cause?.status, code: cause?.code, name: cause?.name, retryAfter: cause?.retryAfter ?? cause?.details?.retryAfter, headers: cause?.headers, cause, failureCount: this.runtime.get(candidate.account.id).failures }, context.config.routing, this.clock());
        if (error.code === 'client_cancelled') this.runtime.cancel(candidate.account.id);
        else this.runtime.fail(candidate.account.id, error, this.clock());
        const latencyMs = this.clock() - startedAt;
        failures.push({ attemptId, providerId: candidate.provider.id, accountId: candidate.account.id, upstreamModel: upstreamRequest.model, startedAt, latencyMs, error });
        this.notify(context, 'attemptFailed', { attemptId, candidate, request, upstreamRequest, error, latencyMs, startedAt });
        if (!error.retryable || error.code === 'client_cancelled') throw withFailures(error, failures);
      }
    }
    throw withFailures(new UpstreamError('No eligible provider account could satisfy the request.', { code: 'no_route', status: 503, retryable: false }), failures);
  }

  async *stream(request, context) {
    const plan = this.engine.plan(context.config, request, this.runtime.snapshot(), this.usage);
    const failures = [];
    for (let candidate = plan.next(); candidate; candidate = plan.next()) {
      const startedAt = this.clock();
      const attemptId = newId('attempt');
      const upstreamRequest = { ...request, model: resolveModelAlias(context.config, request.model, candidate.provider.id) };
      this.runtime.begin(candidate.account.id);
      this.notify(context, 'attemptStarted', { attemptId, candidate, request, upstreamRequest, startedAt });
      const buffered = [];
      let visible = false;
      try {
        const adapter = this.registry.get(candidate.provider.type);
        for await (const event of adapter.stream(upstreamRequest, this.adapterContext(candidate, context))) {
          if (event?.type === 'heartbeat') { yield event; continue; }
          if (!visible && isVisible(event)) {
            visible = true;
            for (const pending of buffered.splice(0)) yield pending;
          }
          if (visible) yield event;
          else buffered.push(event);
        }
        if (!visible) for (const pending of buffered) yield pending;
        const latencyMs = this.clock() - startedAt;
        this.runtime.succeed(candidate.account.id, latencyMs);
        this.notify(context, 'attemptSucceeded', { attemptId, candidate, request, upstreamRequest, latencyMs, startedAt, streamed: true });
        return;
      } catch (cause) {
        const error = classifyUpstreamError({ message: cause?.message, status: cause?.status, code: cause?.code, name: cause?.name, retryAfter: cause?.retryAfter ?? cause?.details?.retryAfter, headers: cause?.headers, cause, failureCount: this.runtime.get(candidate.account.id).failures }, context.config.routing, this.clock());
        if (error.code === 'client_cancelled') this.runtime.cancel(candidate.account.id);
        else this.runtime.fail(candidate.account.id, error, this.clock());
        const latencyMs = this.clock() - startedAt;
        failures.push({ attemptId, providerId: candidate.provider.id, accountId: candidate.account.id, upstreamModel: upstreamRequest.model, startedAt, latencyMs, visible, error });
        this.notify(context, 'attemptFailed', { attemptId, candidate, request, upstreamRequest, error, visible, latencyMs, startedAt });
        if (visible || !error.retryable || error.code === 'client_cancelled') throw withFailures(error, failures);
      }
    }
    throw withFailures(new UpstreamError('No eligible provider account could satisfy the streaming request.', { code: 'no_route', status: 503 }), failures);
  }

  notify(context, name, payload) {
    this.hooks[name]?.(payload);
    context.observer?.[name]?.(payload);
  }

  adapterContext(candidate, context) {
    return {
      provider: candidate.provider,
      account: candidate.account,
      signal: context.signal,
      secret: context.resolveSecret(candidate.account.secretRef),
      timeoutMs: context.config.server.requestTimeoutMs,
      logger: context.logger,
    };
  }
}

function isVisible(event) {
  return VISIBLE_EVENTS.has(event?.type) && (event.type !== 'text-delta' || Boolean(event.text));
}

function withFailures(error, failures) {
  error.failures = failures;
  return error;
}
