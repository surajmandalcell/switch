import { matchesGlob } from '../shared.js';
import { evaluateAccountLimits } from './limits.js';
import { selectCandidate, StrategyState } from './strategies.js';

export class RoutingEngine {
  constructor({ state = new StrategyState(), now = () => Date.now(), random = Math.random } = {}) {
    this.state = state;
    this.now = now;
    this.random = random;
  }

  candidates(config, request, runtime = new Map(), usage = {}) {
    const now = this.now();
    const output = [];
    for (const provider of config.providers) {
      if (!provider.enabled || !provider.modelGlobs.some((glob) => matchesGlob(request.model, glob))) continue;
      for (const account of provider.accounts) {
        if (!account.enabled) continue;
        const routeRuntime = runtime.get(account.id) ?? {};
        if ((routeRuntime.cooldownUntil ?? 0) > now || routeRuntime.attention) continue;
        const limits = evaluateAccountLimits(account, usage, now);
        if (!limits.allowed) continue;
        output.push({
          provider,
          account,
          runtime: routeRuntime,
          estimatedCostUsd: request.estimatedCosts?.[provider.id] ?? Number.POSITIVE_INFINITY,
          limitState: limits,
        });
      }
    }
    return output;
  }

  plan(config, request, runtime = new Map(), usage = {}) {
    const pool = this.candidates(config, request, runtime, usage);
    const attempted = new Set();
    const globalLimit = config.routing.maxAttempts;
    const next = () => {
      const remaining = pool.filter((candidate) => !attempted.has(`${candidate.provider.id}:${candidate.account.id}`));
      if (!remaining.length || attempted.size >= globalLimit) return null;
      const providerGroups = new Map();
      for (const candidate of remaining) {
        const list = providerGroups.get(candidate.provider.id) ?? [];
        list.push(candidate);
        providerGroups.set(candidate.provider.id, list);
      }
      const eligible = remaining.filter((candidate) => {
        const providerAttemptCount = [...attempted].filter((key) => key.startsWith(`${candidate.provider.id}:`)).length;
        return providerAttemptCount < (candidate.provider.maxAttempts ?? globalLimit);
      });
      if (!eligible.length) return null;
      const strategies = new Set(eligible.map((candidate) => candidate.provider.strategyOverride ?? config.routing.strategy));
      const strategy = strategies.size === 1 ? strategies.values().next().value : config.routing.strategy;
      const selected = selectCandidate(strategy, eligible, {
        now: this.now(),
        random: this.random,
        stickyKey: request.stickyKey,
        stickyTtlMs: config.routing.stickyTtlMs,
        scopeKey: request.model,
      }, this.state);
      attempted.add(`${selected.provider.id}:${selected.account.id}`);
      return selected;
    };
    return { size: pool.length, next, attempted };
  }
}
