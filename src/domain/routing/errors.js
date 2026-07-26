import { clamp } from '../shared.js';

export class UpstreamError extends Error {
  constructor(message, options = {}) {
    super(message, { cause: options.cause });
    this.name = 'UpstreamError';
    this.code = options.code ?? 'upstream_error';
    this.status = options.status ?? 502;
    this.retryable = options.retryable ?? false;
    this.cooldownMs = options.cooldownMs ?? 0;
    this.attention = options.attention ?? false;
    this.accountExhausted = options.accountExhausted ?? false;
    this.providerExhausted = options.providerExhausted ?? false;
    this.details = options.details;
  }
}

export function parseRetryAfter(value, now = Date.now()) {
  if (value === null || value === undefined || value === '') return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, Math.round(seconds * 1000));
  const date = Date.parse(String(value));
  return Number.isFinite(date) ? Math.max(0, date - now) : null;
}

export function classifyUpstreamError(input = {}, policy = {}, now = Date.now()) {
  if (input instanceof UpstreamError) return input;
  if (input?.name === 'AbortError' || input?.code === 'CLIENT_ABORTED') {
    return new UpstreamError('The client cancelled the request.', { code: 'client_cancelled', status: 499, retryable: false });
  }
  const status = Number(input.status ?? input.response?.status ?? 0);
  const body = String(input.body ?? input.message ?? 'Upstream request failed.');
  const base = Number(policy.baseCooldownMs ?? 5_000);
  const max = Number(policy.maxCooldownMs ?? 900_000);
  const failureCount = Number(input.failureCount ?? 0);
  const exponential = clamp(base * (2 ** failureCount), base, max);
  const retryAfter = parseRetryAfter(input.retryAfter ?? input.details?.retryAfter ?? input.headers?.['retry-after'] ?? input.headers?.get?.('retry-after'), now);

  if (status === 401 || status === 403) {
    return new UpstreamError(body, { code: 'authentication_error', status, retryable: policy.failoverOnAuthError ?? true, attention: true, cooldownMs: max, accountExhausted: true, cause: input });
  }
  if (status === 402 || /billing|insufficient[_ -]?quota|credit/i.test(body)) {
    return new UpstreamError(body, { code: 'quota_exhausted', status: status || 429, retryable: true, cooldownMs: Math.max(retryAfter ?? 0, max), accountExhausted: true, cause: input });
  }
  if (status === 429 || /rate.?limit|too many requests/i.test(body)) {
    return new UpstreamError(body, { code: 'rate_limited', status: 429, retryable: true, cooldownMs: clamp(retryAfter ?? exponential, base, max), cause: input });
  }
  if (status >= 500 || status === 408 || status === 409 || status === 425) {
    return new UpstreamError(body, { code: 'upstream_unavailable', status: status || 502, retryable: true, cooldownMs: exponential, cause: input });
  }
  if (!status && /timeout|timed out|network|ECONN|fetch failed/i.test(body)) {
    return new UpstreamError(body, { code: /timeout/i.test(body) ? 'timeout' : 'network_error', status: 502, retryable: true, cooldownMs: exponential, cause: input });
  }
  return new UpstreamError(body, { code: status >= 400 && status < 500 ? 'invalid_request' : 'upstream_error', status: status || 502, retryable: false, cause: input });
}
