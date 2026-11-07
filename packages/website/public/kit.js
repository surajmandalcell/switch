(() => {
  const DATA = [
    { name: 'Claude Code', icon: 'claude-code', color: '#D97757', accounts: [
      { email: 'ada.lovelace@example', windows: [['Session', 76, '3h 19m'], ['Weekly', 41, '2d 3h']] },
      { email: 'katherine.johnson@example', windows: [['Session', 65, '1h 59m'], ['Weekly', 9, '23h 59m']] },
    ] },
    { name: 'Codex CLI', icon: 'openai', color: '#10A37F', accounts: [
      { email: 'grace.hopper@example', windows: [['Session', 59, '1h 29m'], ['Weekly', 12, '5d 12h']] },
      { email: 'linus.torvalds@example', windows: [['Weekly', 33, '2d 23h']] },
    ] },
  ];
  const state = DATA.map(() => 0);
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const check = '<svg class="kp-check" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 6.4 4.8 9 10 3"/></svg>';
  // The small macOS progress indicator: eight spokes, stepped round in 45 degree turns.
  const spin = `<svg class="kp-spin" viewBox="0 0 16 16" aria-hidden="true">${[...Array(8)].map((_, i) => `<path d="M8 1.8v2.9" transform="rotate(${i * 45} 8 8)" stroke-opacity="${(0.22 + i * 0.11).toFixed(2)}"/>`).join('')}</svg>`;
  const foot = '<div class="kp-foot"><span class="kp-open">Open Switch <kbd>⌘O</kbd></span><span class="kp-sp"></span>' +
    '<span class="kp-ib"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M13 8a5 5 0 1 1-1.5-3.6M13 2.5v2.8h-2.8"/></svg></span>' +
    '<span class="kp-ib"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M8 2v5.5M4.6 4.4a5 5 0 1 0 6.8 0"/></svg></span>' +
    '<span class="kp-ib"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.6M8 12.6v1.6M14.2 8h-1.6M3.4 8H1.8M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1M12.4 12.4l-1.1-1.1M4.7 4.7 3.6 3.6"/></svg></span></div>';
  const pops = [];
  const whenSeen = (el, fn) => { const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { io.disconnect(); fn(); } }, { threshold: 0.3 }); io.observe(el); };
  // Offsets instead of client rects, so motion stays right inside zoomed or scaled parents.
  const pos = (n, root) => { let x = 0, y = 0; for (let e = n; e && e !== root; e = e.offsetParent) { x += e.offsetLeft; y += e.offsetTop; } return { x, y, w: n.offsetWidth, h: n.offsetHeight }; };
  const flash = (n, cls, ms) => { n.classList.remove(cls); void n.offsetWidth; n.classList.add(cls); setTimeout(() => n.classList.remove(cls), ms); };
  const ITEMS = [];
  DATA.forEach((s, si) => s.accounts.forEach((a, ai) => ITEMS.push({ si, ai, s, a, key: `${a.email.split('@')[0].replace('.', ' ')} ${s.name}`.toLowerCase() })));
  const tick = '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 6.4 4.8 9 10 3"/></svg>';
  function initPal(el) {
    el.classList.add('kpal');
    el.innerHTML = '<div class="kpal-q"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="7" cy="7" r="5"/><path d="m11 11 3.5 3.5"/></svg><span class="kpal-in"><span class="kpal-ty"></span><span class="kpal-cr"></span><span class="kpal-ph">Search accounts</span></span><kbd>⌘K</kbd></div><div class="kpal-sec">Accounts</div>' +
      '<div class="kpal-list">' + ITEMS.map((it, i) => `<div class="kpal-it" data-i="${i}"><img src="assets/tools/${it.s.icon}.webp" alt=""><span class="nm">${it.a.email.split('@')[0]}</span><small>${it.s.name} · ${it.a.windows[0][1]}% left</small><span class="kpal-def">${tick}Default</span><kbd class="kpal-ent">⏎</kbd></div>`).join('') + '</div>' +
      '<div class="kpal-foot"><span><kbd>↑</kbd> <kbd>↓</kbd> to move</span><span><kbd>⏎</kbd> to make default</span></div>';
    const rows = [...el.querySelectorAll('.kpal-it')], ty = el.querySelector('.kpal-ty'), ph = el.querySelector('.kpal-ph');
    const badges = () => rows.forEach((r, i) => r.classList.toggle('def', state[ITEMS[i].si] === ITEMS[i].ai));
    const mark = q => { let first = null; rows.forEach((r, i) => { const m = !q || ITEMS[i].key.includes(q); r.classList.toggle('out', !m); r.classList.remove('on'); if (m && !first) first = r; }); if (first) first.classList.add('on'); ph.style.display = q ? 'none' : ''; };
    const press = i => { rows[i].classList.add('press'); setTimeout(() => rows[i].classList.remove('press'), 260); K.pick(ITEMS[i].si, ITEMS[i].ai); };
    badges(); mark('');
    document.addEventListener('k-switch', badges);
    rows.forEach((r, i) => { r.addEventListener('mouseenter', () => { rows.forEach(x => x.classList.remove('on')); r.classList.add('on'); }); r.addEventListener('click', () => press(i)); });
    const run = async (word, idx) => {
      for (let n = 1; n <= word.length; n++) { ty.textContent = word.slice(0, n); mark(ty.textContent); await sleep(70 + Math.random() * 60); }
      await sleep(650); press(idx); await sleep(1700);
      while (ty.textContent) { ty.textContent = ty.textContent.slice(0, -1); mark(ty.textContent); await sleep(38); }
    };
    const words = [['linus', 3], ['katherine', 1], ['grace', 2], ['ada', 0]];
    let w = 0;
    whenSeen(el, async () => { await sleep(+el.dataset.delay || 900); for (;;) { const [word, idx] = words[w++ % words.length]; await run(word, idx); await sleep(800); } });
  }
  const hash = (a, b) => { const s = Math.sin(a * 127.1 + b * 311.7) * 43758.5453; return s - Math.floor(s); };
  // Every provider Switch supports, best known first. The file is assets/tools/<id>.webp.
  const TOOLS = [
    ['claude-code', 'Claude Code'], ['openai', 'OpenAI Codex'], ['cursor', 'Cursor'], ['gemini-cli', 'Gemini CLI'],
    ['copilot', 'GitHub Copilot'], ['windsurf', 'Windsurf'], ['factory', 'Factory Droid'], ['amp', 'Amp'], ['clinepass', 'Cline'],
    ['zed', 'Zed'], ['kiro', 'Kiro'], ['openrouter', 'OpenRouter'], ['ollama', 'Ollama'], ['grok-build', 'Grok Build'],
    ['mistral', 'Mistral'], ['deepseek', 'DeepSeek'], ['qwencloud', 'QwenCloud'], ['perplexity', 'Perplexity'],
    ['antigravity', 'Antigravity'], ['vertexai', 'Vertex AI'], ['azureopenai', 'Azure OpenAI'], ['bedrock', 'AWS Bedrock'], ['xai', 'xAI'],
    ['jetbrains', 'JetBrains AI'], ['notion', 'Notion AI'], ['warp', 'Warp'], ['raycast', 'Raycast'], ['vercel', 'Vercel AI Gateway'],
    ['huggingface', 'Hugging Face'], ['groq', 'Groq'], ['kimi', 'Kimi'], ['minimax', 'MiniMax'], ['zai', 'z.ai / GLM'],
    ['opencodego', 'OpenCode Go'], ['kilo', 'Kilo'], ['devin', 'Devin'], ['augment', 'Augment'], ['codebuff', 'Codebuff'], ['v0', 'v0'],
    ['gitkraken', 'GitKraken AI'], ['elevenlabs', 'ElevenLabs'], ['replicate', 'Replicate'], ['fireworks', 'Fireworks'],
    ['deepinfra', 'DeepInfra'], ['poe', 'Poe'], ['t3chat', 'T3 Chat'], ['manus', 'Manus'], ['litellm', 'LiteLLM'], ['tavily', 'Tavily'],
    ['exa', 'Exa'], ['deepgram', 'Deepgram'], ['mimo', 'Xiaomi MiMo'], ['stepfun', 'StepFun'], ['doubao', 'Doubao'],
    ['alibaba', 'Alibaba Coding Plan'], ['alibabatokenplan', 'Alibaba Token Plan'], ['ibmbob', 'IBM Bob'], ['xapi', 'X API'], ['pi', 'Pi'],
    ['qoder', 'Qoder'], ['muse', 'Muse Code'], ['commandcode', 'Command Code'], ['workbuddy', 'WorkBuddy'], ['zenmux', 'ZenMux'],
    ['atlascloud', 'Atlas Cloud'], ['venice', 'Venice'], ['nous', 'Nous Portal'], ['chutes', 'Chutes'], ['abacus', 'Abacus AI'],
    ['langdock', 'Langdock'], ['bifrost', 'Bifrost'], ['synthetic', 'Synthetic'], ['longcat', 'LongCat'], ['zoommate', 'ZoomMate'],
    ['xkiro', 'xKiro'], ['aerostack', 'Aerostack'], ['aiand', 'ai&'], ['aixy', 'Aixy'], ['cosmic', 'Cosmic AI'], ['devpass', 'DevPass'],
    ['helmcode', 'Helmcode'], ['linkup', 'Linkup'], ['neuralwatt', 'Neuralwatt'], ['sofya', 'Sofya'], ['tinyapi', 'TinyApi'],
    ['typesafe', 'TypeSafe'], ['hyper', 'Charm Hyper'], ['lithosai', 'LithosAI'], ['clawrouter', 'ClawRouter'],
    ['sailresearch', 'Sail Research'], ['sakana', 'Sakana AI'], ['wayfinder', 'Wayfinder'], ['llmman', 'llmman'],
    ['llmproxy', 'LLM Proxy'], ['sub2api', 'sub2api'],
  ];
  const TOOL_IDS = TOOLS.slice(0, 30).map(t => t[0]);
  function initExtras() {
    document.querySelectorAll('[data-marquee]').forEach(el => {
      const row = TOOL_IDS.map(t => `<img src="assets/tools/${t}.webp" alt="">`).join('');
      el.classList.add('k-marq');
      el.innerHTML = `<div class="k-marq-in">${row}${row}</div>`;
    });
    document.querySelectorAll('[data-copy]').forEach(b => b.addEventListener('click', () => { navigator.clipboard?.writeText(b.dataset.copy).catch(() => {}); b.classList.add('done'); setTimeout(() => b.classList.remove('done'), 1500); }));
  }
  const FAQ = [
    ['Is Switch free?', 'Yes. Switch is free and open source under the MIT license.'],
    ['Does Switch work on Mac and Linux?', 'The Mac app requires macOS 14 or later on Apple silicon. The standalone CLI supports Linux x86_64 with glibc 2.38 or later. The npm package is for Apple Silicon Macs.'],
    ['How much CPU and memory does it use?', 'Switch is a native Swift app with no Electron or web views. It refreshes usage and sleeps between checks. In the published day-long measurement, it averaged 0.6% CPU and about 20 MB of idle memory.'],
    ['What changes when I switch accounts?', 'For supported tools, Switch updates the login while keeping local settings and workspace data in place. Some tools use separate account profiles. Other providers support usage checks without changing a coding tool login. Cloud history and attachments can still require the original account.'],
    ['What if a switch fails?', 'Switch backs up the previous login and replaced data. Failed changes have recovery options.'],
    ['Does Switch read Keychain or browser cookies?', 'No. Switch does not read the macOS Keychain or browser cookie stores. Providers that need a browser session accept a session value you paste.'],
    ['Do I need the terminal?', 'No. On Mac, you can use the app and menu bar. The optional CLI uses the same saved accounts; Linux uses the CLI.'],
  ];
  const ALIAS = { 'ada.lovelace@example': 'Calm Heron', 'katherine.johnson@example': 'Bright Fox', 'grace.hopper@example': 'Swift Owl', 'linus.torvalds@example': 'Quiet Pine' };
  const COPY_SVG = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8" rx="2"/><path d="M10.5 5.5V4a1.5 1.5 0 0 0-1.5-1.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5"/></svg><svg class="ok" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5 6.5 11.5 12.5 4.5"/></svg>';
  const UUID = { grace: '3F2A9C14-7B1E-4D2A-9E55-0C8B6A1D7E42', linus: '9D41B7E0-25C3-4F8A-B6D2-71E0C4A93F15', ada: 'C7E2F930-4A1B-4E6D-8F27-5B9A03D1C68E', katherine: '1B8D6A52-E3F4-47C9-A0B1-D2E5F6A7B8C9' };
  function usageBlocks(which) {
    const codex = [`Codex CLI  grace.hopper@example  Plus  DEFAULT`, `  id      ${UUID.grace}`, `  Session           59% left  resets 1h 29m`, `  Weekly            12% left  resets 5d 12h`, ``, `Codex CLI  linus.torvalds@example  Pro`, `  id      ${UUID.linus}`, `  Weekly            33% left  resets 2d 23h`];
    const claude = [`Claude Code  ada.lovelace@example  Max  DEFAULT`, `  id      ${UUID.ada}`, `  Session           76% left  resets 3h 19m`, `  Weekly            41% left  resets 2d 3h`, ``, `Claude Code  katherine.johnson@example  Pro`, `  id      ${UUID.katherine}`, `  Session           65% left  resets 1h 59m`, `  Weekly            9% left  resets 23h 59m`];
    if (which === 'codex') return codex;
    if (which === 'claude-code') return claude;
    if (!which) return [...codex, '', ...claude];
    return [`Unknown provider or account '${which}'. Run switch providers.`];
  }
  const HELP = ['Switch manages file-based accounts for supported AI tools without using Keychain.', '', 'Usage:', '  ai-manager providers [--json]', '  ai-manager add [codex|grok-build|claude-code] [--yes] [--json]', '  ai-manager usage [provider|account-uuid] [--json] [--force]', '  ai-manager history [--json] [--period week|month|year]', '  ai-manager guard --provider <id> --min-remaining <0-100> [--json]', '  ai-manager status [--json]', '  ai-manager use <account-uuid> [--yes] [--json]', '  ai-manager interactive'];
  function runCmd(line) {
    const a = line.trim().split(/\s+/).filter(Boolean);
    if (!a.length) return [];
    const [c, sub, ...rest] = a;
    if (c === 'clear') return null;
    if (c === 'switch' || c === 'ai-manager') {
      if (!sub || ['help', '--help', '-h'].includes(sub)) return HELP;
      if (sub === 'usage') return usageBlocks(rest.find(x => !x.startsWith('-')));
      if (sub === 'guard') {
        const i = rest.indexOf('--min-remaining'), n = i >= 0 ? +rest[i + 1] : NaN;
        if (Number.isNaN(n)) return ['guard needs --provider <id> and --min-remaining <0-100>.'];
        return [59 > n ? `allow: 59% remains in primary, above ${n}%.` : `block: 59% remains in primary, at or below ${n}%.`];
      }
      if (sub === 'status') return ['Codex CLI    grace.hopper@example     DEFAULT', 'Codex CLI    linus.torvalds@example', 'Claude Code  ada.lovelace@example     DEFAULT', 'Claude Code  katherine.johnson@example', 'No pending logins.'];
      return [`Unknown command '${sub}'. Run ai-manager help.`];
    }
    return [`zsh: command not found: ${c}`];
  }
  const BRANCH = '<i class="br"></i>';
  // Agnoster with DEFAULT_USER set, so the user@host segment is hidden: the directory, then the git branch.
  const PROMPT = '<i class="ag a2"> ~/dev/switch </i><i class="ag a3"> ' + BRANCH + 'master </i><i class="ag a4"></i> ';
  // macOS Terminal, 90 columns by 22 rows. The profile colors come from body[data-term].
  function initMacTerm(el) {
    el.classList.add('mt');
    el.setAttribute('role', 'img');
    el.setAttribute('aria-label', 'Terminal running switch usage codex, switch guard, and switch status');
    el.innerHTML = '<div class="mt-bar"><span class="mt-dots"><i></i><i></i><i></i></span><span class="mt-title">switch — -zsh — 90×22</span></div><div class="mt-body"><div class="mt-out"></div></div>';
    const body = el.querySelector('.mt-body'), out = el.querySelector('.mt-out');
    const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
    const hlCmd = cmd => {
      const m = cmd.match(/^(\S*)([\s\S]*)$/), ok = ['switch', 'clear'].includes(m[1]);
      return (m[1] ? `<i class="${ok ? 'cg' : 'cr'}">${esc(m[1])}</i>` : '') + esc(m[2]);
    };
    let entries = [{ o: 'Last login: Mon Nov  2 09:41:02 on ttys000' }], cur = '', full = '';
    const line = (cmd, live) => {
      const ghost = live && full.startsWith(cur) && cur.length > 1 ? esc(full.slice(cur.length)) : '';
      return `<div class="pl">${PROMPT}${hlCmd(cmd)}${live ? '<span class="mt-cur"> </span>' + (ghost ? `<i class="sug">${ghost}</i>` : '') : ''}</div>`;
    };
    const render = () => {
      out.innerHTML = entries.map(e => e.p !== undefined ? line(e.p, false) : `<div>${esc(e.o) || ' '}</div>`).join('') + line(cur, true);
      body.scrollTop = body.scrollHeight;
    };
    const type = async cmd => {
      full = cmd;
      for (let n = 1; n <= cmd.length; n++) { cur = cmd.slice(0, n); render(); await sleep(40 + Math.random() * 70 + (cmd[n - 1] === ' ' ? 50 : 0)); }
      await sleep(380);
    };
    const enter = cmd => {
      entries.push({ p: cmd }); cur = ''; full = '';
      const res = runCmd(cmd);
      entries = res === null ? [] : [...entries, ...res.map(o => ({ o }))].slice(-40);
      render();
    };
    const script = ['switch usage codex', 'switch guard --provider codex --min-remaining 10', 'switch status', 'clear'];
    render();
    whenSeen(el, async () => {
      await sleep(800);
      for (;;) for (const cmd of script) { await type(cmd); enter(cmd); await sleep(cmd === 'clear' ? 900 : 2400); }
    });
  }
  const ALERTS = [
    ['Almost Out', 'Claude Code · katherine.johnson · Weekly', 'Under 10% usage remaining for this window.'],
    ['Cutting It Close', 'Codex CLI · grace.hopper · Weekly', 'Projected to finish close to your limit.'],
    ['Will Run Out', 'Claude Code · ada.lovelace · Session', 'Projected to finish before the limit resets.'],
    ['Available again', 'Codex CLI · linus.torvalds · Weekly', 'This window has reset. You can use this account again.'],
    ['Almost Out', 'Codex CLI · grace.hopper · Session', 'Under 10% usage remaining for this window.'],
  ];
  // macOS banners: they stack as they arrive, open into their Notification Center group, then close.
  function initAlerts(el) {
    el.classList.add('al');
    el.innerHTML = '<div class="al-gh"><b>Switch</b><span>Show less</span></div>' + ALERTS.map(([t, s, b]) => `<div class="al-n"><img src="assets/icon-256.webp" alt=""><div class="al-tx"><div class="al-t"><b>${t}</b><time>now</time></div><span>${s}</span><p>${b}</p></div></div>`).join('');
    const ns = [...el.querySelectorAll('.al-n')], gh = el.querySelector('.al-gh'), N = ns.length, G = 8, OFF = 'translateX(calc(100% + 28px))';
    let h = [];
    const put = (n, tf, z, op = 1) => { n.style.transform = tf; n.style.zIndex = z; n.style.opacity = op; };
    const reset = () => {
      el.classList.add('reset'); gh.classList.remove('on');
      ns.forEach(n => { n.style.height = ''; n.classList.remove('under'); put(n, OFF, 10); });
      h = ns.map(n => n.offsetHeight);
      void el.offsetWidth; el.classList.remove('reset');
    };
    const stack = (top, out) => ns.forEach((n, i) => {
      const d = Math.min(top - i, 3);
      let tf = OFF, op = 1;
      if (i <= top) tf = `${out ? OFF + ' ' : ''}translateY(${Math.min(d, 2) * 9}px) scale(${1 - Math.min(d, 2) * 0.05})`;
      if (i <= top && d > 2) op = 0;
      n.style.height = (i < top ? h[top] : h[i]) + 'px';
      n.classList.toggle('under', i < top);
      put(n, tf, 10 + i, op);
    });
    const column = (top, y0) => { let at = y0; for (let i = top; i >= 0; i--) { ns[i].style.height = h[i] + 'px'; ns[i].classList.remove('under'); put(ns[i], `translateY(${at}px)`, 10 + i); at += h[i] + G; } };
    whenSeen(el, async () => {
      for (;;) {
        reset();
        for (let k = 0; k < N; k++) { await sleep(k ? 650 : 600); stack(k, false); }
        await sleep(1300);
        gh.classList.add('on'); column(N - 1, 38); await sleep(3400);
        gh.classList.remove('on'); stack(N - 1, false); await sleep(1600);
        stack(N - 1, true); await sleep(1000);
      }
    });
  }
  const MB = {
    bat: '<svg class="mb-bat" viewBox="0 0 26 12" aria-hidden="true"><rect x=".5" y=".5" width="22" height="11" rx="3.5" fill="none" stroke="currentColor" stroke-opacity=".42"/><rect x="2" y="2" width="16" height="8" rx="2" fill="currentColor"/><path d="M24 4.2v3.6a1.9 1.9 0 0 0 0-3.6Z" fill="currentColor" fill-opacity=".42"/></svg>',
    wifi: '<svg class="mb-wifi" viewBox="0 0 17 12" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M1.3 4.4a10.2 10.2 0 0 1 14.4 0"/><path d="M3.9 7a6.5 6.5 0 0 1 9.2 0"/></g><path fill="currentColor" d="M8.5 11.6 6.4 9.5a3 3 0 0 1 4.2 0z"/></svg>',
    cc: '<svg class="mb-cc" viewBox="0 0 16 14" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.25"><rect x=".8" y="1" width="14.4" height="5.2" rx="2.6"/><rect x=".8" y="7.8" width="14.4" height="5.2" rx="2.6"/></g><circle cx="12.6" cy="3.6" r="1.6" fill="currentColor"/><circle cx="3.4" cy="10.4" r="1.6" fill="currentColor"/></svg>',
  };
  MB.bt = '<svg class="mb-bt" width="10" height="15" viewBox="0 0 10 15" aria-hidden="true"><path d="M1 4.2 8 10.4 4.6 13.4V1.6L8 4.6 1 10.8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  MB.spk = '<svg class="mb-spk" width="18" height="13" viewBox="0 0 18 13" aria-hidden="true"><path d="M1.5 4.5h2.8L8 1.5v10L4.3 8.5H1.5z" fill="currentColor"/><path d="M11 4a3.6 3.6 0 0 1 0 5M13.3 2a6.6 6.6 0 0 1 0 9" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';
  const MENUS = { Finder: ['File', 'Edit', 'View', 'Go', 'Window', 'Help'], Switch: ['File', 'Edit', 'View', 'Window', 'Help'] };
  // A macOS menu bar at 1:1 point size. The Switch status item sits left of the system items, as macOS orders them.
  function initMbar(el) {
    const app = el.dataset.app || 'Finder', menus = (MENUS[app] || MENUS.Finder).slice(0, el.dataset.menus ? +el.dataset.menus : 9);
    el.classList.add('mb');
    el.setAttribute('aria-hidden', 'true');
    el.innerHTML = `<i class="mb-apple"></i><b>${app}</b>${menus.map(m => `<span>${m}</span>`).join('')}<i class="mb-sp"></i>${MB.bt}${MB.spk}<span class="mb-st" data-status="glyph"></span>${MB.bat}${MB.wifi}${MB.cc}<span class="mb-clock">Mon Nov 2&nbsp; 9:41 AM</span>`;
  }
  // Backup: the login in ~/.codex flies back to its account first, then the next account's login flies in.
  // Avatars carry the meaning, so the motion needs no labels.
  const BKA = [['grace.hopper', 'GH', '#5E5CE6'], ['linus.torvalds', 'LT', '#F28C28']];
  const FILES = ['config.toml', 'AGENTS.md', 'sessions/', 'history.jsonl'];
  const FI = { doc: '<i class="bk-fi doc"></i>', dir: '<i class="bk-fi dir"></i>' };
  const CK = '<svg class="bk-ck" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 6.4 4.8 9 10 3"/></svg>';
  const SAVED = '<svg class="bk-sv" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6.3 5.1 8.4 9 4"/></svg>';
  function initBackup(el) {
    el.classList.add('bk');
    const av = i => `<i class="bk-av" style="--c:${BKA[i][2]}">${BKA[i][1]}</i>`;
    el.innerHTML = `<div class="bk-card bk-l"><div class="bk-h"><img src="assets/tools/openai.webp" alt="">Codex CLI</div>` +
      BKA.map((a, i) => `<div class="bk-acc">${CK}<span>${a[0]}</span><span class="bk-pin">${av(i)}${SAVED}</span></div>`).join('') +
      `<div class="bk-h dim"><img src="assets/tools/claude-code.webp" alt="">Claude Code</div></div><i class="bk-gap"></i>` +
      `<div class="bk-card bk-r"><div class="bk-h mono"><img src="assets/tools/openai.webp" alt="">~/.codex</div><div class="bk-f hot"><span class="bk-slot">${av(0)}</span><span>auth.json</span></div>${FILES.map(f => `<div class="bk-f">${f.endsWith('/') ? FI.dir : FI.doc}<span>${f}</span></div>`).join('')}</div>` +
      '<svg class="bk-lanes" aria-hidden="true"><path class="bk-ln"/><path class="bk-ln"/></svg><i class="bk-chip"></i>';
    const accs = [...el.querySelectorAll('.bk-acc')], slot = el.querySelector('.bk-slot'), hot = el.querySelector('.hot'), chip = el.querySelector('.bk-chip'), svg = el.querySelector('.bk-lanes'), lns = [...svg.querySelectorAll('path')];
    let cur = 0;
    const set = i => { cur = i; accs.forEach((a, j) => a.classList.toggle('on', j === i)); slot.innerHTML = av(i); };
    const mid = n => { const p = pos(n, el); return [p.x + p.w / 2, p.y + p.h / 2]; };
    const travel = async (from, to, i, ln, up) => {
      svg.setAttribute('width', el.offsetWidth); svg.setAttribute('height', el.offsetHeight);
      const [x0, y0] = mid(from), [x1, y1] = mid(to), dx = (x1 - x0) * 0.42, bend = up ? -46 : 46;
      const d = `M${x0.toFixed(1)} ${y0.toFixed(1)}C${(x0 + dx).toFixed(1)} ${(y0 + bend).toFixed(1)} ${(x1 - dx).toFixed(1)} ${(y1 + bend).toFixed(1)} ${x1.toFixed(1)} ${y1.toFixed(1)}`;
      ln.setAttribute('d', d); ln.style.stroke = BKA[i][2];
      const L = ln.getTotalLength();
      ln.style.strokeDasharray = L;
      chip.style.offsetPath = `path("${d}")`; chip.style.setProperty('--c', BKA[i][2]); chip.textContent = BKA[i][1];
      const ease = 'cubic-bezier(.65, 0, .35, 1)';
      chip.animate([{ offsetDistance: '0%', transform: 'scale(.8)', opacity: 0 }, { offsetDistance: '6%', transform: 'scale(1.18)', opacity: 1, offset: 0.12 }, { offsetDistance: '94%', transform: 'scale(1.18)', opacity: 1, offset: 0.88 }, { offsetDistance: '100%', transform: 'scale(1)', opacity: 0 }], { duration: 1050, easing: ease, fill: 'forwards' });
      ln.animate([{ strokeDashoffset: L, opacity: 0.9 }, { strokeDashoffset: 0, opacity: 0.9, offset: 0.8 }, { strokeDashoffset: 0, opacity: 0 }], { duration: 1400, easing: ease, fill: 'forwards' });
      await sleep(1050);
    };
    set(0);
    whenSeen(el, async () => {
      await sleep(600);
      for (;;) {
        const next = 1 - cur, home = accs[cur].querySelector('.bk-pin');
        flash(accs[next], 'press', 520); await sleep(380);
        slot.classList.add('out');
        await travel(slot, home, cur, lns[0], true);
        flash(home, 'got', 1300); await sleep(260);
        await travel(accs[next].querySelector('.bk-pin'), slot, next, lns[1], false);
        set(next); slot.classList.remove('out'); flash(slot, 'got', 900); flash(hot, 'flash', 900);
        await sleep(2400);
      }
    });
  }
  // Auto switch on a 608 by 420 stage: ada.lovelace drains to 1%, Switch makes katherine.johnson the default,
  // and the open Claude Code session resumes on it.
  const AUTO = { svc: 'Claude Code', win: 'Session', from: 'ada.lovelace', to: 'katherine.johnson', a: 76, b: 65, id: '7c1e9a2f' };
  const RESUME = 'Continue. A usage limit cut your last turn short; redo the last step if it did not finish.';
  const banner = () => `<div class="as-ban"><img src="assets/icon-256.webp" alt=""><div><div class="al-t"><b>Switch</b><time>now</time></div><p>${AUTO.svc} account ${AUTO.from} has 1% left. Switched to ${AUTO.to}.</p></div></div>`;
  const emitAuto = d => document.dispatchEvent(new CustomEvent('k-auto', { detail: d }));
  const frames = (alive, ms, on) => new Promise(res => { const t0 = performance.now(); const f = now => { if (!alive()) return res(); const t = Math.min(1, (now - t0) / ms); on(t); if (t < 1) requestAnimationFrame(f); else res(); }; requestAnimationFrame(f); });
  const drain = (alive, ms, on) => { let last = -1; return frames(alive, ms, t => { const v = Math.max(1, Math.round(AUTO.a - (AUTO.a - 1) * (1 - Math.pow(1 - t, 2.2)))); if (v !== last) { last = v; on(v); emitAuto({ pct: v }); } }); };
  const count = (alive, from, to, ms, on) => frames(alive, ms, t => on(Math.round(from + (to - from) * (1 - Math.pow(1 - t, 3)))));
  const typeIn = async (node, s, ms, alive) => { if (!node) return; for (let n = 1; n <= s.length; n++) { if (!alive()) return; node.textContent = s.slice(0, n); await sleep(ms + (s[n - 1] === ' ' ? ms : 0)); } };
  const status = (who, n) => `<div class="as-sl"><span>${who} · ${AUTO.svc}</span><span>${AUTO.win} <b>${n}</b>% left</span></div>`;
  const OLD = () => `<div class="pl">${PROMPT}<i class="cg">claude</i></div><div class="as-q">&gt; Add retries to the sync job</div><div><i class="as-dot">⏺</i> Update(src/sync.ts)</div><div class="as-dim">  ⎿  Added 12 lines</div><div><i class="as-dot">⏺</i> Bash(npm test)</div><div class="as-dim">  ⎿  PASS src/sync.test.ts (14 tests)</div><div><i class="as-dot">⏺</i> Update(src/retry.ts)</div><div class="as-lim">  ⎿  Usage limit reached · resets in 3h 19m</div><div class="as-box"><i>&gt;</i> <span class="as-ph">Try "add a test for retries"</span></div>${status(AUTO.from, `<span class="as-n0">${AUTO.a}</span>`)}`;
  const NEW = () => `<div class="pl">${PROMPT}<span class="as-cmd"></span><span class="mt-cur as-c1"> </span></div><div class="as-box"><i>&gt;</i> <span class="as-mt"></span><span class="mt-cur as-c2"> </span></div>${status(AUTO.to, AUTO.b)}`;
  const SCENE = () => `<div class="zc-cam"><div class="zc-wall"></div><div class="mb zc-mb"><i class="mb-apple"></i><b>Terminal</b><span>Shell</span><span>Edit</span><span>View</span><i class="mb-sp"></i><span class="mb-st zc-st"><i class="k-gl" style="--g:url(assets/glyphs/claude.svg)"></i><b><span class="as-n">${AUTO.a}</span>%</b></span>${MB.bat}${MB.wifi}<span class="mb-clock">9:41 AM</span></div>` +
    `<div class="zc-tm"><div class="mt"><div class="mt-bar"><span class="mt-dots"><i></i><i></i><i></i></span><span class="mt-title">switch — claude — 64×15</span></div><div class="mt-body"><div class="mt-out"><div class="zc-old">${OLD()}</div><div class="zc-new">${NEW()}</div></div></div></div></div>${banner()}</div><i class="zc-flash"></i>`;
  async function zoomCuts(el, alive) {
    const q = s => el.querySelector(s), st = el.querySelector('.as-st'), cam = q('.zc-cam'), item = q('.zc-st'), n = q('.zc-st .as-n'), n0 = q('.as-n0');
    const focus = (node, s, ms) => {
      const W = st.clientWidth, H = st.clientHeight;
      let tf = 'none';
      if (node) { const p = pos(node, cam), tx = Math.min(0, Math.max(W - W * s, W / 2 - s * (p.x + p.w / 2))), ty = Math.min(0, Math.max(H - H * s, H / 2 - s * (p.y + p.h / 2))); tf = `translate(${tx.toFixed(1)}px, ${ty.toFixed(1)}px) scale(${s})`; }
      cam.style.transitionDuration = ms + 'ms'; cam.style.transform = tf;
    };
    el.dataset.ph = 'drain'; el.classList.remove('low', 't1', 't2'); q('.as-cmd').textContent = ''; q('.as-mt').textContent = ''; n.textContent = AUTO.a; n0.textContent = AUTO.a;
    focus(item, 3.2, 0); emitAuto({ phase: 'reset', pct: AUTO.a });
    await sleep(900); if (!alive()) return;
    await drain(alive, 3200, v => { n.textContent = v; n0.textContent = v; el.classList.toggle('low', v <= 10); }); if (!alive()) return;
    flash(item, 'shake', 520); await sleep(700); if (!alive()) return;
    el.dataset.ph = 'switch'; emitAuto({ phase: 'switch' }); focus(null, 1, 900);
    await sleep(450); el.classList.remove('low');
    await count(alive, 1, AUTO.b, 700, v => { n.textContent = v; }); await sleep(1500); if (!alive()) return;
    el.dataset.ph = 'resume'; focus(q('.zc-tm'), 1.3, 900); await sleep(1000); if (!alive()) return;
    el.classList.add('t1'); await typeIn(q('.as-cmd'), `claude --resume ${AUTO.id}`, 40, alive);
    await sleep(350); if (!alive()) return; el.classList.add('t2'); await typeIn(q('.as-mt'), RESUME, 12, alive);
    await sleep(1600); if (!alive()) return;
    q('.zc-flash').animate([{ opacity: 0 }, { opacity: 1, offset: 0.35 }, { opacity: 0 }], { duration: 560, easing: 'ease-out' }); await sleep(200);
  }
  function initAuto(el) {
    const tile = el.parentElement;
    const fit = () => {
      const st = el.querySelector('.as-st'); if (!st) return;
      const w = tile.clientWidth, h = tile.clientHeight, k = Math.min(w / 608, h / 420);
      st.style.zoom = k.toFixed(4); st.style.width = Math.round(w / k) + 'px'; st.style.height = Math.round(h / k) + 'px';
    };
    el.className = 'as as-zc'; el.dataset.ph = 'drain'; el.innerHTML = `<div class="as-st">${SCENE()}</div>`; fit();
    new ResizeObserver(fit).observe(tile);
    whenSeen(el, async () => { const alive = () => true; await sleep(60); for (;;) await zoomCuts(el, alive); });
  }
  // The tools wall: four rows drift in opposite directions. The second copy of each row only closes the loop.
  function initWall(el) {
    const rows = el.querySelector('.wall-rows'), R = 4, per = Math.ceil(TOOLS.length / R);
    rows.innerHTML = [...Array(R)].map((_, r) => {
      const set = TOOLS.slice(r * per, r * per + per);
      const tiles = copy => set.map(([t, n]) => `<span class="wi" data-n="${n}"${copy ? ' aria-hidden="true"' : ''}><img src="assets/tools/${t}.webp" alt="${copy ? '' : n}"></span>`).join('');
      return `<div class="wr" style="--s:${[66, 58, 72, 62][r]}s">${tiles(0)}${tiles(1)}</div>`;
    }).join('');
  }
  // Scales a fixed-size scene to its parent's width. --fit (CSS, per breakpoint) or data-fit is the design width.
  function initFit() {
    const els = [...document.querySelectorAll('[data-fit]')];
    const run = () => els.forEach(el => {
      const pw = el.parentElement.clientWidth, w = parseFloat(getComputedStyle(el).getPropertyValue('--fit')) || +el.dataset.fit;
      if (pw && w) el.style.zoom = Math.min(1, pw / w).toFixed(4);
    });
    addEventListener('resize', run); run();
  }
  // A frame with `same` keeps the account and drains its window; `sw` shows the automatic switch that follows.
  const RING = [
    { icon: 'openai', svc: 'Codex CLI', who: 'grace.hopper', win: 'Session', pct: 59, c: '#10A37F' },
    { icon: 'openai', svc: 'Codex CLI', who: 'linus.torvalds', win: 'Weekly', pct: 33, c: '#10A37F' },
    { icon: 'claude-code', svc: 'Claude Code', who: 'ada.lovelace', win: 'Session', pct: 76, c: '#D97757' },
    { icon: 'claude-code', svc: 'Claude Code', who: 'ada.lovelace', win: 'Almost out', pct: 6, c: '#E5484D', low: 1, same: 1 },
    { icon: 'claude-code', svc: 'Claude Code', who: 'katherine.johnson', win: 'Session', pct: 65, c: '#D97757', sw: 1 },
  ];
  function initRing(el) {
    el.classList.add('kr');
    el.innerHTML = '<div class="kr-dial"><svg viewBox="0 0 120 120" aria-hidden="true"><circle class="kr-track" cx="60" cy="60" r="52"/><circle class="kr-arc" cx="60" cy="60" r="52" pathLength="100"/></svg><div class="kr-mid"><img src="assets/tools/' + RING[0].icon + '.webp" alt=""><b>0%</b><small>left</small></div></div>' +
      '<div class="kr-cap"><span class="kr-who"></span><small class="kr-win"></small></div><div class="kr-sw"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5 6.5 11.5 12.5 4.5"/></svg><span>Switched to <b></b></span></div>';
    const arc = el.querySelector('.kr-arc'), numEl = el.querySelector('.kr-mid b'), img = el.querySelector('.kr-mid img'), who = el.querySelector('.kr-who'), win = el.querySelector('.kr-win'), to = el.querySelector('.kr-sw b');
    let i = 0, cur = 0;
    const apply = f => {
      el.classList.toggle('low', !!f.low); el.classList.toggle('switched', !!f.sw);
      if (!f.same) { arc.style.transition = 'none'; arc.style.strokeDashoffset = 100; void arc.getBoundingClientRect(); arc.style.transition = ''; cur = 0; }
      arc.style.stroke = f.c; arc.style.transitionDuration = f.same ? '1.6s' : ''; arc.style.strokeDashoffset = 100 - f.pct;
      tween(numEl, cur, f.pct, f.same ? 1600 : 1000); cur = f.pct;
      img.src = `assets/tools/${f.icon}.webp`;
      who.textContent = `${f.svc} · ${f.who}`; win.textContent = f.low ? f.win : `${f.win} window`; to.textContent = f.who;
    };
    const show = () => {
      const f = RING[i++ % RING.length];
      if (f.same) apply(f);
      else {
        el.classList.add('out');
        setTimeout(() => { el.classList.remove('out', 'beat'); void el.offsetWidth; el.classList.add('beat'); apply(f); }, 300);
      }
      setTimeout(show, f.low ? 2600 : f.sw ? 3400 : 2600);
    };
    whenSeen(el, () => setTimeout(show, 300));
  }
  function initPrivacyPop() {
    const tg = document.querySelectorAll('[data-privacy-toggle]');
    if (!tg.length) return;
    let on = false, auto = true;
    const set = v => {
      on = v; tg.forEach(t => t.setAttribute('aria-checked', String(v)));
      document.querySelectorAll('[data-privacy-pop] .kp-email').forEach((s, i) => {
        if (!s.dataset.real) s.dataset.real = s.textContent;
        s.classList.add('swap'); setTimeout(() => { s.textContent = v ? ALIAS[s.dataset.real] : s.dataset.real; s.classList.remove('swap'); }, 150 + i * 50);
      });
    };
    tg.forEach(t => t.addEventListener('click', e => { e.stopPropagation(); auto = false; set(!on); }));
    whenSeen(tg[0], () => { const loop = () => { if (!auto) return; set(!on); setTimeout(loop, 2800); }; setTimeout(loop, 1200); });
  }
  // Hero desktop: the pointer opens the popover from the status item, expands an account, and clicks Switch.
  // The popover only fades, like the real one, so its text never scales or moves.
  function initDesk(el) {
    const st = el.querySelector('.mb-st'), pop = el.querySelector('.dk-pop'), kp = pop.querySelector('.kp'), cur = el.querySelector('.dk-cur');
    // Client rects are in zoomed pixels; the pointer moves in the scene's own pixels.
    const rel = n => { const a = n.getBoundingClientRect(), b = el.getBoundingClientRect(), z = b.width / el.offsetWidth || 1; return { x: (a.left - b.left) / z, y: (a.top - b.top) / z, w: a.width / z, h: a.height / z }; };
    const placePop = () => { if (!el.offsetWidth) return; const s = rel(st); pop.style.left = Math.round(Math.max(8, Math.min(el.clientWidth - pop.offsetWidth - 8, s.x + s.w / 2 - pop.offsetWidth / 2))) + 'px'; };
    const hover = n => { kp.querySelectorAll('.hov').forEach(x => x.classList.remove('hov')); if (n) n.classList.add('hov'); };
    const open = v => { el.classList.toggle('open', v); st.classList.toggle('on', v); if (!v) { kp.kp.expand(null, false); hover(null); } };
    const moveTo = async (p, ms) => { cur.style.transitionDuration = ms + 'ms'; cur.style.transform = `translate(${Math.round(p.x)}px, ${Math.round(p.y)}px)`; await sleep(ms + 60); };
    const click = async () => { cur.classList.add('down'); await sleep(130); cur.classList.remove('down'); await sleep(70); };
    const rest = () => ({ x: el.clientWidth * 0.9, y: el.clientHeight * 0.86 });
    let run = 0;
    async function loop(id) {
      const alive = () => id === run;
      placePop(); open(false);
      const r0 = rest(); cur.style.transitionDuration = '0ms'; cur.style.transform = `translate(${Math.round(r0.x)}px, ${Math.round(r0.y)}px)`;
      await sleep(900);
      for (let k = 0; alive(); k++) {
        const si = k % 2, ai = 1 - state[si];
        const s = rel(st); await moveTo({ x: s.x + s.w / 2 - 4, y: s.y + s.h / 2 - 2 }, 1000); if (!alive()) return;
        await click(); placePop(); open(true); await sleep(650); if (!alive()) return;
        const row = kp.querySelector(`.kp-row[data-si="${si}"][data-ai="${ai}"]`);
        let r = rel(row.querySelector('.kp-email'));
        await moveTo({ x: r.x + Math.min(r.w, 160) * 0.55, y: r.y + r.h / 2 + 1 }, 820); hover(row); await sleep(320); if (!alive()) return;
        await click(); kp.kp.expand(row, true); await sleep(560); if (!alive()) return;
        const btn = row.querySelector('.kp-sw'); r = rel(btn);
        await moveTo({ x: r.x + r.w / 2 - 2, y: r.y + r.h / 2 - 1 }, 560); btn.classList.add('hov'); await sleep(280); if (!alive()) return;
        btn.classList.add('down'); await click(); btn.classList.remove('down', 'hov');
        await kp.kp.doSwitch(row); await sleep(1400); if (!alive()) return;
        await moveTo(rest(), 950); hover(null); await click(); open(false); await sleep(1600);
      }
    }
    addEventListener('resize', placePop);
    whenSeen(el, () => { run++; loop(run); });
  }
  function place(el) {
    el.querySelectorAll('.kp-row').forEach(r => r.classList.toggle('on', state[+r.dataset.si] === +r.dataset.ai));
  }
  const openLabel = s => `Open ${s.icon === 'openai' ? 'Codex' : s.name}`;
  // The menu bar popover. Clicking an account expands it; the expanded row shows Switch (other accounts only) and Open.
  function initPop(el) {
    el.classList.add('kp');
    if (el.dataset.pop === 'dark') el.classList.add('dark');
    el.innerHTML = DATA.map((s, si) => `<div class="kp-svc"><div class="kp-head"><img src="assets/tools/${s.icon}.webp" alt="">${s.name}</div><div class="kp-rows">` +
      s.accounts.map((a, ai) => `<div class="kp-row" role="button" tabindex="0" aria-expanded="false" data-si="${si}" data-ai="${ai}">${check}${spin}<div class="kp-email">${a.email}</div>` +
        a.windows.map((w, wi) => `<div class="kp-win"><span>${w[0]}</span><span class="kp-bar"><i style="--w:${w[1]}%;--c:${w[1] < 15 ? 'var(--kp-low)' : s.color};--dl:${0.6 + (si * 2 + ai) * 0.06 + wi * 0.04}s"></i></span><span class="kp-pct">${w[1]}%</span><span class="kp-rst">${w[2]}</span></div>`).join('') +
        `<div class="kp-act"><div><button type="button" class="kp-btn kp-sw" tabindex="-1">Switch</button><button type="button" class="kp-btn" tabindex="-1">${openLabel(s)}</button></div></div></div>`).join('') + '</div></div>').join('') + (el.dataset.foot === 'no' ? '' : foot);
    pops.push(el);
    const rows = [...el.querySelectorAll('.kp-row')];
    const expand = (row, v) => rows.forEach(r => { const on = r === row && v; r.classList.toggle('open', on); r.setAttribute('aria-expanded', String(on)); r.querySelectorAll('.kp-btn').forEach(b => { b.tabIndex = on ? 0 : -1; }); });
    const doSwitch = async row => {
      if (row.classList.contains('busy') || row.classList.contains('on')) return;
      row.classList.add('busy'); await sleep(800); row.classList.remove('busy');
      K.pick(+row.dataset.si, +row.dataset.ai);
    };
    el.kp = { expand, doSwitch };
    el.addEventListener('click', e => {
      const r = e.target.closest('.kp-row'); if (!r) return;
      const b = e.target.closest('.kp-btn');
      if (b) { if (b.classList.contains('kp-sw')) doSwitch(r); return; }
      expand(r, !r.classList.contains('open'));
    });
    el.addEventListener('keydown', e => { if (e.target.classList.contains('kp-row') && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); expand(e.target, !e.target.classList.contains('open')); } });
    place(el);
  }
  function tween(el, from, to, ms = 420) {
    const t0 = performance.now();
    const f = now => { const t = Math.min(1, (now - t0) / ms); el.textContent = Math.round(from + (to - from) * (1 - Math.pow(1 - t, 3))) + '%'; if (t < 1) requestAnimationFrame(f); };
    requestAnimationFrame(f);
  }
  // A status item: each tool's glyph (or tile) and its default account's Session percent. kit.js tweens the
  // numbers of every [data-status] on a switch, so a status item made later only needs filling once.
  function fillStatus(el) {
    el.classList.add('k-status');
    const gl = el.dataset.status === 'glyph';
    el.classList.toggle('glyph', gl);
    el.innerHTML = DATA.map((s, si) => (gl ? `<i class="k-gl" style="--g:url(assets/glyphs/${s.icon === 'openai' ? 'openai' : 'claude'}.svg)"></i>` : `<img src="assets/tools/${s.icon}.webp" alt="">`) + `<b>${s.accounts[state[si]].windows[0][1]}%</b>`).join('');
  }
  const K = window.K = {
    data: DATA, state, status: fillStatus, MB,
    pick(si, ai) {
      if (state[si] === ai) return;
      const before = DATA[si].accounts[state[si]].windows[0][1];
      state[si] = ai;
      pops.forEach(place);
      const s = DATA[si], a = s.accounts[ai];
      document.querySelectorAll('[data-status]').forEach(st => tween(st.querySelectorAll('b')[si], before, a.windows[0][1]));
      document.dispatchEvent(new CustomEvent('k-switch', { detail: { si, ai, service: s.name, who: a.email.split('@')[0], pct: a.windows[0][1] } }));
    },
  };
  function init() {
    document.querySelectorAll('[data-faq]').forEach(el => { el.innerHTML = FAQ.map(([q, a], i) => `<details class="faq"${i === 0 ? ' open' : ''}><summary>${q}</summary><p>${a}</p></details>`).join(''); });
    initFit();
    document.querySelectorAll('[data-pop]').forEach(initPop);
    document.querySelectorAll('[data-mbar]').forEach(initMbar);
    document.querySelectorAll('[data-mbz]').forEach(el => { el.classList.add('mbz'); el.setAttribute('aria-hidden', 'true'); el.innerHTML = `<i class="mbz-x">${MB.bt}</i><i class="mbz-x">${MB.spk}</i><span data-status="glyph"></span><i class="mbz-x">${MB.bat}</i><i class="mbz-x">${MB.wifi}</i>`; });
    document.querySelectorAll('[data-status]').forEach(fillStatus);
    document.querySelectorAll('[data-tiles]').forEach(el => {
      el.classList.add('k-tiles');
      el.innerHTML = TOOLS.slice(0, +el.dataset.tiles || TOOLS.length).map(([t, n], i) => `<li style="--i:${i};--r:${hash(i, 7).toFixed(3)}" data-n="${n}"><img src="assets/tools/${t}.webp" alt="${n}"></li>`).join('');
    });
    document.querySelectorAll('[data-pal]').forEach(initPal);
    document.querySelectorAll('[data-wall]').forEach(initWall);
    document.querySelectorAll('[data-count]').forEach(el => {
      const n = +el.dataset.count; el.textContent = '0';
      whenSeen(el, () => { const t0 = performance.now(); const f = now => { const t = Math.min(1, (now - t0) / 1400); el.textContent = Math.round(n * (1 - Math.pow(1 - t, 4))); if (t < 1) requestAnimationFrame(f); }; requestAnimationFrame(f); });
    });
    document.querySelectorAll('[data-reveal]').forEach(el => { const io = new IntersectionObserver(es => { if (es[0].isIntersecting) { el.classList.add('in'); io.disconnect(); } }, { threshold: 0.12 }); io.observe(el); });
    document.querySelectorAll('[data-macterm]').forEach(initMacTerm);
    document.querySelectorAll('[data-alerts]').forEach(initAlerts);
    document.querySelectorAll('[data-ring]').forEach(initRing);
    document.querySelectorAll('[data-backup]').forEach(initBackup);
    document.querySelectorAll('[data-autosw]').forEach(initAuto);
    document.querySelectorAll('[data-desk]').forEach(initDesk);
    document.querySelectorAll('[data-copy]').forEach(b => { if (!b.innerHTML.trim()) b.innerHTML = COPY_SVG; });
    initExtras();
    initPrivacyPop();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
