import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const scanRoots = ['README.md', 'CHANGELOG.md', 'docs', 'src', 'public', 'tests'];

function listFiles(path) {
  const fullPath = join(process.cwd(), path);
  if (statSync(fullPath).isFile()) return [path];

  return readdirSync(fullPath).flatMap((entry) => {
    const child = join(path, entry);
    const stats = statSync(join(process.cwd(), child));
    return stats.isDirectory() ? listFiles(child) : [child];
  });
}

function readScannedFiles() {
  return scanRoots.flatMap(listFiles).map((file) => ({
    file,
    text: readFileSync(join(process.cwd(), file), 'utf8')
  }));
}

test('first-party files do not reintroduce legacy account fallback surfaces', () => {
  const forbiddenTerms = [
    'rota' + 'tion',
    'rota' + 'tor',
    ['CODEX_CLAUDE_PROXY_ENABLE_MULTI_ACCOUNT', 'ROTATION'].join('_'),
    ['account', 'rota' + 'tion'].join('-')
  ];
  const forbidden = new RegExp(forbiddenTerms.join('|'));
  const offenders = readScannedFiles()
    .filter(({ text }) => forbidden.test(text))
    .map(({ file }) => file);

  assert.deepEqual(offenders, []);
});

test('first-party source and docs do not expose plural account-management APIs', () => {
  const pluralAccountPath = '/account' + 's';
  const forbiddenTerms = [
    pluralAccountPath,
    ['account' + 's', 'switch'].join('/'),
    ['refresh', 'all'].join('/'),
    ['quota', 'all'].join('/')
  ];
  const forbidden = new RegExp(forbiddenTerms.join('|'));
  const upstreamAccountCheckPath = ['/wham', 'account' + 's', 'check'].join('/');
  const offenders = readScannedFiles()
    .filter(({ file, text }) => {
      const allowedUpstreamPath = file === 'src/model-api.js'
        ? text.replace(upstreamAccountCheckPath, '')
        : text;
      return forbidden.test(allowedUpstreamPath);
    })
    .map(({ file }) => file);

  assert.deepEqual(offenders, []);
});
