import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';

const root = path.resolve(import.meta.dirname, '..');
async function collect(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await collect(full));
    else if (entry.name.endsWith('.test.js')) files.push(full);
  }
  return files;
}

const files = (await collect(path.join(root, 'tests'))).sort();
if (!files.length) throw new Error('No tests found.');
const watch = process.argv.includes('--watch');
const coverage = process.argv.includes('--coverage');
const args = ['--test'];
if (watch) args.push('--watch');
if (coverage) args.push(
  '--experimental-test-coverage',
  '--test-coverage-include=src/**',
  '--test-coverage-lines=99',
  '--test-coverage-functions=96',
  '--test-coverage-branches=90',
);
args.push(...files);
const child = spawn(process.execPath, args, { cwd: root, stdio: 'inherit' });
child.once('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
