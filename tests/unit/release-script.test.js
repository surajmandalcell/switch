import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

function readText(path) {
  return readFileSync(join(process.cwd(), path), 'utf8');
}

function readJson(path) {
  return JSON.parse(readText(path));
}

test('test:all runs mutable unit and server-backed tests sequentially', () => {
  const packageJson = readJson('package.json');

  assert.equal(packageJson.scripts['test:all'], 'npm run test:unit && npm test');
});

test('release verifier uses an isolated proxy config directory', () => {
  const script = readText('scripts/npm.sh');

  assert.match(script, /CODEX_CLAUDE_PROXY_TEST_CONFIG_DIR/);
  assert.match(script, /mktemp -d .*codex-proxy-release-config/);
  assert.match(script, /CODEX_CLAUDE_PROXY_CONFIG_DIR="\$test_config_dir"[\s\S]+src\/index\.js/);
  assert.match(script, /CODEX_CLAUDE_PROXY_CONFIG_DIR="\$test_config_dir"[\s\S]+"\$NPM" run test:all/);
});

test('make update rolls back its own version files when verification fails', () => {
  const script = readText('scripts/npm.sh');

  assert.match(script, /rollback_update\(\)/);
  assert.match(script, /git restore --staged --worktree -- "\$\{release_files\[@\]\}"/);
  assert.match(script, /trap fail_update ERR/);
  assert.match(script, /trap interrupt_update INT/);
  assert.match(script, /trap terminate_update TERM/);
  assert.match(script, /trap - ERR INT TERM/);
});
