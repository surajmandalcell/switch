const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const publicDir = path.join(__dirname, 'public');
const output = path.resolve(process.argv.find(arg => arg.endsWith('.html')) || '/Volumes/External1TB/data/_custom/codex/switch/previews/website-copy/index.html');
const choices = [
  { name: 'Accounts first', title: 'Switch: AI coding accounts in your menu bar', hero: '<em class="hw">Switch AI coding accounts.</em><span class="g">From your menu bar.</span>', subtitle: "Save logins for Claude Code, Codex, and other tools. Check usage and choose an account from your Mac's menu bar.", description: 'Switch is a free, open-source Mac app for saved AI coding accounts. Check usage and choose supported logins from your menu bar.' },
  { name: 'Switching first', title: 'Switch: change saved coding accounts', hero: '<em class="hw">Change coding accounts.</em><span class="g">Keep your local conversations.</span>', subtitle: 'Keep saved logins for your coding tools. Choose another supported account when you need it.', description: "Change coding accounts and keep your local conversations. Save logins for supported tools and check usage from your Mac's menu bar." },
  { name: 'Usage first', title: 'Switch: AI usage and saved coding accounts', hero: '<em class="hw">Track AI usage.</em><span class="g">Choose your next account.</span>', subtitle: 'See limits, reset times, and token use for saved accounts. Choose which supported account your coding tool uses.', description: 'Check limits, reset times, and token use for saved AI coding accounts. Switch is a native Mac app with a Mac and Linux CLI.' },
];
const fields = [];
function field(selector, values, attribute) {
  fields.push({ selector, values: Array.isArray(values) ? values : [values, values, values], attribute });
}
field('.h-t', choices.map(choice => choice.hero));
field('.h-sub', choices.map(choice => choice.subtitle));
field('.h-badge > span:last-child', 'For Claude Code, Codex, and more');
field('#nav nav a[href="#speed"]', 'Performance');
field('#nav nav a[href="#features"]', ['Accounts', 'Switching', 'Usage']);
field('#nav nav a[href="#tools"]', 'Tools');
field('#nav nav a[href="#safety"]', 'Logins');
field('#nav nav a[href="#faq"]', 'FAQ');
field('[data-g="speed"] .sh h2', 'A small native app. <span>Light on memory.</span>');
field('[data-card="speed"] .pf-cap', 'No Electron or web views. The interface uses native Mac controls.');
field('[data-card="dl"] .pf-cap', 'Download one signed, Apple-notarized ZIP.');
field('[data-g="features"] .sh h2', ['Your accounts. <span>Grouped by tool.</span>', 'Use a saved login. <span>Keep your local work.</span>', 'Usage and accounts. <span>In one view.</span>']);
field('.t.m .mcopy h3', ['Check usage from the menu bar', 'Choose an account from the menu bar', 'See remaining usage in the menu bar']);
field('.t.m .mcopy > p', ["See the remaining limit for each tool's default account. The numbers update when you switch.", 'Keep a default account for each supported tool. Choose another saved login when you need it.', 'Check the current limit and reset time for each default account without opening its tool.']);
field('.t.a .lab h3', ['Switch to another saved account', 'Change to a saved login', 'Choose an account with room left']);
field('.t.a .lab > p', ['Select an account, then choose Switch.', 'Select an account, then choose Switch.', 'Check its usage, then choose Switch.']);
field('.t.b > h3', 'See limits and reset times');
field('.t.c > h3', 'Tools and providers');
field('.t.e .lab h3', 'Back up logins before switching');
field('.t.e .lab > p', 'Switch saves the outgoing login and backs up replaced data. Local settings and supported history stay in place.');
field('.t.h .lab h3', 'Get alerts when limits run low');
field('.t.h .lab > p', 'Choose another saved account before a usage window runs out.');
field('.t.f .lab h3', 'Hide account details on screen');
field('.t.f .lab > p', 'Replace email addresses with stable aliases when you share your screen.');
field('.t.g .lab h3', ['Track usage by account and model', 'See usage across saved accounts', 'Track tokens by account and model']);
field('.t.g .lab > p', 'See daily tokens, activity, account trends, and estimated API costs.');
field('[data-g="limits"] .sh h2', ['See limits and reset times. <span>Choose when to switch.</span>', 'Know when an account runs low. <span>Choose another login.</span>', 'Check each usage window. <span>See when it resets.</span>']);
field('[data-g="tools"] .sh h2', ['Find your tools <span>and providers.</span>', 'Switch supported tools. <span>Check provider usage.</span>', 'Check usage for <span>your tools and providers.</span>']);
field('[data-g="safety"] .sh h2', 'How Switch handles <span>your logins.</span>');
field('.safe > div:nth-child(1) h3', 'Sign in separately');
field('.safe > div:nth-child(1) p', 'New sign-ins use a private temporary home, separate from your active login.');
field('.safe > div:nth-child(2) h3', 'Save the previous login');
field('.safe > div:nth-child(2) p', 'Switch saves the old login and backs up data before replacing it.');
field('.safe > div:nth-child(3) h3', 'No Keychain or browser access');
field('.safe > div:nth-child(3) p', 'Switch does not read the macOS Keychain or browser cookie stores.');
field('.safe > div:nth-child(4) h3', 'Read the source');
field('.safe > div:nth-child(4) p', 'MIT licensed. The Mac download is signed and notarized.');
field('[data-g="terminal"] h2', 'Run Switch in your terminal');
field('[data-g="terminal"] > div:first-child > p', 'Use the same saved accounts from the command line.<br>Available on Mac and Linux. The npm package is Mac-only.');
field('[data-g="faq"] .q h2', 'Questions about Switch');
field('[data-g="faq"] .q p', 'For other questions, open an issue on GitHub.');
field('.bigicon > h2', 'Download Switch for Mac');
field('.bigicon > .bi-sub', ['Free and open source. Use multiple coding accounts from one native app.', 'Save logins, check usage, and choose an account from the menu bar.', 'See account limits and usage without opening the terminal.']);
field('.fbrand > div > span', ['Coding accounts and usage, in the menu bar.', 'Saved coding accounts, ready to switch.', 'Account limits and usage, in one view.']);
field('.fcols > div:first-child > h4', 'Downloads');
const faq = [
  ['Is Switch free?', 'Yes. Switch is free and open source under the MIT license.'],
  ['Does Switch work on Mac and Linux?', 'The Mac app requires macOS 14 or later on Apple silicon. The standalone CLI supports Linux x86_64 with glibc 2.38 or later. The npm package is for Apple Silicon Macs.'],
  ['How much CPU and memory does it use?', 'Switch is a native Swift app with no Electron or web views. It refreshes usage and sleeps between checks. In the published day-long measurement, it averaged 0.6% CPU and about 20 MB of idle memory.'],
  ['What changes when I switch accounts?', 'For supported tools, Switch updates the login while keeping local settings and workspace data in place. Some tools use separate account profiles. Other providers support usage checks without changing a coding tool login. Cloud history and attachments can still require the original account.'],
  ['What if a switch fails?', 'Switch backs up the previous login and replaced data. Failed changes have recovery options.'],
  ['Does Switch read Keychain or browser cookies?', 'No. Switch does not read the macOS Keychain or browser cookie stores. Providers that need a browser session accept a session value you paste.'],
  ['Do I need the terminal?', 'No. On Mac, you can use the app and menu bar. The optional CLI uses the same saved accounts; Linux uses the CLI.'],
];
faq.forEach(([question, answer], index) => {
  field(`[data-faq] details:nth-child(${index + 1}) summary`, question);
  field(`[data-faq] details:nth-child(${index + 1}) > p`, answer);
});
field('title', choices.map(choice => choice.title));
field('meta[name="description"]', choices.map(choice => choice.description), 'content');
field('meta[property="og:title"]', choices.map(choice => choice.title), 'content');
field('meta[property="og:description"]', choices.map(choice => choice.description), 'content');
assert(fields.length > 50 && fields.every(item => item.values.length === choices.length));

const css = `<style id="copy-preview-style">
#copy-dock{--cp-fill:rgba(249,249,251,.84);--cp-ink:#1d1d1f;--cp-line:rgba(0,0,0,.12);position:fixed;z-index:10000;right:14px;bottom:14px;padding:7px;border:1px solid var(--cp-line);border-radius:999px;background:var(--cp-fill);color:var(--cp-ink);box-shadow:0 7px 28px rgba(0,0,0,.15),inset 0 1px rgba(255,255,255,.7);backdrop-filter:blur(24px) saturate(1.8);-webkit-backdrop-filter:blur(24px) saturate(1.8);font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,system-ui,sans-serif}
#copy-dock *{box-sizing:border-box}#copy-dock .cp-row{display:flex;align-items:center;gap:7px}#copy-dock select{width:158px;min-width:0;border:0;border-radius:18px;padding:8px 24px 8px 11px;background:transparent;color:inherit;font:inherit}#copy-dock button{border:0;border-radius:18px;padding:8px 12px;background:transparent;color:inherit;cursor:pointer;font:inherit;white-space:nowrap}#copy-dock button[aria-pressed="true"]{color:#fff;background:#007aff;box-shadow:0 1px 3px rgba(0,0,0,.13)}#copy-dock .cp-segment{display:flex;gap:2px;padding:2px;background:rgba(120,120,128,.12);border-radius:20px}#copy-dock .cp-more{width:34px;height:34px;padding:0;font-size:21px}#copy-dock .cp-extra{position:absolute;right:0;bottom:62px;width:270px;border:1px solid var(--cp-line);border-radius:20px;padding:14px;background:var(--cp-fill);backdrop-filter:blur(24px) saturate(1.8);-webkit-backdrop-filter:blur(24px) saturate(1.8);box-shadow:0 7px 28px rgba(0,0,0,.15)}#copy-dock .cp-extra[hidden]{display:none}#copy-dock .cp-extra label{display:flex;gap:8px;align-items:center;margin-bottom:8px}#copy-dock .cp-extra button{display:block;width:100%;text-align:left;padding-left:0;color:#007aff}#copy-dock .cp-status{display:block;margin-top:7px;color:inherit;opacity:.65;font-size:11px}#copy-dock input{accent-color:#007aff}#copy-dock .cp-expand{display:none;width:34px;height:34px;padding:0}#copy-dock.cp-collapsed .cp-row{display:none}#copy-dock.cp-collapsed .cp-expand{display:block}.copy-highlight{outline:1px dashed #007aff!important;outline-offset:4px!important}body{padding-bottom:88px!important}
@media(prefers-color-scheme:dark){#copy-dock{--cp-fill:rgba(37,37,40,.88);--cp-ink:#f5f5f7;--cp-line:rgba(255,255,255,.17);box-shadow:0 7px 28px rgba(0,0,0,.35),inset 0 1px rgba(255,255,255,.08)}#copy-dock .cp-extra{box-shadow:0 7px 28px rgba(0,0,0,.35)}}@media(max-width:520px){#copy-dock{right:10px;bottom:10px;max-width:calc(100vw - 20px);padding:6px}#copy-dock select{width:132px;font-size:12px;padding-left:8px}#copy-dock button{padding:8px 10px;font-size:12px}#copy-dock .cp-row{gap:4px}#copy-dock .cp-more{width:29px}}
</style>`;
const dock = `<aside id="copy-dock" aria-label="Website copy preview"><div class="cp-row"><select id="copy-set" aria-label="Copy direction">${choices.map((choice, index) => `<option value="${index}">${choice.name}${index === 1 ? ' · Approved' : ''}</option>`).join('')}</select><div class="cp-segment" role="group" aria-label="Compare copy"><button id="copy-before" aria-pressed="false">Before</button><button id="copy-after" aria-pressed="true">After</button></div><button class="cp-more" id="copy-more" aria-expanded="false" aria-label="More preview controls">···</button></div><button class="cp-expand" id="copy-expand" aria-label="Show copy controls">Aa</button><div class="cp-extra" id="copy-extra" hidden><label><input id="copy-changes" type="checkbox">Show changed text</label><button id="copy-choice">Copy this choice</button><button id="copy-collapse">Hide controls</button><span class="cp-status" id="copy-status" role="status"></span></div></aside>`;
const data = JSON.stringify({ choices: choices.map(({ name }) => ({ name })), fields }).replace(/</g, '\\u003c');
const script = `<script id="copy-preview-data" type="application/json">${data}</script><script id="copy-preview-script">
(()=>{
 const data=JSON.parse(document.getElementById('copy-preview-data').textContent),dock=document.getElementById('copy-dock');
 const select=document.getElementById('copy-set'),before=document.getElementById('copy-before'),after=document.getElementById('copy-after'),extra=document.getElementById('copy-extra'),more=document.getElementById('copy-more'),status=document.getElementById('copy-status'),changes=document.getElementById('copy-changes');
 const storageKey='switch-website-copy-approved';
 let pick=1,mode='after',records=[];try{const saved=JSON.parse(localStorage.getItem(storageKey)||'{}');if(Number.isInteger(saved.pick)&&saved.pick>=0&&saved.pick<data.choices.length)pick=saved.pick;if(saved.mode==='before')mode=saved.mode}catch{}
 select.value=pick;
 const value=(record)=>record.attribute?record.node.getAttribute(record.attribute):record.node.innerHTML;
 const write=(record,text)=>record.attribute?record.node.setAttribute(record.attribute,text):record.node.innerHTML=text;
 const anchor=()=>[...document.querySelectorAll('.page>.grp')].map(node=>({node,top:node.getBoundingClientRect().top})).filter(item=>item.top<innerHeight&&item.node.getBoundingClientRect().bottom>100).sort((a,b)=>Math.abs(a.top-120)-Math.abs(b.top-120))[0];
 function paint(){const mark=anchor();records.forEach(record=>{const text=mode==='before'?record.original:record.values[pick];if(value(record)!==text)write(record,text);record.node.classList.toggle('copy-highlight',changes.checked&&mode==='after'&&text!==record.original)});before.setAttribute('aria-pressed',mode==='before');after.setAttribute('aria-pressed',mode==='after');status.textContent=data.choices[pick].name+' · '+mode+' · '+records.filter(record=>record.values[pick]!==record.original).length+' text fields';dispatchEvent(new Event('resize'));if(mark)scrollBy({top:mark.node.getBoundingClientRect().top-mark.top,behavior:'instant'});try{localStorage.setItem(storageKey,JSON.stringify({pick,mode}))}catch{}document.dispatchEvent(new Event('copy-preview-change'))}
 function init(){records=data.fields.flatMap(field=>[...document.querySelectorAll(field.selector)].map(node=>({...field,node,original:field.attribute?node.getAttribute(field.attribute):node.innerHTML})));const missing=data.fields.filter(field=>!document.querySelector(field.selector));if(missing.length){status.textContent='Missing copy fields: '+missing.map(field=>field.selector).join(', ');console.error(status.textContent);return}window.copyPreview={choices:data.choices,records,setMode(next){mode=next==='before'?'before':'after';paint()},setChoice(index){if(index>=0&&index<data.choices.length){pick=index;select.value=pick;paint()}}};paint()}
 select.addEventListener('change',()=>{pick=Number(select.value);paint()});before.addEventListener('click',()=>{mode='before';paint()});after.addEventListener('click',()=>{mode='after';paint()});changes.addEventListener('change',paint);
 more.addEventListener('click',()=>{extra.hidden=!extra.hidden;more.setAttribute('aria-expanded',!extra.hidden)});document.addEventListener('click',event=>{if(!dock.contains(event.target)){extra.hidden=true;more.setAttribute('aria-expanded','false')}});document.addEventListener('keydown',event=>{if(event.key==='Escape'){extra.hidden=true;more.setAttribute('aria-expanded','false')}});document.getElementById('copy-collapse').addEventListener('click',()=>{extra.hidden=true;more.setAttribute('aria-expanded','false');dock.classList.add('cp-collapsed')});document.getElementById('copy-expand').addEventListener('click',()=>dock.classList.remove('cp-collapsed'));
 document.getElementById('copy-choice').addEventListener('click',async()=>{const text='Switch website copy: '+data.choices[pick].name+' ('+mode+').';try{await navigator.clipboard.writeText(text);status.textContent='Choice copied'}catch{const area=document.createElement('textarea');area.value=text;dock.append(area);area.select();const copied=document.execCommand('copy');area.remove();status.textContent=copied?'Choice copied':text}});
 if(document.readyState==='complete')requestAnimationFrame(init);else addEventListener('load',()=>requestAnimationFrame(init),{once:true});
})();
</script>`;
new vm.Script(script.match(/<script id="copy-preview-script">([\s\S]*?)<\/script>/)[1]);
const original = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8');
const html = original.replace('</head>', `${css}</head>`).replace('</body>', `${dock}${script}</body>`);
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(`${output}.new`, html);
fs.renameSync(`${output}.new`, output);
fs.writeFileSync(path.join(path.dirname(output), 'copy-inventory.json'), JSON.stringify({ choices, fields, preserved: ['App demo UI and synthetic data', 'Performance quantities and measured release facts', 'Provider count widget and version facts', 'Download URLs and actual commands', 'Privacy and legal policy pages', 'Images, interactions, layout, and website styling'] }, null, 2));
console.log(JSON.stringify({ output, fields: fields.length, choices: choices.map(choice => choice.name) }));
if (process.argv.includes('--serve')) {
  const types = { '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.html': 'text/html' };
  const server = http.createServer((request, response) => {
    if (request.method !== 'GET' && request.method !== 'HEAD') { response.writeHead(405).end(); return; }
    let pathname;
    try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); } catch { response.writeHead(400).end(); return; }
    let target = pathname === '/' || pathname === '/index.html' ? output : path.resolve(publicDir, `.${pathname}`);
    if (target !== output && !path.extname(target)) target = path.join(target, 'index.html');
    if (target !== output && !target.startsWith(`${publicDir}${path.sep}`)) { response.writeHead(403).end(); return; }
    fs.stat(target, (error, stat) => {
      if (error || !stat.isFile()) { response.writeHead(404).end(); return; }
      const real = fs.realpathSync(target);
      if (target !== output && !real.startsWith(`${fs.realpathSync(publicDir)}${path.sep}`)) { response.writeHead(403).end(); return; }
      response.writeHead(200, { 'Content-Type': `${types[path.extname(target)] || 'application/octet-stream'}${['.html', '.js', '.css'].includes(path.extname(target)) ? '; charset=utf-8' : ''}`, 'Cache-Control': 'no-store' });
      if (request.method === 'HEAD') response.end(); else fs.createReadStream(target).on('error', () => response.destroy()).pipe(response);
    });
  });
  server.listen(8850, '127.0.0.1', () => console.log('Copy preview: http://127.0.0.1:8850 (8-hour limit)'));
  setTimeout(() => server.close(), 8 * 60 * 60 * 1000).unref();
  process.on('SIGINT', () => server.close());
  process.on('SIGTERM', () => server.close());
}
