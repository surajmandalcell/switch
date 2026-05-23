import net from 'node:net';
import { execFile } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const DEFAULT_TEST_PORT = 28081;
const DEFAULT_MAX_ATTEMPTS = 50;
const execFileAsync = promisify(execFile);
const DEFAULT_REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

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

async function findListenerPidsOnPort(port) {
  try {
    const { stdout } = await execFileAsync('lsof', ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-t']);
    return [...new Set(stdout.trim().split(/\s+/).filter(Boolean).map(Number).filter(Number.isInteger))];
  } catch (error) {
    if (error.code === 1) {
      return [];
    }
    throw error;
  }
}

async function getProcessInfo(pid) {
  const [{ stdout: command }, { stdout: cwdOutput }] = await Promise.all([
    execFileAsync('ps', ['-p', String(pid), '-o', 'command=']),
    execFileAsync('lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'])
  ]);
  const cwd = cwdOutput.split('\n').find((line) => line.startsWith('n'))?.slice(1) || '';
  return { pid, command: command.trim(), cwd };
}

function isPidRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForPidExit(pid, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!isPidRunning(pid)) {
      return true;
    }
    await sleep(100);
  }
  return !isPidRunning(pid);
}

async function terminatePid(pid) {
  if (!isPidRunning(pid)) {
    return;
  }
  process.kill(pid, 'SIGTERM');
  if (await waitForPidExit(pid)) {
    return;
  }
  process.kill(pid, 'SIGKILL');
  await waitForPidExit(pid, 1000);
}

function isPreviousProxyProcess(info, repoRoot) {
  const cwd = info?.cwd ? resolve(info.cwd) : '';
  const root = resolve(repoRoot);
  const command = String(info?.command || '').replaceAll('\\', '/');
  const rootCommand = `${root.replaceAll('\\', '/')}/src/index.js`;

  return (
    cwd === root
    && /(^|[\/\s])node(?:\s|$)/.test(command)
    && (/(^|\s)src\/index\.js(?:\s|$)/.test(command) || command.includes(rootCommand))
  );
}

export async function killPreviousProxyInstances({
  requestedPort = DEFAULT_TEST_PORT,
  explicit = false,
  maxAttempts = DEFAULT_MAX_ATTEMPTS,
  repoRoot = DEFAULT_REPO_ROOT,
  findListenerPids = findListenerPidsOnPort,
  getProcessInfo: inspectProcess = getProcessInfo,
  killPid = terminatePid
} = {}) {
  const startPort = normalizePort(requestedPort);
  const attempts = explicit ? 1 : maxAttempts;
  const killed = [];
  const seenPids = new Set();

  for (let offset = 0; offset < attempts; offset += 1) {
    const port = startPort + offset;
    if (port > 65535) break;

    for (const pid of await findListenerPids(port)) {
      if (seenPids.has(pid)) continue;
      seenPids.add(pid);

      const info = await inspectProcess(pid);
      if (!isPreviousProxyProcess(info, repoRoot)) continue;

      await killPid(pid);
      killed.push({ pid, port, command: info.command });
    }
  }

  return killed;
}

export async function findAvailablePort({
  host = '127.0.0.1',
  requestedPort = DEFAULT_TEST_PORT,
  explicit = false,
  maxAttempts = DEFAULT_MAX_ATTEMPTS,
  canListen: checkCanListen = canListen
} = {}) {
  const startPort = normalizePort(requestedPort);
  const attempts = explicit ? 1 : maxAttempts;

  for (let offset = 0; offset < attempts; offset += 1) {
    const port = startPort + offset;
    if (port > 65535) break;
    if (await checkCanListen({ host, port })) {
      return port;
    }
  }

  if (explicit) {
    throw new Error(`TEST_PORT ${startPort} is already in use on ${host}`);
  }

  const endPort = Math.min(startPort + attempts - 1, 65535);
  throw new Error(`No available test port found from ${startPort} to ${endPort} on ${host}`);
}

export async function prepareTestPort(options = {}) {
  const killed = await killPreviousProxyInstances(options);
  const port = await findAvailablePort(options);
  return { port, killed };
}

async function main() {
  const [host = '127.0.0.1', portArg = String(DEFAULT_TEST_PORT), explicitArg = '0'] = process.argv.slice(2);
  const result = await prepareTestPort({
    host,
    requestedPort: portArg,
    explicit: explicitArg === '1'
  });
  for (const { pid, port } of result.killed) {
    console.error(`Stopped previous codex-proxy test server PID ${pid} on ${host}:${port}`);
  }
  console.log(result.port);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
