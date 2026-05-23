import net from 'node:net';
import { pathToFileURL } from 'node:url';

const DEFAULT_TEST_PORT = 28081;
const DEFAULT_MAX_ATTEMPTS = 50;

function normalizePort(value) {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid test port: ${value}`);
  }
  return port;
}

function canListen({ host, port }) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(false));
    server.once('listening', () => {
      server.close(() => resolve(true));
    });
    server.listen(port, host);
  });
}

export async function findAvailablePort({
  host = '127.0.0.1',
  requestedPort = DEFAULT_TEST_PORT,
  explicit = false,
  maxAttempts = DEFAULT_MAX_ATTEMPTS
} = {}) {
  const startPort = normalizePort(requestedPort);
  const attempts = explicit ? 1 : maxAttempts;

  for (let offset = 0; offset < attempts; offset += 1) {
    const port = startPort + offset;
    if (port > 65535) break;
    if (await canListen({ host, port })) {
      return port;
    }
  }

  if (explicit) {
    throw new Error(`TEST_PORT ${startPort} is already in use on ${host}`);
  }

  const endPort = Math.min(startPort + attempts - 1, 65535);
  throw new Error(`No available test port found from ${startPort} to ${endPort} on ${host}`);
}

async function main() {
  const [host = '127.0.0.1', portArg = String(DEFAULT_TEST_PORT), explicitArg = '0'] = process.argv.slice(2);
  const port = await findAvailablePort({
    host,
    requestedPort: portArg,
    explicit: explicitArg === '1'
  });
  console.log(port);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
