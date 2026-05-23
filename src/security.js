const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);
const CONTROL_PATH_PREFIXES = [
  '/account',
  '/settings',
  '/claude/config',
  '/api/logs',
  '/api/metrics'
];
const SAFE_FETCH_SITES = new Set(['same-origin', 'same-site', 'none']);
const SENSITIVE_KEY_RE = /(api[_-]?key|auth[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|secret|password)/i;

export function isLoopbackAddress(address) {
  if (!address || typeof address !== 'string') return false;
  const normalized = address.replace(/^\[|\]$/g, '');
  return normalized === '::1' ||
    normalized === '127.0.0.1' ||
    normalized.startsWith('127.') ||
    normalized.startsWith('::ffff:127.');
}

export function isLoopbackHostname(hostname) {
  if (!hostname || typeof hostname !== 'string') return false;
  return LOOPBACK_HOSTS.has(hostname.toLowerCase());
}

export function isControlPath(path = '') {
  return CONTROL_PATH_PREFIXES.some(prefix => path === prefix || path.startsWith(`${prefix}/`));
}

export function isStateChangingMethod(method = 'GET') {
  return !['GET', 'HEAD', 'OPTIONS'].includes(method.toUpperCase());
}

export function evaluateRequestAccess(req, options = {}) {
  const path = req.path || req.url || '';
  const method = req.method || 'GET';

  if (!isControlPath(path)) {
    return { allowed: true };
  }

  const headers = req.headers || {};
  if (isStateChangingMethod(method)) {
    const fetchSite = String(headers['sec-fetch-site'] || '').toLowerCase();
    if (fetchSite && !SAFE_FETCH_SITES.has(fetchSite)) {
      return { allowed: false, status: 403, reason: 'Cross-site control-plane request blocked' };
    }

    const origin = headers.origin;
    if (origin && Array.isArray(options.allowedOrigins) && !options.allowedOrigins.includes(origin)) {
      return { allowed: false, status: 403, reason: 'Origin is not allowed for control-plane request' };
    }
  }

  const remoteAddress = req.socket?.remoteAddress || req.ip;
  if (isLoopbackAddress(remoteAddress)) {
    return { allowed: true };
  }

  const adminToken = options.adminToken || process.env.CODEX_CLAUDE_PROXY_ADMIN_TOKEN;
  const suppliedToken = headers['x-codex-proxy-admin-token'];
  if (adminToken && suppliedToken === adminToken) {
    return { allowed: true };
  }

  return { allowed: false, status: 403, reason: 'Remote control-plane request blocked' };
}

export function securityMiddleware(options = {}) {
  return (req, res, next) => {
    const result = evaluateRequestAccess(req, options);
    if (result.allowed) {
      next();
      return;
    }
    res.status(result.status || 403).json({ success: false, error: result.reason || 'Forbidden' });
  };
}

export function redactSensitiveConfig(value) {
  if (Array.isArray(value)) {
    return value.map(redactSensitiveConfig);
  }

  if (!value || typeof value !== 'object') {
    return value;
  }

  const result = {};
  for (const [key, nestedValue] of Object.entries(value)) {
    result[key] = SENSITIVE_KEY_RE.test(key) ? '[redacted]' : redactSensitiveConfig(nestedValue);
  }
  return result;
}

export function isAllowedApiEndpoint(apiUrl, options = {}) {
  let parsed;
  try {
    parsed = new URL(apiUrl);
  } catch {
    return false;
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return false;
  }

  if (isLoopbackHostname(parsed.hostname)) {
    return true;
  }

  const allowExternal = options.allowExternal ?? process.env.CODEX_CLAUDE_PROXY_ALLOW_EXTERNAL_ENDPOINTS === 'true';
  return allowExternal === true;
}

export function buildAllowedOrigins(port, host = '127.0.0.1') {
  const origins = new Set([
    `http://localhost:${port}`,
    `http://127.0.0.1:${port}`
  ]);

  if (Number(port) === 80) {
    origins.add('http://localhost');
    origins.add('http://127.0.0.1');
  }

  if (host && !['0.0.0.0', '::'].includes(host)) {
    origins.add(`http://${host}:${port}`);
  }

  return [...origins];
}

export default {
  buildAllowedOrigins,
  evaluateRequestAccess,
  isAllowedApiEndpoint,
  isControlPath,
  isLoopbackAddress,
  isLoopbackHostname,
  redactSensitiveConfig,
  securityMiddleware
};
