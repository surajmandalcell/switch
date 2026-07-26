import { resolveModelAlias } from '../domain/config.js';
import { choosePricingRule, estimateCost, summarizeUsage, usageToCsv } from '../domain/usage.js';

export class UsageService {
  constructor(repository, configProvider) {
    this.repository = repository;
    this.configProvider = configProvider;
  }

  record(input) {
    const config = this.configProvider();
    const provider = config.providers.find((item) => item.id === input.providerId);
    const rule = choosePricingRule(config.pricing, input.providerId, provider?.type, input.upstreamModel ?? input.requestedModel);
    const estimate = estimateCost(input, rule);
    return this.repository.insert({ ...input, estimatedCostUsd: input.reportedCostUsd ?? input.estimatedCostUsd ?? estimate.usd, pricingKnown: input.reportedCostUsd !== undefined || estimate.known });
  }

  estimateRouteCosts(request) {
    const config = this.configProvider();
    const inputTokens = estimateCanonicalInputTokens(request);
    const outputTokens = Math.max(1, Number(request.maxOutputTokens ?? 1024));
    return Object.fromEntries(config.providers.map((provider) => {
      const model = resolveModelAlias(config, request.model, provider.id);
      const rule = choosePricingRule(config.pricing, provider.id, provider.type, model);
      return [provider.id, estimateCost({ inputTokens, outputTokens }, rule).usd];
    }));
  }

  list(filters = {}, options = {}) {
    return this.repository.list(filters, options);
  }

  summary(filters = {}) {
    if (typeof this.repository.summary === 'function') return this.repository.summary(filters);
    return summarizeUsage(this.repository.list(filters), filters);
  }

  csv(filters = {}) {
    if (typeof this.repository.csv === 'function') return this.repository.csv(filters);
    return usageToCsv(this.repository.list(filters), filters);
  }

  attempts(requestId) {
    return this.repository.listAttempts?.(requestId) ?? [];
  }

  prune(days) {
    return this.repository.prune(days);
  }
}

export function estimateCanonicalInputTokens(request) {
  const value = JSON.stringify({ system: request.system, messages: request.messages, tools: request.tools });
  return Math.max(1, Math.ceil(value.length / 4));
}
