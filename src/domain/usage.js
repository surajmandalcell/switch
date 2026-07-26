import { matchesGlob } from './shared.js';
import { normalizeUsage } from './protocol/canonical.js';

export function choosePricingRule(rules, providerId, providerType, model) {
  const matches = (rules ?? []).filter((rule) => {
    const providerMatch = rule.providerId ? rule.providerId === providerId : rule.providerType ? rule.providerType === providerType : true;
    return providerMatch && matchesGlob(model, rule.modelGlob ?? '*');
  });
  return matches.sort((a, b) => specificity(b) - specificity(a) || String(b.verifiedAt ?? '').localeCompare(String(a.verifiedAt ?? '')))[0] ?? null;
}

function specificity(rule) {
  let score = 0;
  if (rule.providerId) score += 1000;
  else if (rule.providerType) score += 500;
  const glob = rule.modelGlob ?? '*';
  score += glob.replace(/[?*]/g, '').length;
  if (!glob.includes('*') && !glob.includes('?')) score += 100;
  return score;
}

export function estimateCost(usageInput, rule) {
  const usage = normalizeUsage(usageInput);
  if (!rule) return { usd: 0, known: false, usage };
  const million = 1_000_000;
  const usd = (
    usage.inputTokens * Number(rule.inputPerMillionUsd ?? 0) +
    usage.outputTokens * Number(rule.outputPerMillionUsd ?? 0) +
    usage.cacheReadTokens * Number(rule.cacheReadPerMillionUsd ?? 0) +
    usage.cacheWriteTokens * Number(rule.cacheWritePerMillionUsd ?? 0)
  ) / million;
  return { usd, known: true, usage };
}

export function filterUsage(records, filters = {}) {
  return (records ?? []).filter((record) => {
    if (filters.status && record.status !== filters.status) return false;
    if (filters.providerId && record.providerId !== filters.providerId) return false;
    if (filters.accountId && record.accountId !== filters.accountId) return false;
    if (filters.protocol && record.protocol !== filters.protocol) return false;
    const timestamp = Date.parse(record.startedAt ?? record.createdAt ?? 0);
    if (filters.from && timestamp < Date.parse(filters.from)) return false;
    if (filters.to && timestamp > Date.parse(filters.to)) return false;
    return true;
  });
}

export function summarizeUsage(records, filters = {}) {
  const selected = filterUsage(records, filters);
  const summary = selected.reduce((summary, record) => {
    summary.requests += 1;
    summary.successes += record.status === 'success' ? 1 : 0;
    summary.failures += record.status === 'error' ? 1 : 0;
    summary.cancelled += record.status === 'cancelled' ? 1 : 0;
    summary.inputTokens += Number(record.inputTokens ?? 0);
    summary.outputTokens += Number(record.outputTokens ?? 0);
    summary.cacheReadTokens += Number(record.cacheReadTokens ?? 0);
    summary.cacheWriteTokens += Number(record.cacheWriteTokens ?? 0);
    summary.estimatedCostUsd += Number(record.estimatedCostUsd ?? 0);
    summary.totalLatencyMs += Number(record.latencyMs ?? 0);
    return summary;
  }, { requests: 0, successes: 0, failures: 0, cancelled: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, estimatedCostUsd: 0, totalLatencyMs: 0 });
  summary.estimatedCostUsd = Number(summary.estimatedCostUsd.toFixed(12));
  return summary;
}

export function usageToCsv(records, filters = {}) {
  const columns = ['id','startedAt','status','protocol','requestedModel','upstreamModel','providerId','accountId','inputTokens','outputTokens','cacheReadTokens','cacheWriteTokens','estimatedCostUsd','latencyMs','firstTokenLatencyMs'];
  const escape = (value) => `"${String(value ?? '').replaceAll('"', '""')}"`;
  return [columns.join(','), ...filterUsage(records, filters).map((record) => columns.map((column) => escape(record[column])).join(','))].join('\n');
}
