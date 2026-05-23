import test from 'node:test';
import assert from 'node:assert/strict';

const UI_URL = process.env.UI_TEST_URL || 'http://localhost:8081/';

async function getText(html, regex) {
  const match = html.match(regex);
  return match ? match[1] : null;
}

test('Web UI loads and includes core navigation', async () => {
  const res = await fetch(UI_URL);
  assert.equal(res.status, 200);
  const html = await res.text();

  // Basic smoke checks that are resilient to styling changes.
  assert.ok(html.includes('<title>Codex Claude Proxy</title>'));
  assert.ok(html.includes('Dashboard'));
  assert.ok(html.includes('Metrics'));
  assert.ok(html.includes('Accounts'));
  assert.ok(html.includes('Server Logs'));
  assert.ok(html.includes('Settings'));
  assert.ok(html.includes('Monitor'));
  assert.ok(html.includes('Manage'));
});

test('Web UI loads app bundle and has a logs container', async () => {
  const res = await fetch(UI_URL);
  assert.equal(res.status, 200);
  const html = await res.text();

  // Script is the main interactive surface.
  assert.ok(html.includes('<script src="/js/app.js"></script>'));

  // Logs view uses this id; useful for streaming/log rendering.
  assert.ok(html.includes('id="logs-container"'));
});

test('Metrics UI includes usage panels and recent request table', async () => {
  const res = await fetch(UI_URL);
  assert.equal(res.status, 200);
  const html = await res.text();

  assert.ok(html.includes('Token Usage'));
  assert.ok(html.includes('id="metrics-recent-events"'));
  assert.ok(html.includes(`x-show="activeTab === 'metrics'"`));
});

test('UI Quick Test and Haiku test controls are present', async () => {
  const res = await fetch(UI_URL);
  assert.equal(res.status, 200);
  const html = await res.text();

  // Find the two test panels by their headings.
  assert.ok(html.includes('Quick Test'));
  assert.ok(html.includes('Haiku Test'));

  // Buttons: labels should remain stable.
  assert.ok(html.includes('>Test<'));
  assert.ok(html.includes('>Test Haiku<'));
});

test('Settings UI includes Claude model mapping controls', async () => {
  const res = await fetch(UI_URL);
  assert.equal(res.status, 200);
  const html = await res.text();

  assert.ok(html.includes('Claude Model Mapping'));
  assert.ok(html.includes('data-model-mapping-alias="opus"'));
  assert.ok(html.includes('data-model-mapping-alias="sonnet"'));
  assert.ok(html.includes('data-model-mapping-alias="haiku"'));
  assert.ok(html.includes('Reasoning'));
});

test('Settings UI includes Claude proxy configuration controls', async () => {
  const res = await fetch(UI_URL);
  assert.equal(res.status, 200);
  const html = await res.text();

  assert.ok(html.includes('Configure Claude Code'));
  assert.ok(html.includes('Configure on startup'));
  assert.ok(html.includes('@click="configureClaudeProxy()"'));
  assert.ok(html.includes('@change="setConfigureClaudeOnStartup($event.target.checked)"'));
});

test('Settings UI does not expose account strategy controls', async () => {
  const htmlRes = await fetch(UI_URL);
  assert.equal(htmlRes.status, 200);
  const html = await htmlRes.text();

  assert.equal(html.includes('Account Selection Strategy'), false);
  assert.equal(html.includes('setAccountStrategy'), false);
  assert.equal(html.includes('Round-Robin'), false);

  const jsRes = await fetch(new URL('/js/app.js', UI_URL));
  assert.equal(jsRes.status, 200);
  const js = await jsRes.text();

  assert.equal(js.includes('/settings/account-strategy'), false);
  assert.equal(js.includes('accountStrategy'), false);
  assert.equal(js.includes('strategySaving'), false);
  assert.equal(js.includes('multiAccountRotationEnabled'), false);
});

test('light macOS theme keeps hover text readable', async () => {
  const res = await fetch(new URL('/css/style.css', UI_URL));
  assert.equal(res.status, 200);
  const css = await res.text();

  const lightThemeStart = css.indexOf('/* Native macOS glass treatment */');
  assert.ok(lightThemeStart > -1, 'Expected light macOS theme CSS block');

  for (const selector of [
    '.hover\\:text-white:hover',
    '.group:hover .group-hover\\:text-white'
  ]) {
    const overrideIndex = css.indexOf(selector, lightThemeStart);
    assert.ok(
      overrideIndex > lightThemeStart,
      `Expected ${selector} to be overridden inside the light theme block`
    );

    const overrideRule = css.slice(overrideIndex, css.indexOf('}', overrideIndex) + 1);
    assert.match(
      overrideRule,
      /color:\s*var\(--text-strong\)/,
      `Expected ${selector} hover text to use the light theme strong text color`
    );
  }
});

test('app.js defines expected Alpine state keys (smoke)', async () => {
  const res = await fetch(new URL('/js/app.js', UI_URL));
  assert.equal(res.status, 200);
  const js = await res.text();

  // These are key behaviors we rely on.
  for (const needle of [
    "Alpine.data('app'",
    'activeTab',
    'refreshAccounts()',
    'checkHealth()',
    'serverUrl',
    'loadMetrics()',
    'metricsSummary',
    'metricsStorage',
    'metricsRecent',
    'formatTokenCount(value)',
    'startLogStream()',
    'loadModelMappingsSetting()',
    'loadClaudeProxySetting()',
    'configureClaudeProxy()',
    'setConfigureClaudeOnStartup(enabled)',
    'setModelMapping(alias, model)',
    'setReasoningMapping(alias, reasoning)',
    'setHaikuModel(model)',
    'testChat()',
    'testHaikuChat()'
  ]) {
    assert.ok(js.includes(needle), `Expected app.js to include ${needle}`);
  }
});

test('Health endpoint drives Online/Offline indicator (server contract)', async () => {
  // This checks the server contract used by the UI (checkHealth -> /health).
  const res = await fetch(new URL('/health', UI_URL));
  assert.equal(res.status, 200);

  const text = await res.text();
  // Expect either JSON or plain text; just ensure it is non-empty.
  assert.ok(text.length > 0);

  // UI expects response.ok to mean connected.
  assert.ok(res.ok);
});
