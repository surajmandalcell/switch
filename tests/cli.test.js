import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

function runCli(args, env = {}) {
  return spawnSync(process.execPath, [join(process.cwd(), 'bin/cli.js'), ...args], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      ...env
    },
    encoding: 'utf8'
  });
}

test('CLI reports the package version', () => {
  const result = runCli(['--version']);

  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), '1.2.0');
});

test('CLI help exposes singular account commands only', () => {
  const result = runCli(['--help']);
  const pluralAccountWord = 'account' + 's';

  assert.equal(result.status, 0);
  assert.match(result.stdout, /account add/);
  assert.match(result.stdout, /account show/);
  assert.equal(result.stdout.includes(pluralAccountWord), false);
});

test('CLI rejects the removed plural accounts command', () => {
  const pluralAccountWord = 'account' + 's';
  const result = runCli([pluralAccountWord, 'list']);

  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`Unknown command: ${pluralAccountWord}`));
});

test('account CLI help documents replacement semantics', (t) => {
  const configDir = mkdtempSync(join(tmpdir(), 'codex-proxy-cli-'));
  t.after(() => rmSync(configDir, { recursive: true, force: true }));

  const result = runCli(['account', 'help'], {
    CODEX_CLAUDE_PROXY_CONFIG_DIR: configDir
  });

  assert.equal(result.status, 0);
  assert.match(result.stdout, /codex-proxy account add/);
  assert.match(result.stdout, /Adding or importing an account replaces the existing local account/);
  assert.doesNotMatch(result.stdout, /account switch/);
});
