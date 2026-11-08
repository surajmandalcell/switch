// Renders the README header and feature tiles into docs/readme/.
// Run from the repository root: node packages/website/readme-art.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '../mac-gui/ui-lint/node_modules/playwright');

const root = path.resolve(__dirname, '../..');
const src = path.join(__dirname, 'public/assets');
const out = path.join(root, 'docs/readme');
const url = (file) => 'file://' + path.join(src, file);
const lights = '<i class="lights"><b></b><b></b><b></b></i>';
const pad = (s, n) => s + ' '.repeat(Math.max(0, n - s.length));

// Same layout and wording as the terminal app's Accounts screen (AIManagerCLI accountsLines).
const accounts = [
  pad('SWITCH', 48) + '08 NOV  09:41', '', 'Accounts', '', '<b>Codex CLI</b>',
  '<i>  ' + pad('grace.hopper@example', 32) + pad('DEFAULT', 10) + '88% weekly left</i>',
  '  ' + pad('linus.torvalds@example', 32) + pad('', 10) + '67% weekly left', '',
  'Actions', '  ⊕ Add account', '  ⇥ Advanced import', '  ⇥ Import current Droid login',
  '  ⌕ Discover accounts', '  ↻ Recover interrupted work', '  ⏻ Quit', '',
  '↑↓ move   →/Enter select   Esc quit',
].join('\n');
// Same text as AutoSwitchController's notification.
const autoSwitch = 'Codex account ada.lovelace@example has 8% left. Switched to grace.hopper@example.';

const figure = (tile, title, text) =>
  `<figure><div class="tile">${tile}</div><figcaption><b>${title}</b><span>${text}</span></figcaption></figure>`;
const page = (theme) => `<!doctype html><html data-theme="${theme}"><head><meta charset="utf-8"><style>
@font-face{font-family:Jost;src:url('${url('fonts/Jost.ttf')}');font-weight:100 900}
*{box-sizing:border-box}html,body{margin:0;background:transparent}
body{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,sans-serif;--ink:#1f2328;--muted:#59636e;--tile:#f2f2f4}
[data-theme=dark] body{--ink:#f0f6fc;--muted:#9198a1;--tile:#1c1c1e}
#wordmark{display:inline-block;padding:4px 10px 14px;font:800 144px/1 Jost,sans-serif;letter-spacing:-.04em;color:var(--ink)}
#bento{width:880px;display:grid;gap:22px}.row{display:grid;gap:16px;height:400px}
figure{margin:0;display:flex;flex-direction:column;min-width:0}.tile{position:relative;flex:1;overflow:hidden;border-radius:16px;background:url('${url('wall-blossom.webp')}') center/cover}
.tile.plain{background:var(--tile)}
figcaption{padding:12px 2px 0;min-height:58px}figcaption b{display:block;font-size:17px;letter-spacing:-.015em;color:var(--muted)}figcaption span{display:block;font-size:14.5px;color:var(--ink);margin-top:2px}
.lights{position:absolute;display:flex;z-index:2}.lights b{border-radius:50%;background:#ff5f57}.lights b+b{background:#febc2e}.lights b+b+b{background:#28c840}
.win{position:absolute;left:56px;top:70px;width:760px;border-radius:11px;overflow:hidden;container-type:inline-size;box-shadow:0 18px 50px rgba(0,0,0,.35),0 0 0 .5px rgba(0,0,0,.25)}.win img{display:block;width:100%}
.win .lights{top:1.5cqw;left:1.6cqw;gap:.65cqw}.win .lights b{width:1cqw;height:1cqw}
.pop{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}.pop img{height:290px;filter:drop-shadow(0 10px 24px rgba(0,0,0,.18))}
.tw{position:absolute;left:22px;top:44px;width:560px;border-radius:10px;overflow:hidden;background:#fff;color:#000;box-shadow:0 18px 44px rgba(0,0,0,.32),0 0 0 .5px rgba(0,0,0,.3)}
.twbar{height:28px;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:600;color:#4d4d4d;background:#ececec;border-bottom:.5px solid rgba(0,0,0,.14);position:relative}
.twbar .lights{top:8px;left:10px;gap:7px}.twbar .lights b{width:12px;height:12px}
.tw pre{margin:0;padding:8px 10px 12px;font:10.5px/1.38 "SF Mono",ui-monospace,Menlo,monospace;white-space:pre}.tw pre i{font-style:normal;background:#000;color:#fff}
.nt{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:440px;display:flex;gap:11px;padding:12px 14px;border-radius:18px;background:rgba(246,246,248,.78);backdrop-filter:blur(30px) saturate(1.8);box-shadow:0 10px 30px rgba(0,0,0,.22),0 0 0 .5px rgba(0,0,0,.12);color:#1d1d1f}
[data-theme=dark] .nt{background:rgba(44,44,48,.78);color:#f2f2f7;box-shadow:0 10px 30px rgba(0,0,0,.45),0 0 0 .5px rgba(255,255,255,.12)}
.nt img{width:34px;height:34px;border-radius:8px;flex:none}.nth{display:flex;justify-content:space-between;font-size:13px}.nth span{color:#8e8e93;font-size:12px}.nt p{margin:2px 0 0;font-size:13px;line-height:1.35}
</style></head><body><span id="wordmark">Switch</span>
<div id="bento">
<div class="row" style="grid-template-columns:1.9fr 1fr">
${figure(`<div class="win">${lights}<img src="${url(theme === 'dark' ? 'ins-frame-dark.webp' : 'overview-tall-light.webp')}"></div>`, 'Beautifully native.', 'A real Mac app, not a web page.')}
${figure(`<div class="pop"><img src="${url(`menubar-${theme}.webp`)}"></div>`, 'Limits at a glance.', 'Session and weekly use, in the menu bar.').replace('class="tile"', 'class="tile plain"')}
</div>
<div class="row" style="grid-template-columns:1fr 1.9fr">
${figure(`<div class="tw"><div class="twbar">${lights}<span>switch — 80×24</span></div><pre>${accounts}</pre></div>`, 'Also in the terminal.', 'Same accounts on macOS and Linux.')}
${figure(`<div class="nt"><img src="${url('icon-256.webp')}"><div><div class="nth"><b>Switch</b><span>now</span></div><p>${autoSwitch}</p></div></div>`, 'Switches before you run out.', 'Auto switch moves to an account with room left.')}
</div></div></body></html>`;

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'switch-readme-art-'));
  const browser = await chromium.launch({ ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
  try {
    for (const theme of ['light', 'dark']) {
      const html = path.join(tmp, `${theme}.html`);
      fs.writeFileSync(html, page(theme));
      const tab = await browser.newPage({ viewport: { width: 1000, height: 1200 }, deviceScaleFactor: 2, colorScheme: theme });
      const failed = [];
      tab.on('requestfailed', (request) => failed.push(request.url()));
      await tab.goto('file://' + html, { waitUntil: 'load' });
      await tab.evaluate(() => document.fonts.ready);
      assert(await tab.evaluate(() => document.fonts.check('800 144px Jost')), 'Jost did not load');
      assert.equal(await tab.locator('img').evaluateAll((images) => images.filter((image) => !image.naturalWidth).length), 0, 'An image did not load');
      assert.deepEqual(failed, []);
      await tab.locator('#wordmark').screenshot({ path: path.join(out, `wordmark-${theme}.png`), omitBackground: true });
      const png = path.join(tmp, `bento-${theme}.png`);
      await tab.locator('#bento').screenshot({ path: png, omitBackground: true });
      execFileSync('cwebp', ['-quiet', '-q', '88', '-alpha_q', '100', png, '-o', path.join(out, `bento-${theme}.webp`)]);
      await tab.close();
    }
    execFileSync('magick', [path.join(src, 'icon-256.webp'), path.join(out, 'icon-light.png')]);
    execFileSync('magick', [path.join(src, 'icon-dark-512.webp'), '-resize', '256x256', path.join(out, 'icon-dark.png')]);
  } finally {
    await browser.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  console.log(fs.readdirSync(out).map((file) => `${file} ${fs.statSync(path.join(out, file)).size}`).join('\n'));
})().catch((error) => { console.error(error); process.exitCode = 1; });
