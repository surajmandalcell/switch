import { randomUUID } from 'node:crypto';

const SECRET_PATTERN = /(authorization|api[-_]?key|token|cookie|secret|password)/i;

export function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, SECRET_PATTERN.test(key) ? '[REDACTED]' : redact(item)]));
  if (typeof value === 'string') return value.replace(/(Bearer\s+)[\w.-]+/gi, '$1[REDACTED]');
  return value;
}

export class Logger {
  constructor({ sink = console, capacity = 1000 } = {}) {
    this.sink = sink;
    this.capacity = capacity;
    this.entries = [];
    this.listeners = new Set();
  }

  write(level, message, fields = {}) {
    const entry = { id: randomUUID(), timestamp: new Date().toISOString(), level, message, fields: redact(fields) };
    this.entries.push(entry);
    if (this.entries.length > this.capacity) this.entries.splice(0, this.entries.length - this.capacity);
    this.sink[level]?.(message, entry.fields);
    for (const listener of this.listeners) listener(entry);
    return entry;
  }

  debug(message, fields) { return this.write('debug', message, fields); }
  info(message, fields) { return this.write('info', message, fields); }
  warn(message, fields) { return this.write('warn', message, fields); }
  error(message, fields) { return this.write('error', message, fields); }
  list(limit = 500) { return this.entries.slice(-limit); }
  subscribe(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
}
