import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { canonicalResponse, streamEvent } from '../domain/protocol/canonical.js';

export function createCommandAdapter() {
  return {
    type: 'command',
    async execute(request, context) {
      const events = [];
      for await (const event of runCommand(request, context)) events.push(event);
      const content = [];
      let usage = {};
      let stopReason = 'end_turn';
      for (const event of events) {
        if (event.type === 'text-delta') content.push({ type: 'text', text: event.text });
        if (event.type === 'tool-call') content.push({ type: 'tool-call', id: event.id, name: event.name, input: parseJson(event.argumentsDelta) });
        if (event.type === 'usage') usage = event.usage;
        if (event.type === 'finish') stopReason = event.stopReason;
      }
      return canonicalResponse({ model: request.model, content, usage, stopReason });
    },
    stream: runCommand,
  };
}

async function* runCommand(request, context) {
  const command = context.provider.adapter?.command;
  const args = context.provider.adapter?.args ?? [];
  if (!command) throw Object.assign(new Error('Command provider has no command configured.'), { status: 400 });
  const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, ...(context.provider.adapter?.environment ?? {}), SPI_ACCOUNT_SECRET: context.secret ?? '' }, shell: false, windowsHide: true });
  const exit = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
  const abort = () => child.kill('SIGTERM');
  context.signal?.addEventListener('abort', abort, { once: true });
  child.stdin.end(`${JSON.stringify(request)}\n`);
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  try {
    yield streamEvent('start', { model: request.model });
    for await (const line of createInterface({ input: child.stdout, crlfDelay: Infinity })) {
      if (!line.trim()) continue;
      const event = JSON.parse(line);
      if (!event.type) throw new Error('Command provider emitted an event without type.');
      yield event;
    }
    const code = await exit;
    if (context.signal?.aborted) { const error = new Error('Cancelled'); error.name = 'AbortError'; error.code = 'CLIENT_ABORTED'; throw error; }
    if (code !== 0) throw Object.assign(new Error(stderr || `Command exited with code ${code}.`), { status: 502, code: 'COMMAND_FAILED' });
  } finally {
    context.signal?.removeEventListener('abort', abort);
    if (!child.killed) child.kill('SIGTERM');
  }
}

function parseJson(value) { try { return JSON.parse(value ?? '{}'); } catch { return {}; } }
