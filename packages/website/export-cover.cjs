// Capture the website's real hero demo. Run on the rendering host.
// node packages/website/export-cover.cjs [output.png] [--gif]
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { execFileSync } = require('node:child_process');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || '../mac-gui/ui-lint/node_modules/playwright');

(async () => {
  const output = path.resolve(process.argv.find(arg => arg.endsWith('.png')) || path.join(__dirname, '../../docs/screenshots/cover-smooth.png'));
  const frames = process.argv.includes('--gif') ? await fs.mkdtemp(path.join(path.dirname(output), '.cover-frames-')) : null;
  // Chrome screenshot capture can interrupt an active screencast. Finish the still first.
  if (frames) execFileSync(process.execPath, [__filename, output], { stdio: 'inherit', timeout: 30000 });
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}),
  });
  let completed = false;
  try {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1360 }, deviceScaleFactor: 1 });
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
      body > :not(.page):not(svg), .page > :not([data-g="top"]), .h-badge, .h-cta, .h-meta, .strip { display: none !important; }
      .page { width: 1600px; max-width: none; height: 1360px; padding: 0 120px; background: #F2F2F4; border-radius: 6px; overflow: hidden; }
      .hero { padding-top: 150px; animation: none; }
      .h-t { font-size: 56px; font-weight: 600; letter-spacing: -.035em; color: #111; }
      .h-t .hw, .h-t .g { color: #111; font-weight: 600; }
      .h-sub { margin-top: 16px; font-size: 18px; color: #6B6B70; }
      .desk { --fit: 1360px; margin-top: 56px; height: 860px; border-radius: 26px; box-shadow: none; animation: none; }
      .dk-win { top: 60px; width: 900px; }
    ` });
    await page.evaluate(async () => {
      await document.fonts.ready;
      document.querySelector('.h-sub').textContent = 'Account switching and usage for your coding tools.';
      await Promise.all([...document.querySelectorAll('[data-g="top"] img')].map(img => img.decode()));
    });
    const bounds = await page.evaluate(() => {
      const rect = selector => {
        const { x, y, width, height } = document.querySelector(selector).getBoundingClientRect();
        return { x, y, width, height };
      };
      return { title: rect('.h-t'), desk: rect('.desk'), window: rect('.dk-win') };
    });
    for (const box of Object.values(bounds)) {
      assert(box.x >= 0 && box.y >= 0 && box.x + box.width <= 1600 && box.y + box.height <= 1360, `Cover content must fit the complete frame: ${JSON.stringify(bounds)}`);
    }
    assert(bounds.title.y >= 150 && 1360 - bounds.desk.y - bounds.desk.height >= 130, 'The cover must keep generous vertical space');
    assert(bounds.desk.width >= 1360 && bounds.window.width >= 900, 'The desktop and app must stay larger than the previous cover');
    for (const box of [bounds.window]) {
      assert(box.x >= bounds.desk.x && box.x + box.width <= bounds.desk.x + bounds.desk.width && box.y + box.height <= bounds.desk.y + bounds.desk.height, 'The desktop must contain the complete window and popover');
    }
    assert.equal(await page.locator('.hero').isVisible(), true);
    assert.equal(await page.locator('.page').evaluate(el => getComputedStyle(el).borderRadius), '6px');
    if (frames) {
      const mask = path.join(frames, 'mask.png');
      await fs.copyFile(output, mask);
      const capture = await page.context().newCDPSession(page);
      const captured = [];
      const writes = [];
      capture.on('Page.screencastFrame', ({ data, metadata, sessionId }) => {
        capture.send('Page.screencastFrameAck', { sessionId }).catch(() => {});
        const file = `${String(captured.length).padStart(4, '0')}.png`;
        captured.push({ file, time: metadata.timestamp });
        writes.push(fs.writeFile(path.join(frames, file), Buffer.from(data, 'base64')));
      });
      const start = Date.now();
      await page.evaluate(() => window.heroStart());
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await capture.send('Page.startScreencast', { format: 'png', maxWidth: 1200, maxHeight: 1020, everyNthFrame: 1 });
      let still = false;
      while (Date.now() - start < 10800) {
        const elapsed = Date.now() - start;
        // Return the closed menu's account to the first frame before the loop ends.
        if (elapsed >= 9500) await page.evaluate(() => { if (!document.querySelector('.desk').classList.contains('open') && window.K.state[0] !== 0) window.K.pick(0, 0); });
        if (!still && elapsed >= 5000) {
          const popover = await page.locator('.dk-pop').boundingBox();
          assert(popover.x >= bounds.desk.x && popover.x + popover.width <= bounds.desk.x + bounds.desk.width && popover.y + popover.height <= bounds.desk.y + bounds.desk.height, 'The expanded popover must fit inside the desktop');
          still = true;
        }
        await page.waitForTimeout(100);
      }
      const state = await page.evaluate(() => ({ account: window.K.state[0], open: document.querySelector('.desk').classList.contains('open') }));
      assert.equal(state.account, 0);
      assert.equal(state.open, false);
      await capture.send('Page.stopScreencast');
      await Promise.all(writes);
      const first = captured[0].time;
      const capturedSpan = captured.at(-1).time - first;
      const movingFrames = captured.filter(frame => frame.time >= first + 1 && frame.time < first + 2).length;
      console.log(JSON.stringify({ captured: captured.length, capturedSpan, movingFramesInOneSecond: movingFrames, firstFrame: path.join(frames, captured[0].file) }));
      assert(capturedSpan >= 9.5, 'The screencast must cover the complete interaction before its final rest');
      assert(movingFrames >= 25, 'The lossless recording must capture at least 25 real frames during one second of pointer motion');
      const timeline = captured.map((frame, index) => `file ${frame.file}\nduration ${Math.max(0.001, (captured[index + 1]?.time ?? first + 10.8) - frame.time)}`).join('\n');
      const input = path.join(frames, 'frames.ffconcat');
      await fs.writeFile(input, `ffconcat version 1.0\n${timeline}\nfile ${captured.at(-1).file}\n`);
      const gif = output.replace(/\.png$/, '.gif');
      const raw = path.join(frames, 'full.gif');
      execFileSync('ffmpeg', ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', input, '-loop', '1', '-framerate', '25', '-t', '10.8', '-i', mask, '-filter_complex', '[0:v]fps=25,format=rgb24[v];[1:v]scale=1200:1020,format=rgba,alphaextract[m];[v][m]alphamerge=shortest=1,format=rgba,split[a][b];[a]palettegen=max_colors=192:reserve_transparent=1[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:alpha_threshold=128', '-t', '10.8', '-loop', '0', raw], { timeout: 60000 });
      const checkAlpha = file => {
        const rgba = execFileSync('ffmpeg', ['-nostdin', '-v', 'error', '-i', file, '-frames:v', '1', '-vf', 'crop=51:51:0:0,format=rgba', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-'], { timeout: 30000 });
        assert(rgba[3] === 0 && rgba.at(-1) === 255, `The GIF must keep transparent corners and an opaque cover background: ${file} (${rgba[3]}, ${rgba.at(-1)})`);
      };
      checkAlpha(raw);
      execFileSync(process.env.GIFSICLE_PATH || 'gifsicle', ['-O3', '--careful', raw, '-o', gif], { timeout: 60000 });
      checkAlpha(gif);
      const duration = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', gif], { encoding: 'utf8' }).trim());
      assert(Math.abs(duration - 10.8) < 0.1, `The encoded GIF must preserve the complete 10.8-second recording, received ${duration}`);
      assert((await fs.stat(gif)).size < 5 * 1024 * 1024, 'The README animation must stay below 5 MiB');
      console.log(JSON.stringify({ output, gif, fps: 25, captured: captured.length, capturedSpan, movingFramesInOneSecond: movingFrames, duration, bytes: (await fs.stat(gif)).size, bounds }));
    } else {
      await page.evaluate(() => window.heroStart());
      await page.waitForTimeout(5000);
      await page.screenshot({ path: output, omitBackground: true });
      console.log(JSON.stringify({ output, bounds }));
    }
    completed = true;
  } finally {
    await browser.close();
    if (frames && completed) await fs.rm(frames, { recursive: true, force: true });
    else if (frames) console.error(`Failed capture retained at ${frames}`);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
