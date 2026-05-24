/**
 * Codex Claude Proxy
 * Entry point
 */

import { startServer } from './server.js';
import { logger } from './utils/logger.js';
import { getStatus, ACCOUNT_FILE } from './account-manager.js';

const PORT = Number(process.env.PORT || 8081);
const HOST = process.env.HOST || '127.0.0.1';

startServer({ port: PORT, host: HOST });

console.log(`
╔══════════════════════════════════════════════════════════════╗
	║                 Codex Claude Proxy v1.2.1                    ║
║                   (Direct API Mode)                          ║
╠══════════════════════════════════════════════════════════════╣
║  Server:   http://${HOST}:${PORT}                          ║
║  WebUI:    http://${HOST}:${PORT}                          ║
║  Health:   http://${HOST}:${PORT}/health                   ║
	║  Account:  http://${HOST}:${PORT}/account                  ║
║  Logs:     http://${HOST}:${PORT}/api/logs/stream          ║
╠══════════════════════════════════════════════════════════════╣
║  Features:                                                   ║
║    ✓ Native tool calling support                             ║
║    ✓ Real-time streaming                                     ║
	║    ✓ Single-account local mode                               ║
║    ✓ OpenAI & Anthropic API compatibility                    ║
╠══════════════════════════════════════════════════════════════╣
║  Support:                                                    ║
║    ★ Give it a star on GitHub!                               ║
║    https://github.com/surajmandalcell/codex-proxy            ║
╚══════════════════════════════════════════════════════════════╝
`);

const status = getStatus();
logger.info(`Account configured: ${status.active || 'None'}`);

if (status.total === 0) {
  logger.warn(`No account configured. Open http://${HOST}:${PORT} to add one.`);
}

// Expose config path in logs for convenience
logger.info(`Account config: ${ACCOUNT_FILE}`);
