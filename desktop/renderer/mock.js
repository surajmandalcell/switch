const demo = {
  config: {
    server: { host: '127.0.0.1', port: 8081, corsOrigins: [], requestTimeoutMs: 120000, startOnLogin: false, hasApiKey: true },
    routing: { strategy: 'least-inflight', maxAttempts: 4, stickyTtlMs: 900000, baseCooldownMs: 5000, maxCooldownMs: 900000, failoverOnAuthError: true },
    appearance: { theme: 'dark', compact: true, reduceMotion: false },
    retentionDays: 90,
    providers: [
      { id: 'openai', name: 'OpenAI', type: 'openai', enabled: true, baseUrl: 'https://api.openai.com/v1', modelGlobs: ['gpt-*'], strategyOverride: null, maxAttempts: null, accounts: [{ id: 'oa-pro', label: 'Personal Pro', enabled: true, hasSecret: true, priority: 10, weight: 2, limits: {} }, { id: 'oa-team', label: 'Team', enabled: true, hasSecret: true, priority: 20, weight: 1, limits: {} }] },
      { id: 'anthropic', name: 'Anthropic', type: 'anthropic', enabled: true, baseUrl: 'https://api.anthropic.com/v1', modelGlobs: ['claude-*'], strategyOverride: 'priority', maxAttempts: null, accounts: [{ id: 'an-pro', label: 'Claude Pro', enabled: true, hasSecret: true, priority: 10, weight: 1, limits: {} }] },
      { id: 'gemini', name: 'Google Gemini', type: 'gemini', enabled: true, baseUrl: 'https://generativelanguage.googleapis.com/v1beta', modelGlobs: ['gemini-*'], strategyOverride: null, maxAttempts: null, accounts: [{ id: 'gm-main', label: 'Workspace', enabled: true, hasSecret: true, priority: 10, weight: 1, limits: {} }] },
      { id: 'grok', name: 'xAI Grok', type: 'grok', enabled: true, baseUrl: 'https://api.x.ai/v1', modelGlobs: ['grok-*'], strategyOverride: 'weighted-random', maxAttempts: null, accounts: [{ id: 'xai-main', label: 'xAI', enabled: true, hasSecret: true, priority: 10, weight: 1, limits: {} }] },
    ],
  },
  runtime: { 'oa-pro': { inflight: 1, latencyEwmaMs: 812 }, 'oa-team': { inflight: 0, latencyEwmaMs: 1010 }, 'an-pro': { inflight: 0, latencyEwmaMs: 924 }, 'gm-main': { inflight: 0, latencyEwmaMs: 735 }, 'xai-main': { inflight: 0, latencyEwmaMs: 866 } },
  usageSummary: { requests: 1482, successes: 1451, failures: 24, cancelled: 7, estimatedCostUsd: 19.4231 },
  recentUsage: Array.from({ length: 18 }, (_, index) => ({ id: `demo-${index}`, startedAt: new Date(Date.now() - index * 720000).toISOString(), status: index === 5 ? 'error' : index === 9 ? 'cancelled' : 'success', protocol: index % 3 === 0 ? 'anthropic' : index % 3 === 1 ? 'openai-responses' : 'openai-chat', requestedModel: index % 4 === 0 ? 'claude-sonnet-4' : index % 4 === 1 ? 'gpt-5' : index % 4 === 2 ? 'gemini-2.5-pro' : 'grok-4', providerId: ['anthropic','openai','gemini','grok'][index % 4], accountId: ['an-pro','oa-pro','gm-main','xai-main'][index % 4], inputTokens: 850 + index * 31, outputTokens: 210 + index * 9, cacheReadTokens: index % 2 ? 320 : 0, cacheWriteTokens: 0, estimatedCostUsd: 0.012 + index * 0.003, latencyMs: 680 + index * 42 })),
  logs: Array.from({ length: 12 }, (_, index) => ({ id: `log-${index}`, timestamp: new Date(Date.now() - index * 90000).toISOString(), level: index === 3 ? 'warn' : index === 8 ? 'error' : 'info', message: index === 3 ? 'Account entered temporary cooldown' : index === 8 ? 'Route attempt failed' : 'Request completed', fields: { providerId: ['openai','anthropic','gemini','grok'][index % 4], latencyMs: 720 + index * 20 } })),
  providerPresets: [
    { type: 'openai', name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', modelGlobs: ['gpt-*'] },
    { type: 'anthropic', name: 'Anthropic', baseUrl: 'https://api.anthropic.com/v1', modelGlobs: ['claude-*'] },
    { type: 'gemini', name: 'Google Gemini', baseUrl: 'https://generativelanguage.googleapis.com/v1beta', modelGlobs: ['gemini-*'] },
    { type: 'grok', name: 'xAI Grok', baseUrl: 'https://api.x.ai/v1', modelGlobs: ['grok-*'] },
    { type: 'openai-compatible', name: 'OpenAI-compatible', baseUrl: '', modelGlobs: ['*'] },
    { type: 'anthropic-compatible', name: 'Anthropic-compatible', baseUrl: '', modelGlobs: ['*'] },
    { type: 'command', name: 'CLI / command', baseUrl: '', modelGlobs: ['*'] },
  ],
  platform: 'darwin', theme: 'dark', serverUrl: 'http://127.0.0.1:8081',
};

export function ensureMockBridge() {
  if (window.spi) return;
  const respond = async () => structuredClone(demo);
  window.spi = Object.freeze({
    snapshot: respond,
    updateConfig: async () => demo.config,
    setApiKey: async () => demo.config,
    clearApiKey: async () => demo.config,
    replaceConfig: async () => demo.config,
    addProvider: async () => demo.config,
    updateProvider: async () => demo.config,
    removeProvider: async () => demo.config,
    addAccount: async () => demo.config,
    updateAccount: async () => demo.config,
    removeAccount: async () => demo.config,
    resetRoutingOverrides: async () => demo.config,
    listUsage: async () => demo.recentUsage,
    summarizeUsage: async () => demo.usageSummary,
    exportUsageCsv: async () => 'id,status\ndemo,success\n',
    listAttempts: async (requestId) => [{ id: `${requestId}-attempt`, requestId, startedAt: new Date().toISOString(), providerId: 'openai', accountId: 'oa-pro', upstreamModel: 'gpt-5', status: 'success', latencyMs: 720, errorCode: null }],
    listLogs: async () => demo.logs,
    minimize: async () => {}, maximize: async () => {}, close: async () => {}, openExternal: async () => {},
  });
}
