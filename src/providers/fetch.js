import { UpstreamError } from '../domain/routing/errors.js';

export async function fetchWithTimeout(url, options = {}, timeoutMs = 120_000) {
  const timeoutController = new AbortController();
  const timer = setTimeout(() => timeoutController.abort(new DOMException('Upstream timeout', 'TimeoutError')), timeoutMs);
  const signal = options.signal ? AbortSignal.any([options.signal, timeoutController.signal]) : timeoutController.signal;
  try {
    const response = await fetch(url, { ...options, signal });
    if (!response.ok) {
      const body = await response.text().catch(() => '');
      throw new UpstreamError(body || `Upstream returned ${response.status}.`, { status: response.status, retryable: response.status === 429 || response.status >= 500, details: { retryAfter: response.headers.get('retry-after') } });
    }
    return response;
  } catch (error) {
    if (options.signal?.aborted) { const error = new Error('Client cancelled'); error.name = 'AbortError'; error.code = 'CLIENT_ABORTED'; throw error; }
    if (timeoutController.signal.aborted) throw Object.assign(new Error('Upstream request timed out.'), { code: 'ETIMEDOUT' });
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export function authHeaders(secret, provider) {
  const headers = { 'content-type': 'application/json', ...provider.headers };
  if (secret) headers.authorization = `Bearer ${secret}`;
  return headers;
}
