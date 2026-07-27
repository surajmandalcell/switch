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
  assert.equal(pkg.version, '2.1.2');
  assert.equal(pkg.private, true);
  assert.equal(pkg.main, 'desktop/main/index.js');
  assert.deepEqual(
    Object.keys(pkg.build).filter((key) => ['mac', 'win', 'linux'].includes(key)).sort(),
    ['linux', 'mac', 'win'],
  );
});

test('release metadata uses one version in the package, lockfile, README, website, and changelog', async () => {
  const pkg = JSON.parse(await text('package.json'));
  const lock = JSON.parse(await text('package-lock.json'));
  const readme = await text('README.md');
  const website = await text('website/index.html');
  const changelog = await text('CHANGELOG.md');

  assert.equal(pkg.version, '2.1.2');
  assert.equal(lock.version, pkg.version);
  assert.equal(lock.packages[''].version, pkg.version);
  assert.match(readme, /version-2\.1\.2/);
  assert.match(website, /Version 2\.1\.2 · MIT License/);
  assert.match(changelog, /## 2\.1\.2 - 2026-07-28/);
});

test('legacy, generated, and temporary repository paths are absent', async () => {
  for (const relative of [
    'bin', 'public', 'images', 'coverage', 'test-results', '.cache',
    '.rework', '.lockgen', '.publish', 'coverage-audit.txt',
    '.github/workflows/coverage-audit.yml',
  ]) {
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
  const obsoleteFiles = [
    `docs/${['MIGRATION', '_V1.md'].join('')}`,
    `docs/${['WRITING', '_STANDARD.md'].join('')}`,
  ];
  for (const relative of obsoleteFiles) assert.equal(await exists(relative), false);

  const publicText = [
    await text('README.md'),
    await text('CHANGELOG.md'),
    await text('docs/INDEX.md'),
  ].join('\n');
  const forbiddenPhrases = [
    ['Version 1', ' migration'].join(''),
    ['ASD-STE100', ' writing profile'].join(''),
    ['Writing', ' standard'].join(''),
  ];
  for (const phrase of forbiddenPhrases) assert.equal(publicText.includes(phrase), false);
});

test('README omits the request-boundary sequence diagram', async () => {
  const readme = await text('README.md');
  assert.doesNotMatch(readme, /## Request boundary|sequenceDiagram|participant RouteA|participant RouteB/);
  assert.match(readme, /## System flow/);
  assert.match(readme, /## Architecture/);
  assert.match(readme, /## Security boundaries/);
});

test('coverage gate measures every source layer at near-complete thresholds', async () => {
  const runner = await text('scripts/run-tests.mjs');
  for (const rule of [
    /--test-coverage-include=src\/\*\*/,
    /--test-coverage-lines=99/,
    /--test-coverage-functions=96/,
    /--test-coverage-branches=90/,
  ]) assert.match(runner, rule);
  assert.doesNotMatch(runner, /--test-coverage-include=src\/domain|--test-coverage-include=src\/application/);
  for (const relative of [
    'tests/application/coverage-completion.test.js',
    'tests/application/bootstrap-coverage.test.js',
    'tests/domain/coverage-completion.test.js',
    'tests/infrastructure/coverage-completion.test.js',
    'tests/providers/coverage-completion.test.js',
  ]) assert.equal(await exists(relative), true, `${relative} is required`);
});

test('routine workflows run only after a master push', async () => {
  const desktop = await text('.github/workflows/desktop-ci.yml');
  const codeql = await text('.github/workflows/codeql.yml');
  const uiAudit = await text('.github/workflows/ui-audit.yml');

  for (const workflow of [desktop, codeql, uiAudit]) {
    assert.match(workflow, /push:[\s\S]*branches:\s*\[master\]/);
    assert.doesNotMatch(workflow, /pull_request:/);
    assert.doesNotMatch(workflow, /workflow_dispatch:/);
    assert.doesNotMatch(workflow, /schedule:/);
  }

  assert.match(desktop, /npm run build/);
  assert.match(desktop, /npm audit --omit=dev --audit-level=high/);
  assert.match(desktop, /ubuntu-latest, windows-latest, macos-latest/);
  assert.match(desktop, /actions\/upload-artifact@v7/);
  assert.match(uiAudit, /node scripts\/audit-ui\.mjs/);
});

test('Desktop CI removes every non-default branch after successful packages', async () => {
  const workflow = await text('.github/workflows/desktop-ci.yml');
  assert.match(workflow, /cleanup-branches:/);
  assert.match(workflow, /needs:\s*\[validate, package\]/);
  assert.match(workflow, /needs\.validate\.result == 'success'/);
  assert.match(workflow, /needs\.package\.result == 'success'/);
  assert.match(workflow, /permissions:[\s\S]*contents:\s*write/);
  assert.match(workflow, /default_branch=.*gh api/);
  assert.match(workflow, /branches\?per_page=100/);
  assert.match(workflow, /git\/refs\/heads\/\$branch/);
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
  assert.match(release, /\/subscription-proxy-inator\//);
  assert.match(release, /Pull requests and manual dispatches do not start/);
});

test('release workflow requires a version tag and uploads checksummed artifacts', async () => {
  const workflow = await text('.github/workflows/release.yml');
  assert.match(workflow, /tags:[\s\S]*'v\*'/);
  assert.doesNotMatch(workflow, /pull_request:|workflow_dispatch:|schedule:/);
  assert.match(workflow, /node scripts\/checksums\.mjs/);
  assert.match(workflow, /gh release upload/);
});

test('public website uses local assets and stable layout contracts', async () => {
  const html = await text('website/index.html');
  const css = await text('website/assets/site.css');
  const script = await text('website/assets/site.js');
  assert.match(html, /docs\//);
  assert.match(html, /assets\/icon\.svg/);
  assert.equal(await exists('website/assets/layout.css'), true);
  assert.equal(await exists('website/assets/docs.css'), true);
  assert.match(script, /loadStylesheet\('layout\.css'\)/);
  assert.match(script, /loadStylesheet\('docs\.css'\)/);
  assert.doesNotMatch(css, /@import\s+url\(['"]https?:/);
});

test('repository policy files are present', async () => {
  for (const relative of [
    '.github/CODEOWNERS', '.github/dependabot.yml', '.github/pull_request_template.md',
    '.github/ISSUE_TEMPLATE/bug.yml', '.github/ISSUE_TEMPLATE/feature.yml',
    'CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md', 'CODE_OF_CONDUCT.md',
  ]) assert.equal(await exists(relative), true, `${relative} is required`);
});
