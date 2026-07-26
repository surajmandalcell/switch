import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { summarizeUsage, usageToCsv } from '../domain/usage.js';

export class SqliteUsageRepository {
  constructor(Database, filePath) {
    mkdirSync(path.dirname(filePath), { recursive: true });
    this.db = new Database(filePath);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('synchronous = NORMAL');
    this.migrate();
  }

  migrate() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS usage_records (
        id TEXT PRIMARY KEY,
        started_at TEXT NOT NULL,
        status TEXT NOT NULL,
        protocol TEXT,
        requested_model TEXT,
        upstream_model TEXT,
        provider_id TEXT,
        account_id TEXT,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        estimated_cost_usd REAL NOT NULL DEFAULT 0,
        latency_ms INTEGER,
        first_token_latency_ms INTEGER,
        error_code TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_usage_started_at ON usage_records(started_at DESC);
      CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage_records(provider_id, started_at DESC);
      CREATE INDEX IF NOT EXISTS idx_usage_account ON usage_records(account_id, started_at DESC);
      CREATE INDEX IF NOT EXISTS idx_usage_status ON usage_records(status, started_at DESC);
      CREATE TABLE IF NOT EXISTS route_attempts (
        id TEXT PRIMARY KEY, request_id TEXT NOT NULL, started_at TEXT NOT NULL, provider_id TEXT NOT NULL, account_id TEXT NOT NULL, upstream_model TEXT, status TEXT NOT NULL, latency_ms INTEGER, error_code TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_attempt_request ON route_attempts(request_id, started_at);
      CREATE INDEX IF NOT EXISTS idx_attempt_account ON route_attempts(account_id, started_at DESC);
    `);
    this.insertStatement = this.db.prepare(`INSERT OR REPLACE INTO usage_records
      (id, started_at, status, protocol, requested_model, upstream_model, provider_id, account_id, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd, latency_ms, first_token_latency_ms, error_code)
      VALUES (@id, @startedAt, @status, @protocol, @requestedModel, @upstreamModel, @providerId, @accountId, @inputTokens, @outputTokens, @cacheReadTokens, @cacheWriteTokens, @estimatedCostUsd, @latencyMs, @firstTokenLatencyMs, @errorCode)`);
    this.insertAttemptStatement = this.db.prepare(`INSERT OR REPLACE INTO route_attempts (id, request_id, started_at, provider_id, account_id, upstream_model, status, latency_ms, error_code) VALUES (@id, @requestId, @startedAt, @providerId, @accountId, @upstreamModel, @status, @latencyMs, @errorCode)`);
  }

  insert(record) {
    const normalized = { id: record.id, startedAt: record.startedAt ?? new Date().toISOString(), status: record.status ?? 'success', protocol: record.protocol ?? null, requestedModel: record.requestedModel ?? null, upstreamModel: record.upstreamModel ?? null, providerId: record.providerId ?? null, accountId: record.accountId ?? null, inputTokens: record.inputTokens ?? 0, outputTokens: record.outputTokens ?? 0, cacheReadTokens: record.cacheReadTokens ?? 0, cacheWriteTokens: record.cacheWriteTokens ?? 0, estimatedCostUsd: record.estimatedCostUsd ?? 0, latencyMs: record.latencyMs ?? null, firstTokenLatencyMs: record.firstTokenLatencyMs ?? null, errorCode: record.errorCode ?? null };
    this.insertStatement.run(normalized);
    return normalized;
  }

  list(filters = {}, options = {}) {
    const { where, params } = buildWhere(filters);
    const limit = Math.min(10_000, Math.max(1, Number(options.limit ?? 500)));
    const offset = Math.max(0, Number(options.offset ?? 0));
    return this.db.prepare(`SELECT id, started_at AS startedAt, status, protocol, requested_model AS requestedModel, upstream_model AS upstreamModel, provider_id AS providerId, account_id AS accountId, input_tokens AS inputTokens, output_tokens AS outputTokens, cache_read_tokens AS cacheReadTokens, cache_write_tokens AS cacheWriteTokens, estimated_cost_usd AS estimatedCostUsd, latency_ms AS latencyMs, first_token_latency_ms AS firstTokenLatencyMs, error_code AS errorCode FROM usage_records ${where} ORDER BY started_at DESC LIMIT @limit OFFSET @offset`).all({ ...params, limit, offset });
  }

  summary(filters = {}) { return summarizeUsage(this.list(filters, { limit: 10_000 }), {}); }
  csv(filters = {}) { return usageToCsv(this.list(filters, { limit: 10_000 }), {}); }
  requestsSince(accountId, since) { return this.db.prepare('SELECT COUNT(*) AS value FROM usage_records WHERE account_id = ? AND started_at >= ?').get(accountId, new Date(since).toISOString()).value; }
  tokensSince(accountId, since) { return this.db.prepare('SELECT COALESCE(SUM(input_tokens + output_tokens), 0) AS value FROM usage_records WHERE account_id = ? AND started_at >= ?').get(accountId, new Date(since).toISOString()).value; }
  costSince(accountId, since) { return this.db.prepare('SELECT COALESCE(SUM(estimated_cost_usd), 0) AS value FROM usage_records WHERE account_id = ? AND started_at >= ?').get(accountId, new Date(since).toISOString()).value; }
  insertAttempt(attempt) { const value = { latencyMs: null, errorCode: null, upstreamModel: null, ...attempt }; this.insertAttemptStatement.run(value); return value; }
  listAttempts(requestId) { return this.db.prepare('SELECT id, request_id AS requestId, started_at AS startedAt, provider_id AS providerId, account_id AS accountId, upstream_model AS upstreamModel, status, latency_ms AS latencyMs, error_code AS errorCode FROM route_attempts WHERE request_id = ? ORDER BY started_at').all(requestId); }
  prune(days) { const cutoff = new Date(Date.now() - Number(days) * 86_400_000).toISOString(); const usage = this.db.prepare('DELETE FROM usage_records WHERE started_at < ?').run(cutoff).changes; this.db.prepare('DELETE FROM route_attempts WHERE started_at < ?').run(cutoff); return usage; }
  close() { this.db.close(); }
}

function buildWhere(filters) {
  const clauses = [];
  const params = {};
  for (const [filter, column] of Object.entries({ status: 'status', protocol: 'protocol', providerId: 'provider_id', accountId: 'account_id' })) {
    if (filters[filter]) { clauses.push(`${column} = @${filter}`); params[filter] = filters[filter]; }
  }
  if (filters.from) { clauses.push('started_at >= @from'); params.from = filters.from; }
  if (filters.to) { clauses.push('started_at <= @to'); params.to = filters.to; }
  return { where: clauses.length ? `WHERE ${clauses.join(' AND ')}` : '', params };
}

export { buildWhere };
