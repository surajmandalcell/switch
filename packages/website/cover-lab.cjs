const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');

const mediaDir = path.resolve(__dirname, '../../docs/screenshots');
const png = fs.readFileSync(path.join(mediaDir, 'cover-monument.png'));
const gif = fs.readFileSync(path.join(mediaDir, 'cover-monument.gif'));
assert(png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])), 'Expected the final Monument PNG');
assert(['GIF87a', 'GIF89a'].includes(gif.toString('ascii', 0, 6)), 'Expected the final Monument GIF');
const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
assert(width > 0 && height > 0 && width <= 10000 && height <= 10000, 'Invalid cover dimensions');
const gifWidth = gif.readUInt16LE(6), gifHeight = gif.readUInt16LE(8);
assert(gifWidth > 0 && gifHeight > 0 && Math.abs(gifHeight - gifWidth * height / width) <= 1, 'Final cover aspect ratios must match');

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Final cover · Monument</title>
<style>
*{box-sizing:border-box}html{color-scheme:light dark;--paper:#f5f5f7;--ink:#1d1d1f;--secondary:#6e6e73;--line:rgba(0,0,0,.1);--glass:rgba(250,250,252,.85);--blue:#007aff}body{margin:0;padding:28px 28px 100px;background:var(--paper);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,system-ui,sans-serif}header{display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:22px}h1{margin:0;font-size:24px;letter-spacing:-.025em;font-weight:650}p{margin:6px 0 0;color:var(--secondary);font-size:13px}nav{display:flex;gap:18px}a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}main img{display:block;width:100%;height:auto;object-fit:contain;background:transparent;border:0;border-radius:0}.dock{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);display:flex;gap:4px;padding:5px;border:1px solid var(--line);border-radius:28px;background:var(--glass);backdrop-filter:blur(24px) saturate(1.8);-webkit-backdrop-filter:blur(24px) saturate(1.8);box-shadow:0 7px 28px rgba(0,0,0,.14)}button{font:inherit;font-weight:500;border:0;border-radius:22px;padding:10px 20px;color:var(--ink);background:transparent;cursor:pointer}button[aria-pressed=true]{background:var(--blue);color:white}button:focus-visible,a:focus-visible{outline:2px solid var(--blue);outline-offset:3px}@media(prefers-color-scheme:dark){html{--paper:#111113;--ink:#f5f5f7;--secondary:#aeaeb2;--line:rgba(255,255,255,.12);--glass:rgba(37,37,40,.87)}}@media(max-width:600px){body{padding:20px 12px 90px}header{margin-bottom:16px}h1{font-size:21px}nav{font-size:13px}}
button:focus-visible,a:focus-visible{outline:none}button:focus-visible{background:rgba(120,120,128,.24)}button[aria-pressed=true]:focus-visible{background:#005fc4}a:focus-visible{text-decoration:underline}
</style></head><body>
<header><div><h1>Final cover · Monument</h1><p>Jost · 170px wordmark · 800 weight · 36px subtitle</p></div><nav aria-label="Download final cover"><a id="png" download="cover-monument.png">Download PNG</a><a id="gif" download="cover-monument.gif">Download GIF</a></nav></header>
<main><img id="cover" width="${width}" height="${height}" alt="Switch. Coding accounts and usage. Right in your menu bar. The Switch app appears in a desktop window below."></main>
<div class="dock" role="group" aria-label="Cover playback"><button id="animation" aria-pressed="false">Animation</button><button id="still" aria-pressed="false">Still</button></div>
<script>
const png='data:image/png;base64,${png.toString('base64')}',gif='data:image/gif;base64,${gif.toString('base64')}';
const cover=document.getElementById('cover'),animation=document.getElementById('animation'),still=document.getElementById('still');
document.getElementById('png').href=png;document.getElementById('gif').href=gif;
function showAnimation(active){cover.src=active?gif:png;animation.setAttribute('aria-pressed',String(active));still.setAttribute('aria-pressed',String(!active))}
animation.addEventListener('click',()=>showAnimation(true));still.addEventListener('click',()=>showAnimation(false));
const reducedMotion=matchMedia('(prefers-reduced-motion: reduce)');showAnimation(!reducedMotion.matches);reducedMotion.addEventListener('change',event=>{if(event.matches)showAnimation(false)});
</script></body></html>`;
new vm.Script(html.match(/<script>\n([\s\S]*?)<\/script>/)[1]);
const destination = path.resolve(process.argv.find(arg => arg.endsWith('.html')) || '/Volumes/External1TB/data/_custom/codex/switch/previews/cover-lab/index.html');
fs.mkdirSync(path.dirname(destination), { recursive: true });
fs.writeFileSync(`${destination}.new`, html);
fs.renameSync(`${destination}.new`, destination);
console.log(JSON.stringify({ destination, width, height, bytes: Buffer.byteLength(html) }));

if (process.argv.includes('--serve')) {
  const server = http.createServer((request, response) => {
    const route = request.url.split('?')[0];
    if (request.method === 'GET' && route === '/favicon.ico') { response.writeHead(204).end(); return; }
    if (request.method !== 'GET' || !['/', '/index.html'].includes(route)) { response.writeHead(404).end('Not found'); return; }
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    fs.createReadStream(destination).pipe(response);
  });
  server.listen(8847, '127.0.0.1', () => console.log('Final cover: http://127.0.0.1:8847 (8-hour limit)'));
  setTimeout(() => server.close(), 8 * 60 * 60 * 1000).unref();
  process.on('SIGINT', () => server.close());
  process.on('SIGTERM', () => server.close());
}
