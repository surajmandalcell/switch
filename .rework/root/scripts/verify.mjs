import { readdir, readFile, stat } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const required = [
  'README.md',
  'CHANGELOG.md',
  'docs/ARCHITECTURE.md',
  'docs/CONFIGURATION.md',
  'docs/PROVIDERS.md',
  'docs/API.md',
  'docs/SECURITY.md',
  'desktop/main/index.js',
  'desktop/main/proxy.js',
  'desktop/main/router.js',
  'desktop/renderer/App.jsx',
];

for (const relative of required) {
  const full = path.join(root, relative);
  if (!(await stat(full).catch(() => null))) throw new Error(`Missing required file: ${relative}`);
}

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await walk(full)));
    else files.push(full);
  }
  return files;
}

const syntaxTargets = (await walk(path.join(root, 'desktop')))
  .filter((file) => file.endsWith('.js'))
  .concat(await walk(path.join(root, 'scripts')))
  .filter((file) => file.endsWith('.js') || file.endsWith('.mjs'));

for (const file of syntaxTargets) {
  const result = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${path.relative(root, file)} failed syntax validation:\n${result.stderr}`);
}

const packageJson = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
if (!packageJson.build?.mac || !packageJson.build?.win || !packageJson.build?.linux) {
  throw new Error('electron-builder targets must cover macOS, Windows, and Linux.');
}

console.log(`Verified ${syntaxTargets.length} JavaScript files and ${required.length} required project files.`);
