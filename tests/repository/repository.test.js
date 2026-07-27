import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const text = (relative) => readFile(path.join(root, relative), 'utf8');
const exists = (relative) => stat(path.join(root, relative)).then(() => true, () => false);

test('package metadata identifies the current desktop application', async () => {
  const pkg = JSON.parse(await text('package.json'));
  assert.equal(pkg.name, 'subscription-proxy-inator');
  assert.equal(pkg.version, '2.1.1');
  assert.equal(pkg.private, true);
  assert.equal(pkg.main, 'desktop/main/index.js');
  assert.deepEqual(
    Object.keys(pkg.build).filter((key) => ['mac', 'win', 'linux'].includes(key)).sort(),
    ['linux', 'mac', 'win'],
  );
});

test('release metadata uses one version in the package, lockfile, README, and website', async () => {
  const pkg = JSON.parse(await text('package.json'));
  const lock = JSON.parse(await text('package-lock.json'));
  const readme = await text('README.md');
  const website = await text('website/index.html');

  assert.equal(pkg.version, '2.1.1');
  assert.equal(lock.version, pkg.version);
  assert.equal(lock.packages[''].version, pkg.version);
  assert.match(readme, /Version 2\.1\.1/);
  assert.match(website, /Version 2\.1\.1 · MIT/);
});

test('legacy and temporary repository roots are absent', async () => {
  for (const relative of ['bin', 'public', 'images', '.rework', '.lockgen', '.publish']) {
    assert.equal(await exists(relative), false, `${relative} must not exist`);
  }
});

test('renderer stays behind the preload capability boundary', async () => {
  const renderer = [
    'desktop/renderer/App.jsx',
    'desktop/renderer/main.jsx',
    'desktop/renderer/mock.js',
  ].map(text);
  const source = (await Promise.all(renderer)).join('\n');
  assert.doesNotMatch(source, /(?:from\s+['"]electron['"]|ipcRenderer|node:|require\s*\()/);
  const preload = await text('desktop/preload/index.cjs');
  assert.match(preload, /contextBridge\.exposeInMainWorld/);
});

test('Electron window is sandboxed and context isolated', async () => {
  const main = await text('desktop/main/index.js');
  assert.match(main, /contextIsolation:\s*true/);
  assert.match(main, /sandbox:\s*true/);
  assert.match(main, /nodeIntegration:\s*false/);
});

test('public documentation covers every supported operating concern', async () => {
  for (const relative of [
    'docs/QUICK_START.md', 'docs/ARCHITECTURE.md', 'docs/DESIGN_SYSTEM.md', 'docs/CONFIGURATION.md',
    'docs/PROVIDERS.md', 'docs/API.md', 'docs/ROUTING.md', 'docs/USAGE.md',
    'docs/SECURITY.md', 'docs/TROUBLESHOOTING.md', 'docs/DEVELOPMENT.md',
    'docs/RELEASE.md',
  ]) assert.equal(await exists(relative), true, `${relative} is required`);
});

test('obsolete documentation pages and links are absent', async () => {
  assert.equal(await exists('docs/MIGRATION_V1.md'), false);
  assert.equal(await exists('docs/WRITING_STANDARD.md'), false);

  const publicText = [
    await text('README.md'),
    await text('CHANGELOG.md'),
    await text('docs/INDEX.md'),
  ].join('\n');

  assert.doesNotMatch(publicText, /MIGRATION_V1|WRITING_STANDARD|Version 1 migration|ASD-STE100 writing profile|Writing standard/);
});

test('desktop CI validates and packages all three platforms', async () => {
  const workflow = await text('.github/workflows/desktop-ci.yml');
  assert.match(workflow, /npm run build/);
  assert.match(workflow, /npm audit --omit=dev --audit-level=high/);
  assert.match(workflow, /ubuntu-latest, windows-latest, macos-latest/);
  assert.match(workflow, /actions\/upload-artifact@v7/);
});

test('CodeQL is least-privilege and documentation hosting is explicit', async () => {
  const codeql = await text('.github/workflows/codeql.yml');
  const readme = await text('README.md');
  const release = await text('docs/RELEASE.md');
  assert.equal(await exists('.github/workflows/pages.yml'), false);
  assert.match(codeql, /security-events:\s*write/);
  assert.match(codeql, /github\/codeql-action\/analyze@v4/);
  assert.match(readme, /https:\/\/surajmandalcell\.github\.io\/subscription-proxy-inator\//);
  assert.match(readme, /img\.shields\.io\/badge\/docs-online/);
  assert.match(release, /surajmandalcell\.github\.io/);
  assert.match(release, /\/subscription-proxy-inator\//);
});

test('release workflow requires a version tag and uploads checksummed artifacts', async () => {
  const workflow = await text('.github/workflows/release.yml');
  assert.match(workflow, /tags:[\s\S]*'v\*'/);
  assert.match(workflow, /node scripts\/checksums\.mjs/);
  assert.match(workflow, /gh release upload/);
});

test('public website is local-asset only and links documentation', async () => {
  const html = await text('website/index.html');
  const css = await text('website/assets/site.css');
  assert.match(html, /docs\//);
  assert.match(html, /assets\/icon\.svg/);
  assert.doesNotMatch(css, /@import\s+url\(['"]https?:/);
});

test('repository policy files are present', async () => {
  for (const relative of [
    '.github/CODEOWNERS', '.github/dependabot.yml', '.github/pull_request_template.md',
    '.github/ISSUE_TEMPLATE/bug.yml', '.github/ISSUE_TEMPLATE/feature.yml',
    'CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md', 'CODE_OF_CONDUCT.md',
  ]) assert.equal(await exists(relative), true, `${relative} is required`);
});
