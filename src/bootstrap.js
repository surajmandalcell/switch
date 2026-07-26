import path from 'node:path';
import { ConfigStore } from './infrastructure/config-store.js';
import { SecretStore } from './infrastructure/secret-store.js';
import { Logger } from './infrastructure/logger.js';
import { SqliteUsageRepository } from './infrastructure/usage-sqlite.js';
import { RuntimeState } from './application/runtime-state.js';
import { RoutingService } from './application/routing-service.js';
import { UsageService } from './application/usage-service.js';
import { ProxyService } from './application/proxy-service.js';
import { createProviderRegistry } from './providers/index.js';
import { createHttpServer } from './infrastructure/http-server.js';

export async function bootstrap({ userDataPath, safeStorage, Database }) {
  const configStore = new ConfigStore(path.join(userDataPath, 'config.json'));
  await configStore.load();
  const secretStore = new SecretStore({ vaultPath: path.join(userDataPath, 'secrets.json'), keyPath: path.join(userDataPath, 'secret.key'), safeStorage });
  await secretStore.load();
  const logger = new Logger();
  const usageRepository = new SqliteUsageRepository(Database, path.join(userDataPath, 'usage.sqlite'));
  const usageService = new UsageService(usageRepository, () => configStore.get());
  const runtime = new RuntimeState();
  const registry = createProviderRegistry({ trustedModulesRoot: path.join(userDataPath, 'providers') });
  const routing = new RoutingService({ registry, runtime, usage: usageRepository, hooks: {
    attemptStarted({ candidate, request, upstreamRequest }) { logger.info('Route attempt started', { providerId: candidate.provider.id, accountId: candidate.account.id, requestedModel: request.model, upstreamModel: upstreamRequest.model }); },
    attemptSucceeded({ attemptId, candidate, request, upstreamRequest, latencyMs, startedAt }) { usageRepository.insertAttempt({ id: attemptId, requestId: request.id, startedAt: new Date(startedAt).toISOString(), providerId: candidate.provider.id, accountId: candidate.account.id, upstreamModel: upstreamRequest.model, status: 'success', latencyMs, errorCode: null }); },
    attemptFailed({ attemptId, candidate, request, upstreamRequest, error, latencyMs, startedAt }) { logger.warn('Route attempt failed', { providerId: candidate.provider.id, accountId: candidate.account.id, code: error.code }); usageRepository.insertAttempt({ id: attemptId, requestId: request.id, startedAt: new Date(startedAt).toISOString(), providerId: candidate.provider.id, accountId: candidate.account.id, upstreamModel: upstreamRequest.model, status: error.code === 'client_cancelled' ? 'cancelled' : 'error', latencyMs, errorCode: error.code }); },
  } });
  const proxyService = new ProxyService({ routing, getConfig: () => configStore.get(), resolveSecret: (ref) => secretStore.get(ref), logger, usageService });
  const services = { configStore, secretStore, logger, usageRepository, usageService, runtime, registry, routing, proxyService, httpServer: null };
  services.restartHttpServer = async () => {
    if (services.httpServer) await services.httpServer.stop();
    services.httpServer = await createHttpServer({ proxyService, getConfig: () => configStore.get(), resolveSecret: (ref) => secretStore.get(ref), logger });
    await services.httpServer.start();
    return services.httpServer;
  };
  await services.restartHttpServer();
  return services;
}
