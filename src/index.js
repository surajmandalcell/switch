/**
 * Codex Claude Proxy
 * Entry point
 */

import { startServer } from './server.js';
import { logger } from './utils/logger.js';
import { getStatus, ACCOUNTS_FILE } from './account-manager.js';

const PORT = Number(process.env.PORT || 8081);
const HOST = process.env.HOST || '127.0.0.1';

startServer({ port: PORT, host: HOST });

console.log(`
╔══════════════════════════════════════════════════════════════╗
║                 Codex Claude Proxy v1.0.6                    ║
║                   (Direct API Mode)                          ║
╠══════════════════════════════════════════════════════════════╣
║  Server:   http://${HOST}:${PORT}                          ║
║  WebUI:    http://${HOST}:${PORT}                          ║
║  Health:   http://${HOST}:${PORT}/health                   ║
║  Accounts: http://${HOST}:${PORT}/accounts                 ║
║  Logs:     http://${HOST}:${PORT}/api/logs/stream          ║
╠══════════════════════════════════════════════════════════════╣
║  Features:                                                   ║
║    ✓ Native tool calling support                             ║
║    ✓ Real-time streaming                                     ║
║    ✓ Multi-account management                                ║
║    ✓ OpenAI & Anthropic API compatibility                    ║
╠══════════════════════════════════════════════════════════════╣
║  Support:                                                    ║
║    ★ Give it a star on GitHub!                               ║
║    https://github.com/surajmandalcell/codex-claude-proxy     ║
╚══════════════════════════════════════════════════════════════╝
`);

const status = getStatus();
logger.info(`Accounts: ${status.total} total, Active: ${status.active || 'None'}`);

if (status.total === 0) {
  logger.warn(`No accounts configured. Open http://${HOST}:${PORT} to add one.`);
}

// Expose config path in logs for convenience
logger.info(`Accounts config: ${ACCOUNTS_FILE}`);
