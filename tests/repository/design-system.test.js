import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const text = (relative) => readFile(path.join(root, relative), 'utf8');
const exists = (relative) => stat(path.join(root, relative)).then(() => true, () => false);

test('the renderer uses pinned IBM Plex packages without the retired presentation dependencies', async () => {
  const pkg = JSON.parse(await text('package.json'));
  const entry = await text('desktop/renderer/main.jsx');
  assert.equal(pkg.version, '2.1.2');
  assert.equal(pkg.dependencies['@fontsource/ibm-plex-sans'], '5.3.0');
  assert.equal(pkg.dependencies['@fontsource/ibm-plex-mono'], '5.3.0');
  assert.equal(pkg.dependencies['@fontsource/inter'], undefined);
  assert.equal(pkg.dependencies['@pikoloo/darwin-ui'], undefined);
  assert.match(entry, /@fontsource\/ibm-plex-sans\/400\.css/);
  assert.match(entry, /@fontsource\/ibm-plex-mono\/400\.css/);
  assert.doesNotMatch(entry, /inter|darwin-ui/i);
});

test('desktop geometry follows the shared spacing and responsive contract', async () => {
  const css = await text('desktop/renderer/styles.css');
  assert.match(css, /--spacing-03:\s*8px/);
  assert.match(css, /--control-height:\s*40px/);
  assert.match(css, /grid-template-columns:\s*repeat\(16,/);
  for (const width of ['1320px', '1040px', '800px', '620px']) assert.match(css, new RegExp(`max-width:\\s*${width}`));
  assert.match(css, /font-family:\s*"IBM Plex Sans"/);
  assert.doesNotMatch(css, /backdrop-filter|radial-gradient|ambient-glow/i);
});

test('the website presents implemented facts instead of fabricated product telemetry', async () => {
  const html = await text('website/index.html');
  const css = await text('website/assets/site.css');
  for (const route of ['/v1/chat/completions', '/v1/responses', '/v1/messages', '/v1/messages/count_tokens', '/v1/models', '/health']) {
    assert.match(html, new RegExp(route.replaceAll('/', '\\/')));
  }
  for (const fake of ['1,284', '99.4%', '$18.42', 'Good afternoon', 'floating-pill', 'ambient-one', 'Local workspace']) {
    assert.doesNotMatch(html, new RegExp(fake.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'));
  }
  assert.match(html, /Version 2\.1\.2/);
  assert.match(html, /One local API for Claude, Codex, and Z\.ai\./);
  assert.doesNotMatch(html, /hero-label|hero-assurance/);
  assert.match(css, /font-family:\s*"IBM Plex Sans"/);
  assert.match(css, /grid-template-columns:\s*repeat\(16,/);
  assert.doesNotMatch(css, /@import\s+url\(['"]https?:|backdrop-filter|radial-gradient/i);
});

test('the README uses IBM-style system diagrams and an honest release table', async () => {
  const readme = await text('README.md');
  assert.equal((readme.match(/```mermaid/g) ?? []).length, 4);
  assert.match(readme, /#0f62fe/);
  assert.match(readme, /System flow/);
  assert.match(readme, /Request boundary/);
  assert.match(readme, /Architecture/);
  assert.match(readme, /Security boundaries/);
  assert.match(readme, /Apple signing and notarization/);
  assert.match(readme, /Windows Authenticode signing/);
  assert.match(readme, /Pull requests do not start project workflows/);
});

test('the interface contract is documented and linked from the public documentation index', async () => {
  assert.equal(await exists('docs/DESIGN_SYSTEM.md'), true);
  const design = await text('docs/DESIGN_SYSTEM.md');
  const index = await text('docs/INDEX.md');
  assert.match(design, /8 px/);
  assert.match(design, /40 px/);
  assert.match(design, /not affiliated with or endorsed by IBM/i);
  assert.match(design, /Documentation layout/);
  assert.match(index, /DESIGN_SYSTEM\.md/);
});
