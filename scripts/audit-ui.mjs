import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const browserExecutable = process.env.BROWSER;
const appUrl = process.env.APP_URL ?? 'http://127.0.0.1:4174/';
const siteUrl = process.env.SITE_URL ?? 'http://127.0.0.1:4173/';
const output = path.resolve(process.env.OUTPUT_DIR ?? 'ui-audit');

if (!browserExecutable) throw new Error('BROWSER must point to a Chromium-compatible executable.');
await mkdir(output, { recursive: true });

const results = [];
const failures = [];
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

class CdpClient {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.errors = [];
    socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const request = this.pending.get(message.id);
        if (!request) return;
        this.pending.delete(message.id);
        if (message.error) request.reject(new Error(JSON.stringify(message.error)));
        else request.resolve(message.result);
        return;
      }
      if (message.method === 'Runtime.exceptionThrown') {
        this.errors.push(message.params.exceptionDetails?.exception?.description ?? message.params.exceptionDetails?.text ?? 'Runtime exception');
      }
      if (message.method === 'Log.entryAdded' && message.params.entry?.level === 'error') {
        this.errors.push(message.params.entry.text);
      }
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  async value(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text ?? 'Evaluation failed');
    }
    return result.result.value;
  }
}

async function launch(url, width, height, port) {
  const browser = spawn(browserExecutable, [
    '--headless=new',
    '--no-sandbox',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--disable-background-networking',
    '--disable-default-apps',
    '--no-first-run',
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${process.env.RUNNER_TEMP ?? '/tmp'}/spi-chrome-${port}`,
    `--window-size=${width},${height}`,
    url,
  ], { stdio: ['ignore', 'ignore', 'ignore'] });

  let target;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const list = await fetch(`http://127.0.0.1:${port}/json/list`).then((response) => response.json());
      target = list.find((item) => item.type === 'page');
      if (target) break;
    } catch {}
    await sleep(100);
  }

  if (!target) {
    browser.kill('SIGKILL');
    throw new Error(`Chrome target did not start for ${url}`);
  }

  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });

  const client = new CdpClient(socket);
  await client.send('Page.enable');
  await client.send('Runtime.enable');
  await client.send('Log.enable');
  await client.send('Emulation.setDeviceMetricsOverride', {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: width < 600,
  });
  await client.send('Page.reload', { ignoreCache: true });
  await sleep(1400);
  await client.value('document.fonts.ready.then(() => true)');
  return { browser, client, socket };
}

async function screenshot(client, name, fullPage = false) {
  let clip;
  if (fullPage) {
    const metrics = await client.send('Page.getLayoutMetrics');
    const width = Math.ceil(metrics.cssContentSize?.width ?? metrics.contentSize.width);
    const height = Math.min(12000, Math.ceil(metrics.cssContentSize?.height ?? metrics.contentSize.height));
    clip = { x: 0, y: 0, width, height, scale: 1 };
  }

  const capture = await client.send('Page.captureScreenshot', {
    format: 'png',
    fromSurface: true,
    captureBeyondViewport: fullPage,
    ...(clip ? { clip } : {}),
  });
  await writeFile(path.join(output, `${name}.png`), Buffer.from(capture.data, 'base64'));
}

async function close(runtime) {
  runtime.socket.close();
  runtime.browser.kill('SIGKILL');
  await sleep(100);
}

async function auditSite(width, height, label, port) {
  let runtime;
  try {
    runtime = await launch(siteUrl, width, height, port);
    const data = await runtime.client.value(`(() => ({
      title: document.title,
      heading: document.querySelector('h1')?.textContent?.trim(),
      overflow: document.documentElement.scrollWidth > window.innerWidth,
      sections: document.querySelectorAll('main section').length,
      plex: document.fonts.check('16px "IBM Plex Sans"'),
      text: document.body.innerText,
      headerHeight: document.querySelector('.site-header')?.getBoundingClientRect().height,
    }))()`);

    if (!data.title.includes('Subscription Proxy Inator') || !data.heading) throw new Error('Missing site identity.');
    if (data.overflow) throw new Error('Horizontal site overflow.');
    if (data.sections < 5 || !data.plex) throw new Error('Incomplete site or IBM Plex did not load.');
    if (data.headerHeight < 48 || data.headerHeight > 80) throw new Error(`Unexpected header height ${data.headerHeight}.`);
    for (const prohibited of ['1,284', '99.4%', '$18.42', 'Good afternoon', 'Automatic failover in 84 ms']) {
      if (data.text.includes(prohibited)) throw new Error(`Fabricated site content found: ${prohibited}`);
    }

    await screenshot(runtime.client, `site-${label}`, true);
    if (runtime.client.errors.length) throw new Error(`Console errors: ${runtime.client.errors.join('; ')}`);
    results.push({ surface: 'site', label, width, height, heading: data.heading, sections: data.sections, overflow: false, plex: true });
  } catch (error) {
    failures.push({ surface: 'site', label, width, height, error: error.message });
    if (runtime) await screenshot(runtime.client, `site-${label}-failure`, true).catch(() => {});
  } finally {
    if (runtime) await close(runtime);
  }
}

async function auditApp(width, height, label, port) {
  let runtime;
  try {
    runtime = await launch(appUrl, width, height, port);
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const ready = await runtime.client.value(`Boolean(document.querySelector('.nav-item') && document.querySelector('.page-header h1'))`);
      if (ready) break;
      await sleep(100);
    }

    const pages = await runtime.client.value(`[...document.querySelectorAll('.nav-item')].map((button) => button.textContent.trim())`);
    if (pages.length !== 7) throw new Error(`Expected seven desktop sections, received ${pages.length}.`);

    const visited = [];
    for (let index = 0; index < pages.length; index += 1) {
      await runtime.client.value(`document.querySelectorAll('.nav-item')[${index}].click()`);
      await sleep(300);
      const state = await runtime.client.value(`(() => {
        const textElements = [...document.querySelectorAll('.content-frame *')].filter((node) => {
          const style = getComputedStyle(node);
          const rect = node.getBoundingClientRect();
          const hasDirectText = [...node.childNodes].some((child) => child.nodeType === Node.TEXT_NODE && child.textContent.trim());
          return hasDirectText && rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
        });
        const sizes = textElements.map((node) => Number.parseFloat(getComputedStyle(node).fontSize)).filter(Number.isFinite);
        const minText = sizes.length ? Math.min(...sizes) : 99;
        const controls = [...document.querySelectorAll('.content-frame input, .content-frame select, .content-frame textarea, .content-frame .primary-button, .content-frame .secondary-button')]
          .filter((node) => node.getBoundingClientRect().width > 0 && node.getBoundingClientRect().height > 0);
        const shortControls = controls.filter((node) => node.getBoundingClientRect().height < 39);
        return {
          title: document.querySelector('.page-header h1')?.textContent?.trim(),
          overflow: document.documentElement.scrollWidth > window.innerWidth,
          minText,
          shortControls: shortControls.length,
          controls: controls.length,
        };
      })()`);

      if (!state.title) throw new Error(`${pages[index]} did not render a page title.`);
      if (state.overflow) throw new Error(`${pages[index]} caused horizontal application overflow.`);
      if (state.minText < 12) throw new Error(`${pages[index]} rendered ${state.minText}px text.`);
      if (state.shortControls) throw new Error(`${pages[index]} rendered ${state.shortControls} undersized controls.`);

      visited.push({ navigation: pages[index], title: state.title, minText: state.minText, controls: state.controls });
      if ((label === 'wide' && ['Overview', 'Providers', 'Routing', 'Usage'].includes(pages[index])) || (index === 0 && label !== 'wide')) {
        const slug = pages[index].toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
        await screenshot(runtime.client, `app-${label}-${slug}`);
      }
    }

    if (runtime.client.errors.length) throw new Error(`Console errors: ${runtime.client.errors.join('; ')}`);
    results.push({ surface: 'app', label, width, height, sections: visited, overflow: false });
  } catch (error) {
    failures.push({ surface: 'app', label, width, height, error: error.message });
    if (runtime) await screenshot(runtime.client, `app-${label}-failure`).catch(() => {});
  } finally {
    if (runtime) await close(runtime);
  }
}

let port = 9300;
for (const [width, height, label] of [[1440, 900, 'wide'], [1040, 800, 'medium'], [800, 760, 'tablet'], [620, 760, 'compact']]) {
  await auditApp(width, height, label, port++);
}
for (const [width, height, label] of [[1440, 1000, 'wide'], [840, 900, 'tablet'], [390, 844, 'mobile']]) {
  await auditSite(width, height, label, port++);
}

await writeFile(path.join(output, 'audit.json'), `${JSON.stringify({ results, failures }, null, 2)}\n`);
if (failures.length) throw new Error(`UI audit failed: ${JSON.stringify(failures)}`);
console.log(`UI audit passed for ${results.length} viewport surfaces.`);
