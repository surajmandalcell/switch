import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const text = (relative) => readFile(path.join(root, relative), 'utf8');

async function exists(relative) {
  return stat(path.join(root, relative)).then(() => true, () => false);
}

test('polling forms use dirty-aware drafts and mutations report success', async () => {
  const app = await text('desktop/renderer/App.jsx');
  const hook = await text('desktop/renderer/hooks/useSyncedDraft.js');
  assert.match(app, /return true;/);
  assert.match(app, /return false;/);
  assert.match(hook, /if \(!dirty\) setDraftState/);
  for (const file of ['Catalog.jsx', 'Providers.jsx', 'Routing.jsx', 'Settings.jsx']) {
    assert.match(await text(`desktop/renderer/pages/${file}`), /useSyncedDraft/);
  }
});

test('usage interaction handles failures and keyboard selection', async () => {
  const usage = await text('desktop/renderer/pages/Usage.jsx');
  assert.match(usage, /\.catch\(\(cause\) =>/);
  assert.match(usage, /role="button"/);
  assert.match(usage, /tabIndex=\{0\}/);
  assert.match(usage, /event\.key === 'Enter'/);
  assert.match(usage, /role="alert"/);
});

test('site interaction and generated links remain safe and accessible', async () => {
  const script = await text('website/assets/site.js');
  const styles = await text('website/assets/site.css');
  const builder = await text('scripts/build-site.mjs');
  const html = await text('website/index.html');
  assert.match(script, /matchMedia\('\(min-width: 841px\)'\)/);
  assert.match(script, /event\.key === 'Escape'/);
  assert.match(script, /Copy failed/);
  assert.match(styles, /site-navigation a:focus-visible[\s\S]*outline: 2px solid/);
  assert.match(builder, /\^\[a-z\]\[a-z0-9\+\.\-\]\*:/);
  assert.doesNotMatch(builder, /<\[\^>\]\+>/);
  assert.match(html, /color-scheme" content="light"/);
  assert.match(html, /social-card\.svg/);
  assert.equal(await exists('website/assets/social-card.svg'), true);
});

test('desktop status and compact responsive controls retain explicit states', async () => {
  const shell = await text('desktop/renderer/components/Shell.jsx');
  const styles = await text('desktop/renderer/styles.css');
  assert.match(shell, /role="group" aria-label="Gateway status"/);
  assert.match(shell, /topbar-status \$\{snapshot \? 'online' : 'starting'\}/);
  assert.match(styles, /topbar-status\.starting i/);
  assert.match(styles, /clip-path: inset\(50%\)/);
  assert.match(styles, /\.compact select[\s\S]*right 12px center/);
  assert.match(styles, /api-key-row[\s\S]*auto auto/);
});

test('temporary completion machinery is absent from the publishable branch', async () => {
  for (const relative of [
    '.complete-followup',
    '.followup-diagnostic.txt',
    '.github/workflows/complete-ibm-redesign-followup.yml',
    '.github/workflows/execute-complete-followup.yml',
    '.github/workflows/execute-complete-followup-v2.yml',
    '.github/workflows/capture-followup-failure.yml',
    'scripts/prepare-followup-patch.py',
    '.mac-package-error.txt',
    '.mac-build-tail.txt',
    '.github/workflows/capture-mac-package-error.yml',
    '.github/workflows/diagnose-mac-package.yml',
    '.github/workflows/finalize-icon-packaging.yml',
    '.github/workflows/finalize-web-icon-fallbacks.yml',
  ]) {
    assert.equal(await exists(relative), false, `${relative} must not be published`);
  }
});
