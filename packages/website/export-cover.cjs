// Capture the website's real hero demo. Run on the rendering host.
// node packages/website/export-cover.cjs [output.png] [--gif]
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { execFileSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '../mac-gui/ui-lint/node_modules/playwright');

(async () => {
  const output = path.resolve(process.argv.find(arg => arg.endsWith('.png')) || path.join(__dirname, '../../docs/screenshots/cover-demo.png'));
  const frames = process.argv.includes('--gif') ? await fs.mkdtemp(path.join(path.dirname(output), '.cover-frames-')) : null;
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}),
  });
  try {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1160 }, deviceScaleFactor: 1 });
    page.setDefaultTimeout(15000);
    // Start only the hero's existing demo after the export layout is ready.
    await page.addInitScript(() => {
      window.heroStart = null;
      window.IntersectionObserver = class {
        constructor(callback) { this.callback = callback; }
        observe(element) { if (element.matches('[data-desk]')) window.heroStart = () => this.callback([{ isIntersecting: true }]); }
        unobserve() {}
        disconnect() {}
      };
    });
    await page.goto(pathToFileURL(path.join(__dirname, 'public/index.html')).href);
    await page.locator('.dk-pop .kp-row').first().waitFor({ state: 'attached' });
    await page.addStyleTag({ content: `
      html, body { background: transparent !important; }
      body > :not(.page):not(svg), .page > :not([data-g="top"]), .hero, .strip { display: none !important; }
      .page { max-width: 1416px; padding-top: 160px; }
      .desk { --fit: 1360px; margin-top: 0; height: 860px; border-radius: 6px; box-shadow: none; animation: none; }
      .dk-win { top: 60px; width: 900px; }
    ` });
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.all([...document.querySelectorAll('[data-g="top"] img')].map(img => img.decode()));
    });
    const bounds = await page.evaluate(() => {
      const rect = selector => {
        const { x, y, width, height } = document.querySelector(selector).getBoundingClientRect();
        return { x, y, width, height };
      };
      return { desk: rect('.desk'), window: rect('.dk-win') };
    });
    for (const box of Object.values(bounds)) {
      assert(box.x >= 0 && box.y >= 0 && box.x + box.width <= 1600 && box.y + box.height <= 1160, `Cover content must fit the complete frame: ${JSON.stringify(bounds)}`);
    }
    assert(bounds.desk.y >= 160 && 1160 - bounds.desk.y - bounds.desk.height >= 140, 'The transparent canvas must keep generous vertical space');
    assert(bounds.desk.width >= 1360 && bounds.window.width >= 900, 'The desktop and app must stay larger than the previous cover');
    for (const box of [bounds.window]) {
      assert(box.x >= bounds.desk.x && box.x + box.width <= bounds.desk.x + bounds.desk.width && box.y + box.height <= bounds.desk.y + bounds.desk.height, 'The desktop must contain the complete window and popover');
    }
    assert.equal(await page.locator('.hero').isVisible(), false);
    assert.equal(await page.locator('.desk').evaluate(el => getComputedStyle(el).borderRadius), '6px');
    await page.evaluate(() => window.heroStart());
    if (frames) {
      const start = Date.now();
      let count = 0;
      let still = false;
      while (Date.now() - start < 10800) {
        const elapsed = Date.now() - start;
        // Return the closed menu's account to the first frame before the loop ends.
        if (elapsed >= 9500) await page.evaluate(() => { if (!document.querySelector('.desk').classList.contains('open') && window.K.state[0] !== 0) window.K.pick(0, 0); });
        const frame = path.join(frames, `${String(count++).padStart(4, '0')}.png`);
        await page.screenshot({ path: frame, omitBackground: true });
        if (!still && elapsed >= 5000) {
          const popover = await page.locator('.dk-pop').boundingBox();
          assert(popover.x >= bounds.desk.x && popover.x + popover.width <= bounds.desk.x + bounds.desk.width && popover.y + popover.height <= bounds.desk.y + bounds.desk.height, 'The expanded popover must fit inside the desktop');
          await fs.copyFile(frame, output);
          still = true;
        }
        const delay = count * 100 - (Date.now() - start);
        if (delay > 0) await new Promise(resolve => setTimeout(resolve, delay));
      }
      const state = await page.evaluate(() => ({ account: window.K.state[0], open: document.querySelector('.desk').classList.contains('open') }));
      assert.equal(state.account, 0);
      assert.equal(state.open, false);
      const gif = output.replace(/\.png$/, '.gif');
      const raw = path.join(frames, 'full.gif');
      execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-framerate', String(count / 10.8), '-i', path.join(frames, '%04d.png'), '-filter_complex', 'fps=10,scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:reserve_transparent=1[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:alpha_threshold=128', '-loop', '0', raw], { timeout: 60000 });
      execFileSync('magick', [raw, '-coalesce', '-layers', 'Optimize', gif], { timeout: 60000, env: { ...process.env, MAGICK_TEMPORARY_PATH: frames } });
      assert((await fs.stat(gif)).size < 5 * 1024 * 1024, 'The README animation must stay below 5 MiB');
      console.log(JSON.stringify({ output, gif, frames: count, duration: 10.8, bytes: (await fs.stat(gif)).size, bounds }));
    } else {
      await page.waitForTimeout(5000);
      await page.screenshot({ path: output, omitBackground: true });
      console.log(JSON.stringify({ output, bounds }));
    }
  } finally {
    await browser.close();
    if (frames) await fs.rm(frames, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
