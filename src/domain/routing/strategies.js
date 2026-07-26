import { invariant } from '../shared.js';

export class StrategyState {
  constructor() {
    this.roundRobin = new Map();
    this.sticky = new Map();
  }

  pruneSticky(now = Date.now()) {
    for (const [key, value] of this.sticky) if (value.expiresAt <= now) this.sticky.delete(key);
  }
}

function byIdentity(a, b) {
  return a.provider.id.localeCompare(b.provider.id) || a.account.id.localeCompare(b.account.id);
}

function stableCandidates(candidates) {
  return [...candidates].sort(byIdentity);
}

function priority(candidates) {
  return stableCandidates(candidates).sort((a, b) => a.account.priority - b.account.priority || byIdentity(a, b))[0];
}

function roundRobin(candidates, context, state) {
  const ordered = stableCandidates(candidates);
  const key = context.scopeKey ?? 'global';
  const index = state.roundRobin.get(key) ?? 0;
  state.roundRobin.set(key, (index + 1) % ordered.length);
  return ordered[index % ordered.length];
}

function weightedRandom(candidates, context) {
  const random = context.random ?? Math.random;
  const total = candidates.reduce((sum, candidate) => sum + Math.max(0, candidate.account.weight), 0);
  if (total <= 0) return priority(candidates);
  let cursor = random() * total;
  for (const candidate of stableCandidates(candidates)) {
    cursor -= Math.max(0, candidate.account.weight);
    if (cursor <= 0) return candidate;
  }
  return candidates.at(-1);
}

function leastInflight(candidates) {
  return stableCandidates(candidates).sort((a, b) => (a.runtime.inflight ?? 0) - (b.runtime.inflight ?? 0) || byIdentity(a, b))[0];
}

function lowestLatency(candidates) {
  return stableCandidates(candidates).sort((a, b) => (a.runtime.latencyEwmaMs ?? Number.POSITIVE_INFINITY) - (b.runtime.latencyEwmaMs ?? Number.POSITIVE_INFINITY) || byIdentity(a, b))[0];
}

function lowestCost(candidates) {
  return stableCandidates(candidates).sort((a, b) => (a.estimatedCostUsd ?? Number.POSITIVE_INFINITY) - (b.estimatedCostUsd ?? Number.POSITIVE_INFINITY) || byIdentity(a, b))[0];
}

function sticky(candidates, context, state) {
  const now = context.now ?? Date.now();
  state.pruneSticky(now);
  const key = context.stickyKey;
  if (!key) return priority(candidates);
  const existing = state.sticky.get(key);
  if (existing) {
    const match = candidates.find((candidate) => candidate.provider.id === existing.providerId && candidate.account.id === existing.accountId);
    if (match) return match;
  }
  const selected = priority(candidates);
  state.sticky.set(key, { providerId: selected.provider.id, accountId: selected.account.id, expiresAt: now + (context.stickyTtlMs ?? 900_000) });
  return selected;
}

export function selectCandidate(strategy, candidates, context = {}, state = new StrategyState()) {
  invariant(Array.isArray(candidates) && candidates.length > 0, 'At least one route candidate is required.');
  const selectors = {
    priority,
    'round-robin': (items) => roundRobin(items, context, state),
    'weighted-random': (items) => weightedRandom(items, context),
    'least-inflight': leastInflight,
    'lowest-latency': lowestLatency,
    'lowest-cost': lowestCost,
    sticky: (items) => sticky(items, context, state),
  };
  invariant(selectors[strategy], `Unknown routing strategy: ${strategy}`);
  return selectors[strategy](candidates);
}
