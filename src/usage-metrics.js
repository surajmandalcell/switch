import { existsSync, mkdirSync, renameSync, rmSync, statSync } from 'fs';
import { dirname, join } from 'path';

import { DuckDBInstance } from '@duckdb/node-api';

import { CONFIG_DIR } from './account-manager.js';
import { logger } from './utils/logger.js';

const DEFAULT_METRICS_DB = join(CONFIG_DIR, 'metrics.duckdb');
const DEFAULT_METRICS_MAX_BYTES = 50 * 1024 * 1024;
const RANGE_MS = {
  '24h': 24 * 60 * 60 * 1000,
  '7d': 7 * 24 * 60 * 60 * 1000,
  '30d': 30 * 24 * 60 * 60 * 1000
};

let defaultStore = null;

function envMaxBytes() {
  const raw = Number(process.env.CODEX_CLAUDE_PROXY_METRICS_MAX_BYTES);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_METRICS_MAX_BYTES;
}

function toInt(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.trunc(number) : 0;
}

function nowIso() {
  return new Date().toISOString();
}

function sqlString(value) {
  return String(value ?? '').replaceAll("'", "''");
}

function sqlLiteral(value) {
  return value == null ? 'NULL' : `'${sqlString(value)}'`;
}

function normalizeUsage(usage = {}) {
  return {
    input_tokens: toInt(usage.input_tokens ?? usage.prompt_tokens),
    output_tokens: toInt(usage.output_tokens ?? usage.completion_tokens),
    cache_read_input_tokens: toInt(usage.cache_read_input_tokens)
  };
}

function normalizeStatus(status) {
  const numeric = Number(status);
  return Number.isInteger(numeric) && numeric > 0 ? numeric : 0;
}

function normalizeEvent(event = {}) {
  const usage = normalizeUsage(event.usage || event);
  const inputTokens = toInt(event.inputTokens ?? usage.input_tokens);
  const outputTokens = toInt(event.outputTokens ?? usage.output_tokens);
  const cacheReadInputTokens = toInt(event.cacheReadInputTokens ?? usage.cache_read_input_tokens);
  const startedAt = event.startedAt || event.started_at || nowIso();
  const completedAt = event.completedAt || event.completed_at || nowIso();

  return {
    startedAt,
    completedAt,
    endpoint: event.endpoint || 'unknown',
    requestedModel: event.requestedModel || event.requested_model || null,
    upstreamModel: event.upstreamModel || event.upstream_model || event.requestedModel || null,
    accountLabel: event.accountLabel || event.account_label || null,
    provider: event.provider || 'openai',
    stream: event.stream === true,
    messageCount: toInt(event.messageCount ?? event.message_count),
    toolCount: toInt(event.toolCount ?? event.tool_count),
    inputTokens,
    outputTokens,
    cacheReadInputTokens,
    totalTokens: toInt(event.totalTokens ?? event.total_tokens ?? inputTokens + outputTokens),
    status: normalizeStatus(event.status),
    errorType: event.errorType || event.error_type || null,
    durationMs: toInt(event.durationMs ?? event.duration_ms)
  };
}

function statusWhere(status) {
  if (status === 'success') return 'status BETWEEN 200 AND 399';
  if (status === 'error') return 'status >= 400';
  const numeric = Number(status);
  if (Number.isInteger(numeric) && numeric > 0) return `status = ${numeric}`;
  return null;
}

function buildWhere(filters = {}) {
  const clauses = [];
  const range = filters.range || '24h';
  if (RANGE_MS[range]) {
    clauses.push(`started_at >= TIMESTAMP '${new Date(Date.now() - RANGE_MS[range]).toISOString()}'`);
  }
  if (filters.model) {
    clauses.push(`upstream_model = '${sqlString(filters.model)}'`);
  }
  if (filters.account) {
    clauses.push(`account_label = '${sqlString(filters.account)}'`);
  }
  const statusClause = statusWhere(filters.status);
  if (statusClause) clauses.push(statusClause);
  return clauses.length ? `WHERE ${clauses.join(' AND ')}` : '';
}

function rowObjects(reader) {
  return reader.getRowObjectsJson().map((row) => {
    const normalized = {};
    for (const [key, value] of Object.entries(row)) {
      const maybeNumber = Number(value);
      normalized[key] = typeof value === 'string' && value.trim() !== '' && Number.isFinite(maybeNumber)
        ? maybeNumber
        : value;
    }
    return normalized;
  });
}

function fileSize(path) {
  if (!existsSync(path)) return 0;
  return statSync(path).size;
}

async function copyDatabase(sourcePath, targetPath) {
  const instance = await DuckDBInstance.create(':memory:');
  const connection = await instance.connect();
  try {
    await connection.run(`ATTACH '${sqlString(sourcePath)}' AS source_db (READ_ONLY)`);
    await connection.run(`ATTACH '${sqlString(targetPath)}' AS target_db`);
    await connection.run('COPY FROM DATABASE source_db TO target_db');
  } finally {
    connection.closeSync();
    instance.closeSync();
  }
}

class UsageMetricsStore {
  constructor(options = {}) {
    this.dbPath = options.dbPath || process.env.CODEX_CLAUDE_PROXY_METRICS_DB || DEFAULT_METRICS_DB;
    this.maxBytes = Number(options.maxBytes || envMaxBytes());
    this.instance = null;
    this.connection = null;
    this.ready = null;
    this.queue = Promise.resolve();
  }

  async close() {
    await this.ready?.catch(() => {});
    this.connection?.closeSync();
    this.instance?.closeSync();
    this.connection = null;
    this.instance = null;
    this.ready = null;
  }

  async recordUsageEvent(event) {
    return this.enqueue(async () => {
      const normalized = normalizeEvent(event);
      await this.ensureReady();
      await this.connection.run(`
        INSERT INTO usage_events (
          started_at, completed_at, endpoint, requested_model, upstream_model,
          account_label, provider, stream, message_count, tool_count,
          input_tokens, output_tokens, cache_read_input_tokens, total_tokens,
          status, error_type, duration_ms
        ) VALUES (
          TIMESTAMP ${sqlLiteral(normalized.startedAt)},
          TIMESTAMP ${sqlLiteral(normalized.completedAt)},
          ${sqlLiteral(normalized.endpoint)},
          ${sqlLiteral(normalized.requestedModel)},
          ${sqlLiteral(normalized.upstreamModel)},
          ${sqlLiteral(normalized.accountLabel)},
          ${sqlLiteral(normalized.provider)},
          ${normalized.stream ? 'true' : 'false'},
          ${normalized.messageCount},
          ${normalized.toolCount},
          ${normalized.inputTokens},
          ${normalized.outputTokens},
          ${normalized.cacheReadInputTokens},
          ${normalized.totalTokens},
          ${normalized.status},
          ${sqlLiteral(normalized.errorType)},
          ${normalized.durationMs}
        )
      `);
      await this.compactIfNeeded();
    });
  }

  async getSummary(filters = {}) {
    await this.ensureReady();
    const where = buildWhere(filters);
    const totals = rowObjects(await this.connection.runAndReadAll(`
      SELECT
        count(*)::INTEGER AS requestCount,
        sum(CASE WHEN status BETWEEN 200 AND 399 THEN 1 ELSE 0 END)::INTEGER AS successCount,
        sum(CASE WHEN status >= 400 THEN 1 ELSE 0 END)::INTEGER AS errorCount,
        coalesce(sum(input_tokens), 0)::INTEGER AS inputTokens,
        coalesce(sum(output_tokens), 0)::INTEGER AS outputTokens,
        coalesce(sum(cache_read_input_tokens), 0)::INTEGER AS cacheReadInputTokens,
        coalesce(sum(total_tokens), 0)::INTEGER AS totalTokens,
        coalesce(round(avg(duration_ms)), 0)::INTEGER AS averageDurationMs
      FROM usage_events
      ${where}
    `))[0] || this.emptyTotals();

    const byModel = rowObjects(await this.connection.runAndReadAll(`
      SELECT
        coalesce(upstream_model, 'unknown') AS model,
        count(*)::INTEGER AS requestCount,
        coalesce(sum(total_tokens), 0)::INTEGER AS totalTokens,
        coalesce(sum(input_tokens), 0)::INTEGER AS inputTokens,
        coalesce(sum(output_tokens), 0)::INTEGER AS outputTokens
      FROM usage_events
      ${where}
      GROUP BY coalesce(upstream_model, 'unknown')
      ORDER BY totalTokens DESC, requestCount DESC
      LIMIT 12
    `));

    const byAccount = rowObjects(await this.connection.runAndReadAll(`
      SELECT
        coalesce(account_label, 'unknown') AS accountLabel,
        count(*)::INTEGER AS requestCount,
        coalesce(sum(total_tokens), 0)::INTEGER AS totalTokens
      FROM usage_events
      ${where}
      GROUP BY coalesce(account_label, 'unknown')
      ORDER BY totalTokens DESC, requestCount DESC
      LIMIT 12
    `));

    const timeline = rowObjects(await this.connection.runAndReadAll(`
      SELECT
        strftime(started_at, '%Y-%m-%d %H:00') AS bucket,
        count(*)::INTEGER AS requestCount,
        coalesce(sum(total_tokens), 0)::INTEGER AS totalTokens
      FROM usage_events
      ${where}
      GROUP BY bucket
      ORDER BY bucket ASC
      LIMIT 72
    `));

    return {
      range: filters.range || '24h',
      totals: { ...this.emptyTotals(), ...totals },
      byModel,
      byAccount,
      timeline
    };
  }

  async getRecentEvents(filters = {}) {
    await this.ensureReady();
    const where = buildWhere(filters);
    const limit = Math.max(1, Math.min(100, toInt(filters.limit) || 50));
    const events = rowObjects(await this.connection.runAndReadAll(`
      SELECT
        rowid::INTEGER AS id,
        strftime(started_at, '%Y-%m-%dT%H:%M:%S.000Z') AS startedAt,
        strftime(completed_at, '%Y-%m-%dT%H:%M:%S.000Z') AS completedAt,
        endpoint,
        requested_model AS requestedModel,
        upstream_model AS upstreamModel,
        account_label AS accountLabel,
        provider,
        stream,
        message_count AS messageCount,
        tool_count AS toolCount,
        input_tokens AS inputTokens,
        output_tokens AS outputTokens,
        cache_read_input_tokens AS cacheReadInputTokens,
        total_tokens AS totalTokens,
        status,
        error_type AS errorType,
        duration_ms AS durationMs
      FROM usage_events
      ${where}
      ORDER BY started_at DESC, rowid DESC
      LIMIT ${limit}
    `));
    return { range: filters.range || '24h', events };
  }

  async getStorageInfo() {
    await this.ensureReady();
    const metadata = await this.getMetadata();
    const sizeBytes = fileSize(this.dbPath);
    return {
      dbPath: this.dbPath,
      sizeBytes,
      maxBytes: this.maxBytes,
      overLimit: sizeBytes > this.maxBytes,
      lastCompactionAttemptAt: metadata.last_compaction_attempt_at || null,
      lastCompactionBeforeBytes: toInt(metadata.last_compaction_before_bytes),
      lastCompactionAfterBytes: toInt(metadata.last_compaction_after_bytes),
      lastCompactionError: metadata.last_compaction_error || null
    };
  }

  async compactIfNeeded() {
    await this.ensureReady();
    const beforeBytes = fileSize(this.dbPath);
    if (beforeBytes <= this.maxBytes) return;

    const attemptedAt = nowIso();
    let afterBytes = beforeBytes;
    let error = null;

    try {
      await this.connection.run('CHECKPOINT');
      afterBytes = fileSize(this.dbPath);

      if (afterBytes > this.maxBytes) {
        await this.copyCompact();
        afterBytes = fileSize(this.dbPath);
      }
    } catch (err) {
      error = err.message;
      logger.warn(`[Metrics] Compaction failed: ${err.message}`);
    }

    await this.setMetadata({
      last_compaction_attempt_at: attemptedAt,
      last_compaction_before_bytes: String(beforeBytes),
      last_compaction_after_bytes: String(afterBytes),
      last_compaction_error: error || ''
    });
  }

  async copyCompact() {
    const compactPath = `${this.dbPath}.compact-${process.pid}-${Date.now()}`;
    const backupPath = `${this.dbPath}.bak-${process.pid}-${Date.now()}`;

    this.connection?.closeSync();
    this.instance?.closeSync();
    this.connection = null;
    this.instance = null;
    this.ready = null;

    try {
      rmSync(compactPath, { force: true });
      await copyDatabase(this.dbPath, compactPath);
      renameSync(this.dbPath, backupPath);
      renameSync(compactPath, this.dbPath);
      rmSync(backupPath, { force: true });
    } finally {
      rmSync(compactPath, { force: true });
      await this.ensureReady();
    }
  }

  async getMetadata() {
    const rows = rowObjects(await this.connection.runAndReadAll('SELECT key, value FROM usage_metadata'));
    return Object.fromEntries(rows.map((row) => [row.key, row.value]));
  }

  async setMetadata(values) {
    for (const [key, value] of Object.entries(values)) {
      await this.connection.run(`
        INSERT OR REPLACE INTO usage_metadata (key, value)
        VALUES (${sqlLiteral(key)}, ${sqlLiteral(value)})
      `);
    }
  }

  emptyTotals() {
    return {
      requestCount: 0,
      successCount: 0,
      errorCount: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadInputTokens: 0,
      totalTokens: 0,
      averageDurationMs: 0
    };
  }

  async ensureReady() {
    if (!this.ready) {
      this.ready = this.init();
    }
    await this.ready;
  }

  async init() {
    mkdirSync(dirname(this.dbPath), { recursive: true, mode: 0o700 });
    this.instance = await DuckDBInstance.fromCache(this.dbPath);
    this.connection = await this.instance.connect();
    await this.connection.run(`
      CREATE TABLE IF NOT EXISTS usage_events (
        started_at TIMESTAMP NOT NULL,
        completed_at TIMESTAMP NOT NULL,
        endpoint VARCHAR NOT NULL,
        requested_model VARCHAR,
        upstream_model VARCHAR,
        account_label VARCHAR,
        provider VARCHAR NOT NULL,
        stream BOOLEAN NOT NULL,
        message_count INTEGER NOT NULL,
        tool_count INTEGER NOT NULL,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cache_read_input_tokens INTEGER NOT NULL,
        total_tokens INTEGER NOT NULL,
        status INTEGER NOT NULL,
        error_type VARCHAR,
        duration_ms INTEGER NOT NULL
      )
    `);
    await this.connection.run(`
      CREATE TABLE IF NOT EXISTS usage_metadata (
        key VARCHAR PRIMARY KEY,
        value VARCHAR NOT NULL
      )
    `);
    await this.setMetadata({ schema_version: '1' });
  }

  enqueue(task) {
    const run = this.queue.then(task, task);
    this.queue = run.catch(() => {});
    return run;
  }
}

export function createUsageMetricsStore(options = {}) {
  return new UsageMetricsStore(options);
}

export function getUsageMetricsStore() {
  if (!defaultStore) {
    defaultStore = createUsageMetricsStore();
  }
  return defaultStore;
}

export async function recordUsageEventSafe(event, store = getUsageMetricsStore()) {
  try {
    await store.recordUsageEvent(event);
  } catch (error) {
    logger.warn(`[Metrics] Failed to record usage: ${error.message}`);
  }
}

export async function* tapUsageEventStream(eventStream, onUsage) {
  let finalUsage = null;
  for await (const event of eventStream) {
    if (event?.data?.type === 'message_delta' && event.data.usage) {
      finalUsage = normalizeUsage(event.data.usage);
    }
    yield event;
  }
  await onUsage?.(finalUsage || normalizeUsage());
}

export {
  DEFAULT_METRICS_DB,
  DEFAULT_METRICS_MAX_BYTES,
  normalizeUsage
};

export default {
  createUsageMetricsStore,
  getUsageMetricsStore,
  recordUsageEventSafe,
  tapUsageEventStream
};
