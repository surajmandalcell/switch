import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const expectedVersion = '1.2.0';

function readJson(path) {
  return JSON.parse(readFileSync(join(process.cwd(), path), 'utf8'));
}

function readText(path) {
  return readFileSync(join(process.cwd(), path), 'utf8');
}

test('release metadata is aligned to package version 1.2.0', () => {
  const packageJson = readJson('package.json');
  const packageLock = readJson('package-lock.json');
  const appJs = readText('public/js/app.js');
  const serverIndex = readText('src/index.js');

  assert.equal(packageJson.version, expectedVersion);
  assert.equal(packageLock.version, expectedVersion);
  assert.equal(packageLock.packages[''].version, expectedVersion);
  assert.match(appJs, /version: '1\.2\.0'/);
  assert.match(serverIndex, /Codex Claude Proxy v1\.2\.0/);
});

test('CHANGELOG.md is package-visible and documents the latest release', () => {
  const packageJson = readJson('package.json');
  const changelogPath = join(process.cwd(), 'CHANGELOG.md');
  const readme = readText('README.md');

  assert.equal(existsSync(changelogPath), true);
  assert.ok(packageJson.files.includes('CHANGELOG.md'));

  const changelog = readText('CHANGELOG.md');
  assert.match(changelog, /^# Changelog\n/);
  assert.match(changelog, /## \[1\.2\.0\] - 2026-05-24/);
  assert.match(changelog, /Single-account local mode/);
  assert.match(readme, /\[Changelog\]\(CHANGELOG\.md\)/);
});
