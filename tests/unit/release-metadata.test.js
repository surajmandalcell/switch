import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

function readJson(path) {
  return JSON.parse(readFileSync(join(process.cwd(), path), 'utf8'));
}

function readText(path) {
  return readFileSync(join(process.cwd(), path), 'utf8');
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

test('release metadata is aligned to the package version', () => {
  const packageJson = readJson('package.json');
  const packageLock = readJson('package-lock.json');
  const appJs = readText('public/js/app.js');
  const serverIndex = readText('src/index.js');
  const version = packageJson.version;
  const escapedVersion = escapeRegExp(version);

  assert.equal(packageLock.version, version);
  assert.equal(packageLock.packages[''].version, version);
  assert.match(appJs, new RegExp(`version: '${escapedVersion}'`));
  assert.match(serverIndex, new RegExp(`Codex Claude Proxy v${escapedVersion}`));
});

test('CHANGELOG.md is package-visible and documents release entries', () => {
  const packageJson = readJson('package.json');
  const changelogPath = join(process.cwd(), 'CHANGELOG.md');
  const readme = readText('README.md');

  assert.equal(existsSync(changelogPath), true);
  assert.ok(packageJson.files.includes('CHANGELOG.md'));

  const changelog = readText('CHANGELOG.md');
  assert.match(changelog, /^# Changelog\n/);
  assert.match(changelog, /## \[\d+\.\d+\.\d+\] - \d{4}-\d{2}-\d{2}/);
  assert.match(changelog, /Single-account local mode/);
  assert.match(readme, /\[Changelog\]\(CHANGELOG\.md\)/);
});
