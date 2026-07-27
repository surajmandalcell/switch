import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const text = (relative) => readFile(path.join(root, relative), 'utf8');

test('public text uses the ASD-STE100 project gate', async () => {
  const pkg = JSON.parse(await text('package.json'));
  const checker = await text('scripts/check-ste.mjs');
  const profile = await text('docs/WRITING_STANDARD.md');

  assert.equal(pkg.scripts['check:ste'], 'node scripts/check-ste.mjs');
  assert.match(pkg.scripts.check, /npm run check:ste/);
  assert.match(checker, /ASD-STE100 project profile/);
  assert.match(checker, /sentence exceeds/);
  assert.match(checker, /prohibited phrase/);
  assert.match(checker, /'README\.md'/);
  assert.match(checker, /'website\/index\.html'/);
  assert.match(checker, /'website\/manifest\.webmanifest'/);
  assert.match(checker, /walkMarkdown\(path\.join\(root, 'docs'\)\)/);
  assert.match(checker, /const namedEntities = new Map/);
  assert.match(checker, /function stripHtmlElement/);
  assert.doesNotMatch(checker, /replaceAll\('&amp;', '&'\)/);
  assert.doesNotMatch(checker, /<script\[\\s\\S\]\*\?<\\\/script>/);
  assert.match(profile, /Issue 9/);
  assert.match(profile, /maximum of 20 words in an instruction/);
  assert.match(profile, /maximum of 25 words in a descriptive sentence/);
});
