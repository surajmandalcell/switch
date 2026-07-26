import { app, BrowserWindow, ipcMain, nativeTheme, safeStorage, shell } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Database from 'better-sqlite3';
import { bootstrap } from '../../src/bootstrap.js';
import { publicConfig, replaceProviderOverrides } from '../../src/domain/config.js';
import { PROVIDER_PRESETS } from '../../src/providers/index.js';
import { SettingsService } from '../../src/application/settings-service.js';
import { ProviderConfigurationService } from '../../src/application/provider-configuration-service.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
let mainWindow;
let services;
let settingsService;
let providerConfigurationService;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1240,
    height: 800,
    minWidth: 960,
    minHeight: 640,
    frame: false,
    transparent: process.platform === 'darwin',
    backgroundColor: '#0c0d10',
    show: false,
    titleBarStyle: 'hidden',
    trafficLightPosition: { x: 14, y: 14 },
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.cjs'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      webSecurity: true,
    },
  });
  if (process.platform === 'darwin') mainWindow.setVibrancy('under-window');
  if (process.platform === 'win32') mainWindow.setBackgroundMaterial?.('acrylic');
  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) mainWindow.loadURL(devUrl);
  else mainWindow.loadFile(path.join(__dirname, '../../dist/renderer/index.html'));
  mainWindow.once('ready-to-show', () => mainWindow.show());
  mainWindow.webContents.setWindowOpenHandler(({ url }) => { if (/^https:\/\//.test(url)) shell.openExternal(url); return { action: 'deny' }; });
}

function validateSender(event) {
  const url = event.senderFrame?.url ?? '';
  if (process.env.VITE_DEV_SERVER_URL && url.startsWith(process.env.VITE_DEV_SERVER_URL)) return;
  if (url.startsWith('file://')) return;
  throw new Error('Rejected IPC from an untrusted renderer.');
}

function handle(channel, listener) {
  ipcMain.handle(channel, async (event, ...args) => { validateSender(event); return listener(...args); });
}

function snapshot() {
  const config = services.configStore.get();
  return {
    config: publicConfig(config),
    runtime: Object.fromEntries(services.runtime.snapshot()),
    usageSummary: services.usageService.summary({}),
    recentUsage: services.usageService.list({}, { limit: 100 }),
    logs: services.logger.list(300),
    providerPresets: PROVIDER_PRESETS,
    platform: process.platform,
    theme: nativeTheme.shouldUseDarkColors ? 'dark' : 'light',
    serverUrl: `http://${config.server.host}:${config.server.port}`,
  };
}

function exposeConfig(config) { return publicConfig(config); }

function registerIpc() {
  handle('app:snapshot', () => snapshot());
  handle('config:replace', (config) => settingsService.replace(config));
  handle('config:update', (patch) => settingsService.updatePatch(patch));
  handle('server:set-api-key', (value) => settingsService.setApiKey(value));
  handle('server:clear-api-key', () => settingsService.clearApiKey());
  handle('providers:add', (input) => providerConfigurationService.addProvider(input));
  handle('providers:update', (providerId, patch) => providerConfigurationService.updateProvider(providerId, patch));
  handle('providers:remove', (providerId) => providerConfigurationService.removeProvider(providerId));
  handle('accounts:add', (providerId, input) => providerConfigurationService.addAccount(providerId, input));
  handle('accounts:update', (providerId, accountId, patch) => providerConfigurationService.updateAccount(providerId, accountId, patch));
  handle('accounts:remove', (providerId, accountId) => providerConfigurationService.removeAccount(providerId, accountId));
  handle('routing:reset-overrides', async (strategy) => exposeConfig(await services.configStore.update((config) => replaceProviderOverrides(config, strategy))));
  handle('usage:list', (filters, options) => services.usageService.list(filters, options));
  handle('usage:summary', (filters) => services.usageService.summary(filters));
  handle('usage:csv', (filters) => services.usageService.csv(filters));
  handle('usage:attempts', (requestId) => services.usageService.attempts(requestId));
  handle('logs:list', (limit) => services.logger.list(limit));
  handle('window:minimize', () => mainWindow.minimize());
  handle('window:maximize', () => mainWindow.isMaximized() ? mainWindow.unmaximize() : mainWindow.maximize());
  handle('window:close', () => mainWindow.close());
  handle('shell:open', (url) => /^https:\/\//.test(url) ? shell.openExternal(url) : false);
}

app.whenReady().then(async () => {
  services = await bootstrap({ userDataPath: app.getPath('userData'), safeStorage, Database });
  providerConfigurationService = new ProviderConfigurationService({ configStore: services.configStore, secretStore: services.secretStore, runtime: services.runtime });
  settingsService = new SettingsService({
    configStore: services.configStore,
    secretStore: services.secretStore,
    restartServer: () => services.restartHttpServer(),
    setLoginItem: (openAtLogin) => app.setLoginItemSettings({ openAtLogin: Boolean(openAtLogin), path: process.execPath }),
  });
  app.setLoginItemSettings({ openAtLogin: Boolean(services.configStore.get().server.startOnLogin), path: process.execPath });
  registerIpc();
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('before-quit', async (event) => {
  if (!services) return;
  event.preventDefault();
  const current = services;
  services = null;
  await current.httpServer.stop().catch(() => {});
  current.usageRepository.close();
  app.quit();
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });

export { validateSender };
