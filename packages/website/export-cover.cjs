// Capture the real website hero. Run on the rendering host, not the owner's desktop.
// node packages/website/export-cover.cjs [output.png]
// PLAYWRIGHT_MODULE can point to an existing Playwright installation.
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '../mac-gui/ui-lint/node_modules/playwright');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}),
  });
  try {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1, reducedMotion: 'reduce' });
    page.setDefaultTimeout(15000);
    // Keep the website's components in their initial state without starting demo loops.
    await page.addInitScript(() => {
      window.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
    });
    await page.goto(pathToFileURL(path.join(__dirname, 'public/index.html')).href);
    await page.locator('.dk-pop .kp-row').first().waitFor({ state: 'attached' });
    await page.addStyleTag({ content: `
      body > :not(.page):not(svg), .page > :not([data-g="top"]),
      .h-badge, .h-cta, .h-meta, .strip, .dk-cur { display: none !important; }
      *, *::before, *::after { animation: none !important; transition: none !important; }
      .hero { padding-top: 38px; }
      .h-t { font-size: 64px; letter-spacing: -.04em; color: var(--ink2); }
      .h-sub { margin-top: 16px; }
      .desk { margin-top: 28px; height: 740px; }
      .dk-win { top: 44px; }
      .dk-pop { opacity: 1; }
    ` });
    await page.evaluate(async () => {
      await document.fonts.ready;
      document.querySelector('.h-sub').textContent = 'Account switching and usage for your coding tools.';
      await Promise.all([...document.querySelectorAll('[data-g="top"] img')].map(img => img.decode()));
      const desk = document.querySelector('.desk');
      const pop = desk.querySelector('.dk-pop');
      const status = desk.querySelector('.mb-st');
      pop.style.left = `${Math.min(desk.clientWidth - pop.offsetWidth - 8, status.offsetLeft + status.offsetWidth / 2 - pop.offsetWidth / 2)}px`;
      status.classList.add('on');
    });
    const bounds = await page.evaluate(() => {
      const rect = selector => {
        const { x, y, width, height } = document.querySelector(selector).getBoundingClientRect();
        return { x, y, width, height };
      };
      return { desk: rect('.desk'), window: rect('.dk-win'), popover: rect('.dk-pop') };
    });
    for (const box of Object.values(bounds)) {
      assert(box.x >= 0 && box.y >= 0 && box.x + box.width <= 1600 && box.y + box.height <= 1000, `Cover content must fit the complete frame: ${JSON.stringify(bounds)}`);
    }
    for (const box of [bounds.window, bounds.popover]) {
      assert(box.x >= bounds.desk.x && box.x + box.width <= bounds.desk.x + bounds.desk.width && box.y + box.height <= bounds.desk.y + bounds.desk.height, 'The desktop must contain the complete window and popover');
    }
    const colors = await page.evaluate(() => Object.fromEntries(['body', '.h-t', '.hw', '.h-sub'].map(selector => [selector, { color: getComputedStyle(document.querySelector(selector)).color, background: getComputedStyle(document.querySelector(selector)).backgroundColor }])));
    const output = path.resolve(process.argv[2] || path.join(__dirname, '../../docs/screenshots/cover.png'));
    await page.screenshot({ path: output, animations: 'disabled' });
    console.log(JSON.stringify({ output, width: 1600, height: 1000, bounds, colors }));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
