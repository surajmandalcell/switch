import { filterUsage, summarizeUsage, usageToCsv } from '../domain/usage.js';
import { newId } from '../domain/shared.js';

export class MemoryUsageRepository {
  constructor(records = []) {
    this.records = structuredClone(records);
    this.attempts = [];
  }

  insert(record) {
    const value = { ...structuredClone(record), id: record.id ?? newId('usage'), startedAt: record.startedAt ?? new Date().toISOString() };
    this.records.push(value);
    return value;
  }

  list(filters = {}, options = {}) {
    const selected = filterUsage(this.records, filters).sort((a, b) => String(b.startedAt).localeCompare(String(a.startedAt)));
    const offset = Math.max(0, Number(options.offset ?? 0));
    const limit = Math.max(0, Number(options.limit ?? selected.length));
    return selected.slice(offset, offset + limit);
  }

  summary(filters = {}) { return summarizeUsage(this.records, filters); }
  csv(filters = {}) { return usageToCsv(this.records, filters); }
  requestsSince(accountId, since) { return this.records.filter((record) => record.accountId === accountId && Date.parse(record.startedAt) >= since).length; }
  tokensSince(accountId, since) { return this.records.filter((record) => record.accountId === accountId && Date.parse(record.startedAt) >= since).reduce((sum, record) => sum + Number(record.inputTokens ?? 0) + Number(record.outputTokens ?? 0), 0); }
  costSince(accountId, since) { return this.records.filter((record) => record.accountId === accountId && Date.parse(record.startedAt) >= since).reduce((sum, record) => sum + Number(record.estimatedCostUsd ?? 0), 0); }
  insertAttempt(attempt) { const value = structuredClone(attempt); this.attempts.push(value); return value; }
  listAttempts(requestId = null) { return this.attempts.filter((attempt) => !requestId || attempt.requestId === requestId); }
  prune(days) {
    const cutoff = Date.now() - Number(days) * 86_400_000;
    const before = this.records.length;
    this.records = this.records.filter((record) => Date.parse(record.startedAt) >= cutoff);
    return before - this.records.length;
  }
}
