import { randomUUID } from 'node:crypto';

export function invariant(condition, message, details = undefined) {
  if (!condition) {
    const error = new Error(message);
    error.name = 'InvariantError';
    if (details !== undefined) error.details = details;
    throw error;
  }
}

export function newId(prefix = 'id') {
  return `${prefix}_${randomUUID()}`;
}

export function deepClone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

export function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

export function asFiniteNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function globToRegExp(glob) {
  const escaped = String(glob ?? '*')
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*/g, '.*')
    .replace(/\?/g, '.');
  return new RegExp(`^${escaped}$`, 'i');
}

export function matchesGlob(value, glob) {
  return globToRegExp(glob).test(String(value ?? ''));
}

export function stableStringify(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(',')}}`;
}
