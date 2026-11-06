const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const publicDir = path.join(__dirname, 'public');
const mime = { '.webp': 'image/webp', '.svg': 'image/svg+xml', '.png': 'image/png' };
const assets = new Map();
function asset(file) {
  if (!assets.has(file)) assets.set(file, `data:${mime[path.extname(file)]};base64,${fs.readFileSync(path.join(publicDir, 'assets', file)).toString('base64')}`);
  return assets.get(file);
}
const css = ['kit.css', 'b.css'].map(file => fs.readFileSync(path.join(publicDir, file), 'utf8')).join('\n')
  .replace(/assets\/([\w./-]+)/g, (_, file) => asset(file));
const tools = Object.fromEntries(['claude-code', 'openai'].map(id => [id, asset(`tools/${id}.webp`)]));
const glyphs = Object.fromEntries(['claude', 'openai'].map(id => [id, asset(`glyphs/${id}.svg`)]));
const kit = fs.readFileSync(path.join(publicDir, 'kit.js'), 'utf8')
  .replaceAll('assets/tools/${s.icon}.webp', '${SCENE_TOOLS[s.icon]}')
  .replaceAll("assets/glyphs/${s.icon === 'openai' ? 'openai' : 'claude'}.svg", "${SCENE_GLYPHS[s.icon === 'openai' ? 'openai' : 'claude']}");
const escape = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);

function makeScene({
  title = 'Switch accounts.\nKeep the conversation.',
  subtitle = 'Account switching and usage for your coding tools.',
  fontSize = 56, fontWeight = 600, titleFontFamily = 'var(--sans)',
  align = 'center', layout = 'center', pattern = 'plain', subtitleFontSize = 18,
  sceneHeight = 860, appWidth = 900, topPadding = 187.5, sidePadding = 60,
  bottomPadding = 71, gap = 56, animate = false,
} = {}) {
  assert(['center', 'left', 'split'].includes(layout));
  assert(['center', 'left'].includes(align));
  assert(['plain', 'grid', 'dots'].includes(pattern));
  assert(/^[\w\s,'()\-]+$/.test(titleFontFamily), 'Use a local CSS font family');
  assert([fontSize, fontWeight, subtitleFontSize, sceneHeight, appWidth, topPadding, sidePadding, bottomPadding, gap].every(value => Number.isFinite(value) && value >= 0 && value <= 2000));
  const width = 1600 - 2 * sidePadding;
  const scale = layout === 'split' ? (width - 400 - gap) / width : 1;
  assert(width >= 900 && scale > 0);
  // Shorter desktop variants still contain the complete app window.
  const fittedAppWidth = Math.min(appWidth, (sceneHeight - 95) / .85, width - 128);
  const texture = pattern === 'plain' ? 'none' : `url("data:image/svg+xml;base64,${Buffer.from(pattern === 'grid'
    ? '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><path d="M32 0H0V32" fill="none" stroke="#111" stroke-opacity=".04"/></svg>'
    : '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="1" fill="#111" fill-opacity=".07"/></svg>').toString('base64')}")`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=1600"><title>Switch cover preview</title><style>${css}
html,body{margin:0;background:transparent!important;width:1600px;overflow:hidden}
.page{width:1600px;max-width:none;padding:${topPadding}px ${sidePadding}px ${bottomPadding}px;background-color:#F2F2F4;background-image:${texture};border-radius:6px;overflow:hidden}
.cover-layout{${layout === 'split' ? 'display:grid;grid-template-columns:400px 1fr;align-items:center;' : 'display:block;'}gap:${gap}px}
.hero{padding:0;animation:none;align-items:${align === 'left' ? 'flex-start' : 'center'};text-align:${align};${layout === 'split' ? '' : `margin-bottom:${gap}px;`}}
.h-t{font-family:${titleFontFamily};font-size:${fontSize}px;font-weight:${fontWeight};line-height:1.08;letter-spacing:-.035em;color:#111;text-wrap:balance}
.h-sub{max-width:1120px;margin-top:16px;font-size:${subtitleFontSize}px;color:#6B6B70;line-height:1.35}
.desktop-slot{width:${width * scale}px;height:${sceneHeight * scale}px}
.desk{width:${width}px;height:${sceneHeight}px;margin:0;zoom:${scale};border-radius:26px;clip-path:inset(0 round 26px);isolation:isolate;overflow:hidden;box-shadow:none;animation:none}
.dk-win{top:60px;left:64px;width:${fittedAppWidth}px}
${animate ? '' : '*,*::before,*::after{animation:none!important;transition:none!important}.dk-cur{display:none}'}
</style></head><body><main class="page" data-cover-width="1600"><div class="cover-layout"><section class="hero"><h1 class="h-t">${escape(title).replaceAll('\n', '<br>')}</h1><p class="h-sub">${escape(subtitle).replaceAll('\n', '<br>')}</p></section><div class="desktop-slot"><div class="desk" data-desk><div data-mbar data-app="Switch"></div><div class="dk-win"><div class="wsh"><div class="win"><img src="${asset('overview-tall-light.webp')}" alt="Switch Overview"><i class="tl"><b></b><b></b><b></b></i></div></div></div><div class="dk-pop"><div data-pop></div></div><svg class="dk-cur" viewBox="0 0 19 28" aria-hidden="true"><path d="M2 2v20.5l5-4.7 3.2 7.4 3.4-1.5-3.2-7.3H17z" fill="#000" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg></div></div></div></main><script>
const SCENE_TOOLS=${JSON.stringify(tools)},SCENE_GLYPHS=${JSON.stringify(glyphs)};
${animate ? '' : 'window.IntersectionObserver=class{observe(){}unobserve(){}disconnect(){}};'}
${kit.replace(/<\/script/gi, '<\\/script')}
Promise.all([document.fonts.ready,...Array.from(document.images,image=>image.decode())]).then(()=>{
 const height=Math.ceil(document.querySelector('.page').getBoundingClientRect().height);
 document.documentElement.dataset.coverHeight=height;
 document.documentElement.dataset.coverReady='true';
 parent.postMessage({type:'cover-scene-size',height,width:1600},'*');
});
</script></body></html>`;
}

module.exports = { makeScene };
