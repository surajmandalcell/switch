// Performance cards: each card loops through beats of [big text, label, ms]. The graphic above follows the beat.
// Numbers come from a running Switch 3.8.2: about 0.1% CPU between usage checks, under a second of CPU per
// check, 0.6% over a day, about 20 MB resident when idle. The Electron apps were measured on the same Mac.
(() => {
  const root = document.querySelector('.speed');
  if (!root) return;
  const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const CARDS = {
    cpu: [['0.1%', 'between checks', 3400], ['<1 s', 'per usage check', 2400], ['0.6%', 'averaged over a day', 3000]],
    mem: [[20, 'Switch, when idle', 3200], [170, 'an Electron chat app', 2300], [520, 'an Electron mail app', 2800]],
    speed: [['Native', 'Swift and SwiftUI', 0]],
    dl: [['23.5 MB', 'download, all of it', 0]],
  };
  const APPS = ['Switch', 'chat app', 'mail app'];
  const chars = s => [...s].map((c, n) => `<i style="--n:${n}">${c === ' ' ? '&nbsp;' : c.replace('<', '&lt;')}</i>`).join('');
  const cards = [...root.querySelectorAll('.pf-c')];
  const beatsOf = c => CARDS[c.dataset.card];

  function build(c) {
    const beats = beatsOf(c), mem = c.dataset.card === 'mem';
    c.querySelector('.pf-k').innerHTML = mem ? '<span></span>' : beats.map(b => `<span>${chars(b[0])}</span>`).join('');
    c.querySelector('.pf-l').innerHTML = beats.map(b => `<span>${b[1]}</span>`).join('');
    reset(c);
    show(c, 0);
  }
  // Swaps which span of a stack is shown: the old one leaves upward, the new one rises in.
  function swap(list, from, to) {
    list.forEach((s, j) => {
      s.classList.toggle('out', j === from && from !== to);
      s.classList.toggle('on', j === to);
      s.setAttribute('aria-hidden', String(j !== to));
    });
  }
  function show(c, i) {
    const beats = beatsOf(c), card = c.dataset.card, ls = c.querySelectorAll('.pf-l > span');
    if (card === 'mem') {
      const k = c.querySelector('.pf-k > span');
      k.classList.add('on');
      count(c, k, beats[i][0]);
      c.querySelectorAll('.pf-bars > div').forEach((r, j) => { r.classList.toggle('on', j <= i); r.classList.toggle('cur', j === i); });
    } else {
      const ks = c.querySelectorAll('.pf-k > span');
      // A beat with the same number keeps the shown one still and changes only the label.
      const k = c.k >= 0 && beats[c.k][0] === beats[i][0] ? c.k : i;
      if (k !== c.k) swap(ks, c.k, k);
      c.k = k;
    }
    if (i !== c.l) swap(ls, c.l, i);
    c.l = i; c.beat = i;
    clearTimeout(c.clean); c.clean = setTimeout(() => c.querySelectorAll('.out').forEach(s => s.classList.remove('out')), 900);
    if (card === 'cpu') {
      if (i === 1) c.spikeAt = performance.now();
      c.querySelectorAll('.pf-tag > span').forEach((s, j) => s.classList.toggle('on', j === (i === 1 ? 1 : 0)));
    }
  }
  // Hides every beat so the first one rises in again.
  function reset(c) {
    c.querySelectorAll('.pf-k > span, .pf-l > span').forEach(s => s.classList.remove('on', 'out'));
    c.k = c.l = c.beat = -1;
    c.val = null;
  }
  // The memory number runs up or down to the next value, like a counter.
  function count(c, el, to) {
    const from = c.val;
    c.val = to;
    cancelAnimationFrame(c.raf);
    if (calm || from == null || from === to) { el.textContent = to + ' MB'; return; }
    const t0 = performance.now(), dur = 700;
    const step = now => {
      const p = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - p, 4);
      el.textContent = Math.round(from + (to - from) * e) + ' MB';
      if (p < 1) c.raf = requestAnimationFrame(step);
    };
    c.raf = requestAnimationFrame(step);
  }

  // CPU: a sample every 50 ms, drawn every frame. The line slides left by the part of a sample that has
  // passed, and the head eases toward the newest sample, so it scrolls smoothly instead of stepping.
  const N = 90, DT = 50, VH = 100;
  const idle = () => 1 + Math.random() * 0.8;
  function initCpu(c) {
    c.vals = Array.from({ length: N }, idle);
    c.spikeAt = -1; c.acc = 0; c.last = 0;
    c.ln = c.querySelector('.ln'); c.ar = c.querySelector('.ar'); c.dot = c.querySelector('.pf-dot');
    const mo = c.querySelector('.pf-mo');
    c.mh = mo.clientHeight;
    new ResizeObserver(() => { c.mh = mo.clientHeight; drawCpu(c, c.acc / DT); }).observe(mo);
    drawCpu(c, 0);
  }
  function sample(c, now) {
    let v = idle();
    if (c.spikeAt >= 0) {
      const t = (now - c.spikeAt) / 1000;
      if (t < 0.9) v += 64 * (t < 0.12 ? t / 0.12 : Math.exp(-(t - 0.12) * 6)) * (0.92 + Math.random() * 0.16);
      else c.spikeAt = -1;
    }
    return v;
  }
  function tickCpu(c, now) {
    c.acc += c.last ? Math.min(100, now - c.last) : 0;
    c.last = now;
    while (c.acc >= DT) { c.acc -= DT; c.vals.push(sample(c, now)); c.vals.shift(); }
    drawCpu(c, c.acc / DT);
  }
  function drawCpu(c, f) {
    const dx = 240 / (N - 2), y = v => VH - 4 - v;
    let d = '';
    for (let i = 0; i < N - 1; i++) d += (i ? 'L' : 'M') + (240 - (N - 2 - i + f) * dx).toFixed(2) + ' ' + y(c.vals[i]).toFixed(2);
    const head = c.vals[N - 2] + (c.vals[N - 1] - c.vals[N - 2]) * f;
    d += 'L240 ' + y(head).toFixed(2);
    c.ln.setAttribute('d', d);
    c.ar.setAttribute('d', `${d}L240 ${VH}L${(240 - (N - 2 + f) * dx).toFixed(2)} ${VH}Z`);
    c.dot.style.transform = `translateY(${(y(head) / VH * c.mh).toFixed(1)}px)`;
  }

  function initMem(c) {
    const max = Math.max(...CARDS.mem.map(b => b[0]));
    c.querySelector('.pf-bars').innerHTML = CARDS.mem.map((b, j) => `<div><small>${APPS[j]}</small><i><b style="--v:${(b[0] / max * 100).toFixed(1)}%"></b></i></div>`).join('');
  }

  // Native: a small Switch window, laid out like the real one. The pointer clicks the next sidebar item and
  // the page is there on the same frame, as in the app.
  const IC = {
    overview: '<path d="M2.5 7.2 8 2.6l5.5 4.6V13a.6.6 0 0 1-.6.6H10V9.8H6v3.8H3.1a.6.6 0 0 1-.6-.6z"/>',
    accounts: '<circle cx="6" cy="5.4" r="2.4"/><path d="M1.6 13.2c.4-2.4 2.2-3.8 4.4-3.8s4 1.4 4.4 3.8z"/><circle cx="11.4" cy="5.9" r="1.9"/><path d="M11 9.6c2 0 3.2 1.2 3.5 3.6h-3"/>',
    settings: '<path d="M8 1.6l1.1 1.7 2-.3.5 2 1.8 1-.8 1.9.8 1.9-1.8 1-.5 2-2-.3L8 14.4l-1.1-1.7-2 .3-.5-2-1.8-1 .8-1.9-.8-1.9 1.8-1 .5-2 2 .3z"/><circle cx="8" cy="8" r="2.1" fill="#fff"/>',
    maintenance: '<path d="M10.4 1.8a3 3 0 0 0-3 3.9L2.1 11a1.3 1.3 0 0 0 1.8 1.8l5.3-5.3a3 3 0 0 0 3.9-3l-1.7 1.6-1.6-.4-.4-1.6z"/><path d="M3.4 2.2 6 4.8l-.9.9-2.6-2.6z"/>',
    conversations: '<path d="M8 2.4c3.3 0 5.8 2.1 5.8 4.8S11.3 12 8 12c-.6 0-1.2-.1-1.8-.2L3 13.4l.9-2.6C2.8 9.9 2.2 8.6 2.2 7.2 2.2 4.5 4.7 2.4 8 2.4z"/>',
  };
  const NAV = [['overview', 'Overview'], ['accounts', 'Accounts'], ['settings', 'Settings'], ['maintenance', 'Maintenance'], ['conversations', 'Conversations']];
  const card = (title, sub, body, extra = '') => `<section class="mw-cd"><header><b>${title}</b>${sub ? `<small>${sub}</small>` : ''}${extra}</header>${body}</section>`;
  const bar = (w, c) => `<span class="mw-bar"><i style="width:${w}%;background:${c}"></i></span>`;
  const accRow = (on, who, plan, w, c) => `<div class="mw-ar">${on ? '<svg viewBox="0 0 12 12"><path d="M2 6.4 4.8 9 10 3"/></svg>' : '<i></i>'}<span>${who}</span><em>${plan}</em>${bar(w, c)}<small>${w}%</small></div>`;
  const toggle = on => `<i class="mw-tg${on ? ' y' : ''}"></i>`;
  const PAGES = {
    overview: card('Usage', '(last 7 days)', '<div class="mw-st"><div><small>Tokens</small><b>4.2B</b><em>In the last 7 days</em></div><div><small>Estimated cost</small><b>$1.7K</b><em>API-rate estimate</em></div><div><small>Active accounts</small><b>3</b><em>Of 10 saved</em></div><div><small>Busiest day</small><b>Oct 16</b><em>1.3B tokens</em></div></div>', '<span class="mw-seg"><i class="y">Week</i><i>Month</i></span>') +
      card('Tokens per day', '(by account)', '<svg class="mw-ch" viewBox="0 0 400 80" preserveAspectRatio="none"><path fill="#DC8C72" d="M0 34C60 22 120 8 170 6s90 26 130 34 70-14 100-12V80H0z"/><path fill="#EF7A38" d="M0 52C50 50 110 70 170 72s80-26 130-28 70 10 100 8V80H0z"/><path fill="#2FA36B" d="M0 54C50 54 110 74 170 76s80-26 130-29 70 9 100 8V80H0z" opacity=".9"/></svg>'),
    accounts: card('<img src="assets/tools/claude-code.webp" alt="">Claude Code', '', accRow(1, 'ada.lovelace@example', 'Max', 76, '#D97757') + accRow(0, 'katherine.johnson@example', 'Pro', 65, '#D97757')) +
      card('<img src="assets/tools/openai.webp" alt="">Codex CLI', '', accRow(1, 'grace.hopper@example', 'Plus', 59, '#10A37F') + accRow(0, 'linus.torvalds@example', 'Pro', 33, '#10A37F')),
    settings: card('Menu bar', '', `<div class="mw-sr"><span>Show remaining limits</span>${toggle(1)}</div><div class="mw-sr"><span>Privacy mode</span>${toggle(0)}</div>`) +
      card('Auto switch', '', `<div class="mw-sr"><span>Switch accounts automatically</span>${toggle(1)}</div><div class="mw-sr"><span>Switch when an account has</span><span class="mw-pu">5% left</span></div>`),
    maintenance: '<div class="mw-seg big"><i class="y">Cleanup</i><i>Backup</i></div>' +
      card('Cleanup', 'Old sessions and caches', [['Claude Code sessions', '1.2 GB'], ['Codex CLI logs', '840 MB'], ['Droid caches', '310 MB']].map(([n, s], i) => `<div class="mw-sr"><span><i class="mw-cb${i < 2 ? ' y' : ''}"></i>${n}</span><small>${s}</small></div>`).join(''), '<span class="mw-bt">Scan</span>'),
    conversations: '<div class="mw-cv"><div class="mw-cl">' + [['Add retries to the sync job', 'Claude Code · 2 min'], ['Fix the flaky login test', 'Codex CLI · 1 h'], ['Write the release notes', 'Claude Code · Yesterday'], ['Speed up the cleanup scan', 'Droid · Mon']].map(([t, s], i) => `<div${i ? '' : ' class="y"'}><b>${t}</b><small>${s}</small></div>`).join('') +
      '</div><div class="mw-msgs"><p class="u">Add retries to the sync job</p><p>Added a retry with backoff to <code>sync.ts</code> and a test for it.</p><p class="u">Run the tests</p><p>14 tests pass.</p></div></div>',
  };
  const WIN = `<div class="mw"><aside><div class="mw-tl"><i></i><i></i><i></i><b>Switch</b></div><nav>${NAV.map(([k, n], i) => `<span${i ? '' : ' class="y"'}><svg viewBox="0 0 16 16">${IC[k]}</svg>${n}</span>`).join('')}</nav></aside>` +
    `<main><div class="mw-tb"><i class="mw-ib">+</i><i class="mw-ib">···</i><span class="mw-se"><svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.2"/><path d="m10.2 10.2 3 3"/></svg><span>Search accounts and settings…</span><kbd>⌘K</kbd></span></div>` +
    `<div class="mw-pgs">${NAV.map(([k], i) => `<div class="mw-pg${i ? '' : ' y'}">${PAGES[k]}</div>`).join('')}</div></main>` +
    '<svg class="mw-pt" viewBox="0 0 14 21"><path d="M1 1v15.6l3.7-3.6 2.4 5.6 2.6-1.1-2.4-5.5h5.2z"/></svg></div>';
  const MWH = 250;
  function initSpeed(c) {
    const mo = c.querySelector('.pf-app');
    mo.innerHTML = WIN;
    const w = mo.firstChild;
    const fit = () => { const k = mo.clientHeight / MWH; if (!k) return; w.style.transform = `scale(${k.toFixed(4)})`; w.style.width = Math.round(mo.clientWidth / k) + 'px'; place(c); };
    c.mw = w; c.page = 0;
    new ResizeObserver(fit).observe(mo);
    fit();
  }
  function place(c, i = c.page) {
    const item = c.mw.querySelectorAll('nav span')[i];
    c.mw.querySelector('.mw-pt').style.transform = `translate(${item.offsetLeft + 64}px, ${item.offsetTop + item.offsetHeight / 2 - 3}px)`;
  }
  function stepSpeed(c) {
    const next = (c.page + 1) % NAV.length, pt = c.mw.querySelector('.mw-pt');
    place(c, next);
    clearTimeout(c.clk);
    c.clk = setTimeout(() => {
      pt.classList.add('dn');
      c.mw.querySelectorAll('nav span').forEach((s, j) => s.classList.toggle('y', j === next));
      c.mw.querySelectorAll('.mw-pg').forEach((p, j) => p.classList.toggle('y', j === next));
      c.page = next;
      c.clk = setTimeout(() => pt.classList.remove('dn'), 120);
    }, 620);
  }

  cards.forEach(c => {
    if (c.dataset.card === 'cpu') initCpu(c);
    if (c.dataset.card === 'mem') initMem(c);
    if (c.dataset.card === 'speed') initSpeed(c);
    build(c);
  });

  let running = false;
  const loops = new Map();
  function restart(c) {
    (loops.get(c) || []).forEach(clearTimeout);
    const timers = [];
    loops.set(c, timers);
    const beats = beatsOf(c);
    if (beats.length > 1 && !calm) {
      const next = () => { const t = setTimeout(() => { show(c, (c.beat + 1) % beats.length); next(); }, beats[c.beat][2]); timers.push(t); };
      next();
    }
  }
  let raf = 0, pager = null;
  const cpus = cards.filter(c => c.dataset.card === 'cpu');
  const frame = now => { cpus.forEach(c => tickCpu(c, now)); raf = requestAnimationFrame(frame); };
  function start() {
    running = true;
    cards.forEach(reset);
    void root.offsetWidth;
    cards.forEach(c => { show(c, 0); restart(c); });
    if (calm) return;
    cpus.forEach(c => { c.last = 0; });
    raf = requestAnimationFrame(frame);
    pager = setInterval(() => cards.forEach(c => c.dataset.card === 'speed' && stepSpeed(c)), 1800);
  }
  function stop() {
    running = false;
    loops.forEach(ts => ts.forEach(clearTimeout)); loops.clear();
    cancelAnimationFrame(raf); clearInterval(pager);
  }
  new IntersectionObserver(([e]) => {
    root.classList.toggle('live', e.isIntersecting);
    if (e.isIntersecting && !running) start(); else if (!e.isIntersecting && running) stop();
  }, { rootMargin: '-10% 0px' }).observe(root);
})();
