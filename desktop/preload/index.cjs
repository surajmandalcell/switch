const { contextBridge, ipcRenderer } = require('electron');

const invoke = (channel, ...args) => ipcRenderer.invoke(channel, ...args);

contextBridge.exposeInMainWorld('spi', Object.freeze({
  snapshot: () => invoke('app:snapshot'),
  updateConfig: (patch) => invoke('config:update', patch),
  replaceConfig: (config) => invoke('config:replace', config),
  setApiKey: (value) => invoke('server:set-api-key', value),
  clearApiKey: () => invoke('server:clear-api-key'),
  addProvider: (input) => invoke('providers:add', input),
  updateProvider: (providerId, patch) => invoke('providers:update', providerId, patch),
  removeProvider: (providerId) => invoke('providers:remove', providerId),
  addAccount: (providerId, input) => invoke('accounts:add', providerId, input),
  updateAccount: (providerId, accountId, patch) => invoke('accounts:update', providerId, accountId, patch),
  removeAccount: (providerId, accountId) => invoke('accounts:remove', providerId, accountId),
  resetRoutingOverrides: (strategy) => invoke('routing:reset-overrides', strategy),
  listUsage: (filters, options) => invoke('usage:list', filters, options),
  summarizeUsage: (filters) => invoke('usage:summary', filters),
  exportUsageCsv: (filters) => invoke('usage:csv', filters),
  listAttempts: (requestId) => invoke('usage:attempts', requestId),
  listLogs: (limit) => invoke('logs:list', limit),
  minimize: () => invoke('window:minimize'),
  maximize: () => invoke('window:maximize'),
  close: () => invoke('window:close'),
  openExternal: (url) => invoke('shell:open', url),
}));
