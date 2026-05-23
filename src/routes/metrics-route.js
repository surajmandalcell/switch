import { getUsageMetricsStore } from '../usage-metrics.js';

const VALID_RANGES = new Set(['24h', '7d', '30d', 'all']);
const VALID_STATUSES = new Set(['success', 'error']);

function parseFilters(query = {}) {
  const limit = Number(query.limit);
  const status = String(query.status || '');
  return {
    range: VALID_RANGES.has(query.range) ? query.range : '24h',
    model: typeof query.model === 'string' && query.model.trim() ? query.model.trim() : undefined,
    account: typeof query.account === 'string' && query.account.trim() ? query.account.trim() : undefined,
    status: VALID_STATUSES.has(status) || /^\d+$/.test(status) ? status : undefined,
    limit: Number.isFinite(limit) ? Math.max(1, Math.min(100, Math.trunc(limit))) : 50
  };
}

function routeStore(options = {}) {
  return options.metricsStore || getUsageMetricsStore();
}

export async function handleGetMetricsSummary(req, res, options = {}) {
  const { limit, ...filters } = parseFilters(req.query);
  const summary = await routeStore(options).getSummary(filters);
  res.json({ success: true, summary });
}

export async function handleGetMetricsRecent(req, res, options = {}) {
  const filters = parseFilters(req.query);
  const recent = await routeStore(options).getRecentEvents(filters);
  res.json({ success: true, ...recent });
}

export async function handleGetMetricsStorage(req, res, options = {}) {
  const storage = await routeStore(options).getStorageInfo();
  res.json({ success: true, storage });
}

export default {
  handleGetMetricsSummary,
  handleGetMetricsRecent,
  handleGetMetricsStorage
};
