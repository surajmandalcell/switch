// Every limit, live: the cards beside the auto switch tile. Each design is one .opt child of [data-meters];
// vary.js shows one at a time. Every design follows the tile's k-auto events:
//   { phase: 'reset', pct: 76 }  ada.lovelace is the default again, Session 76%
//   { pct: n }                   ada.lovelace's Claude Code Session drains (76 down to 1)
//   { phase: 'switch' }          Switch makes katherine.johnson the default
(() => {
  const root = document.querySelector('[data-meters]');
  if (!root) return;
  const check = '<svg class="lmc-ck" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 6.4 4.8 9 10 3"/></svg>';
  // The small macOS progress indicator: eight spokes, stepped round in 45 degree turns.
  const spin = `<svg class="lmc-sp" viewBox="0 0 16 16" aria-hidden="true">${[...Array(8)].map((_, i) => `<path d="M8 1.8v2.9" transform="rotate(${i * 45} 8 8)" stroke-opacity="${(0.22 + i * 0.11).toFixed(2)}"/>`).join('')}</svg>`;
  const fmt = s => { const d = Math.floor(s / 86400), h = Math.floor(s / 3600) % 24, m = String(Math.floor(s / 60) % 60).padStart(2, '0'); return d ? `${d}d ${h}h ${m}m` : `${h}h ${m}m ${String(s % 60).padStart(2, '0')}s`; };
  const LIM = [
    { name: 'Claude Code', icon: 'claude-code', color: '#D97757', accounts: [
      { email: 'ada.lovelace@example', on: 1, windows: [['Session', 76, '3h 19m'], ['Weekly', 41, '2d 3h']] },
      { email: 'katherine.johnson@example', windows: [['Session', 65, '1h 59m'], ['Weekly', 58, '4d 6h']] },
    ] },
    { name: 'Codex CLI', icon: 'openai', color: '#10A37F', accounts: [
      { email: 'grace.hopper@example', on: 1, windows: [['Session', 59, '1h 29m'], ['Weekly', 12, '5d 12h']] },
      { email: 'linus.torvalds@example', windows: [['Weekly', 33, '2d 23h']] },
    ] },
  ];
  const designs = [];

  // 1. Popover cards: one card for each tool, after MenuBarRows.swift.
  designs.push(['Popover cards', el => {
    el.innerHTML = LIM.map((s, si) => `<div class="lmc"><div class="lmc-h"><img src="assets/tools/${s.icon}.webp" alt="">${s.name}</div>` +
      s.accounts.map((a, ai) => `<div class="lmc-r${a.on ? ' on' : ''}">${check}${spin}<div class="lmc-e">${a.email}</div>` +
        a.windows.map(([w, p, t], wi) => `<div class="lmc-w"><span>${w}</span><span class="lmc-b"><i class="${p < 15 ? 'low' : ''}" style="--w:${p}%;--c:${s.color};--dl:${(0.3 + (si * 4 + ai * 2 + wi) * 0.06).toFixed(2)}s"></i></span><span class="lmc-p">${p}%</span><span class="lmc-t">${t}</span></div>`).join('') +
        '</div>').join('') + '</div>').join('');
    const [ra, rk] = el.querySelector('.lmc').querySelectorAll('.lmc-r');
    const set = (row, v) => { row.querySelector('.lmc-p').textContent = v + '%'; const b = row.querySelector('.lmc-b i'); b.style.setProperty('--w', v + '%'); b.classList.toggle('low', v < 15); };
    return d => {
      if (d.pct != null) set(ra, d.pct);
      if (d.phase === 'switch') { ra.classList.remove('on'); rk.classList.add('busy'); setTimeout(() => { rk.classList.remove('busy'); rk.classList.add('on'); }, 800); }
      if (d.phase === 'reset') { rk.classList.remove('on', 'busy'); ra.classList.add('on'); }
    };
  }]);

  // 2. Original rows: five floating rows, a tile, the account, and one window each.
  designs.push(['Original rows', el => {
    const rows = [['claude-code', 'ada.lovelace', 'Claude Code · Session', 76, 11940, 1], ['claude-code', 'katherine.johnson', 'Claude Code · Session', 65, 7140, 0], ['openai', 'grace.hopper', 'Codex CLI · Session', 59, 5340, 1], ['openai', 'linus.torvalds', 'Codex CLI · Weekly', 33, 255600, 0], ['openai', 'grace.hopper', 'Codex CLI · Monthly credits', 48, 1209600, 1]];
    const cls = v => v < 15 ? 'low' : v < 40 ? 'mid' : 'ok';
    el.classList.add('km');
    el.innerHTML = rows.map(([ic, who, lab, left, s, def]) => `<div class="km-row${def ? ' def' : ''}"><img src="assets/tools/${ic}.webp" alt=""><div class="km-tx"><i class="km-ck" aria-label="Default"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5 6.5 11.5 12.5 4.5"/></svg></i><b>${who}</b><small>${lab}</small></div><div class="km-num ${left < 15 ? 'low' : ''}"><span>${left}% left</span><small data-secs="${s}">resets in ${fmt(s)}</small><i class="km-spin" aria-hidden="true"></i></div><div class="km-bar"><i class="${cls(left)}" style="--w:${left}%"></i></div></div>`).join('');
    const [r0, r1] = el.children;
    const paint = v => { r0.querySelector('.km-num span').textContent = v + '% left'; r0.querySelector('.km-num').classList.toggle('low', v < 15); const b = r0.querySelector('.km-bar i'); b.style.setProperty('--w', v + '%'); b.className = cls(v); };
    setInterval(() => el.querySelectorAll('[data-secs]').forEach(c => { const s = Math.max(0, +c.dataset.secs - 1); c.dataset.secs = s; c.textContent = 'resets in ' + fmt(s); }), 1000);
    return d => {
      if (d.pct != null) paint(d.pct);
      // As in the menu bar: the old check goes, the new row spins while it switches, then gets the check.
      if (d.phase === 'switch') { r0.classList.remove('def'); r1.classList.add('busy'); setTimeout(() => { r1.classList.remove('busy'); r1.classList.add('def'); }, 900); }
      if (d.phase === 'reset') { r1.classList.remove('def'); r0.classList.add('def'); }
    };
  }]);

  // Designs 3 on share what follows. The app turns a bar red at 90% used, so 10% left or less is low.
  const RM = matchMedia('(prefers-reduced-motion: reduce)');
  const isLow = v => v <= 10;
  const [CL, CX] = LIM, [ADA, KAT] = CL.accounts, GRACE = CX.accounts[0];
  const nick = a => a.email.split('@')[0];
  const ck = c => `<svg class="${c}" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 6.4 4.8 9 10 3"/></svg>`;
  const sp = c => `<svg class="lmx-sp ${c}" viewBox="0 0 16 16" aria-hidden="true">${[...Array(8)].map((_, i) => `<path d="M8 1.8v2.9" transform="rotate(${i * 45} 8 8)" stroke-opacity="${(0.22 + i * 0.11).toFixed(2)}"/>`).join('')}</svg>`;
  const tile = s => `<img src="assets/tools/${s.icon}.webp" alt="">`;
  const glyph = s => `--g:url(assets/glyphs/${s.icon === 'openai' ? 'openai' : 'claude'}.svg)`;
  const initials = a => nick(a).split('.').map(w => w[0].toUpperCase()).join('');
  // Seconds to each window's reset, counted down once a second for every design.
  const left = new Map(), ticks = [];
  LIM.forEach(s => s.accounts.forEach(a => a.windows.forEach(([w, , t]) => left.set(nick(a) + w, t.split(' ').reduce((n, p) => n + parseInt(p, 10) * { d: 86400, h: 3600, m: 60 }[p.slice(-1)], 0) + 37))));
  const secs = (a, w) => left.get(nick(a) + w);
  const short = s => { const d = Math.floor(s / 86400), h = Math.floor(s / 3600) % 24, m = Math.floor(s / 60) % 60; return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`; };
  setInterval(() => { left.forEach((s, k) => left.set(k, Math.max(0, s - 1))); ticks.forEach(f => f()); }, 1000);
  const tickAll = el => ticks.push(() => el.querySelectorAll('[data-t]').forEach(n => { if (n.dataset.t) n.textContent = short(left.get(n.dataset.t)); }));
  const pct = (n, v) => { n.textContent = v + '%'; };
  const num = (n, v) => { n.textContent = v; };
  const set = (n, v, out = pct) => { cancelAnimationFrame(n.raf); n.v = v; out(n, v); };
  const count = (n, to, ms = 700, out = pct) => {
    const from = n.v ?? (parseInt(n.textContent, 10) || to);
    cancelAnimationFrame(n.raf); n.v = to;
    if (RM.matches || from === to) return out(n, to);
    const t0 = performance.now();
    const f = now => { const t = Math.min(1, (now - t0) / ms); out(n, Math.round(from + (to - from) * (1 - Math.pow(1 - t, 3)))); if (t < 1) n.raf = requestAnimationFrame(f); };
    n.raf = requestAnimationFrame(f);
  };
  // A name or value that changes fades and blurs out, then back in, as text does in the app.
  const fade = (n, html) => { if (n.innerHTML === html) return; n.classList.add('lmx-out'); clearTimeout(n.ft); n.ft = setTimeout(() => { n.innerHTML = html; n.classList.remove('lmx-out'); }, RM.matches ? 0 : 170); };
  // The drain, then the switch (the new default shows a spinner, and its check 0.8 s later), then the reset.
  const flow = h => { let t; return d => {
    if (d.phase === 'reset') { clearTimeout(t); h.reset(d.pct); return; }
    if (d.pct != null) h.pct(d.pct);
    if (d.phase === 'switch') { h.switch(); t = setTimeout(h.done, 800); }
  }; };
  const mark = (a, k) => ({
    switch: () => { a.forEach(e => e.classList.remove('on')); k.forEach(e => e.classList.add('busy')); },
    done: () => k.forEach(e => { e.classList.remove('busy'); e.classList.add('on'); }),
    reset: () => { k.forEach(e => e.classList.remove('on', 'busy')); a.forEach(e => e.classList.add('on')); },
  });
  const mine = (name, build) => designs.push([name, el => { el.classList.add('lmx'); return build(el); }]);

  // The popover of the real app (MenuBarRows.swift): group headers, a check column, one line per window, the footer.
  const ICON = {
    refresh: '<path d="M12.6 6.9A4.9 4.9 0 1 1 8 3.7"/><path d="M6.3 1.6 8.5 3.7 6.3 5.8"/>',
    power: '<path d="M8 1.9v5.4"/><path d="M4.9 4.7a5 5 0 1 0 6.2 0"/>',
    gear: (() => { const p = []; for (let j = 0; j < 8; j++) [[-17, 5], [-8, 6.6], [8, 6.6], [17, 5]].forEach(([a, r]) => { const t = (j * 45 + a) * Math.PI / 180; p.push(`${(8 + r * Math.sin(t)).toFixed(2)} ${(8 - r * Math.cos(t)).toFixed(2)}`); }); return `<path d="M${p.join('L')}Z"/><circle cx="8" cy="8" r="2.1"/>`; })(),
  };
  const popover = cls => `<div class="lmp ${cls}"><div class="lmp-list">` + LIM.map((s, si) => '<div class="lmp-g">' + (si ? '<i class="lmp-sep"></i>' : '') +
    `<div class="lmp-h lmx-in" style="--d:${si * 4}">${tile(s)}${s.name}</div>` +
    s.accounts.map((a, ai) => `<div class="lmp-r lmx-in${a.on ? ' on' : ''}" style="--d:${si * 4 + ai + 1}"><div class="lmp-n">${ck('lmp-ck')}<span>${a.email}</span>${sp('lmp-sp')}</div>` +
      a.windows.map(([w, p], wi) => `<div class="lmp-l"><span>${w}</span><span class="lmp-b"><i class="lmx-wipe${isLow(p) ? ' low' : ''}" style="--w:${p}%;--c:${s.color};--d:${si * 4 + ai + wi + 2}"></i></span><b>${p}%</b><span data-t="${nick(a) + w}">${short(secs(a, w))}</span></div>`).join('') + '</div>').join('') + '</div>').join('') +
    `</div><div class="lmp-f lmx-in" style="--d:9"><span class="lmp-o">Open Switch<kbd>⌘O</kbd></span><i></i>${['refresh', 'power', 'gear'].map(k => `<span class="lmp-ib"><svg viewBox="0 0 16 16" aria-hidden="true">${ICON[k]}</svg></span>`).join('')}</div></div>`;
  const popFlow = (el, x = {}) => {
    const [A, K] = el.querySelectorAll('.lmp-r'), bar = A.querySelector('.lmp-b i'), n = A.querySelector('.lmp-l b'), m = mark([A], [K]);
    const paint = v => { n.textContent = v + '%'; bar.style.setProperty('--w', v + '%'); bar.classList.toggle('low', isLow(v)); };
    tickAll(el);
    return flow({
      pct: v => { paint(v); x.pct?.(v); },
      switch: () => m.switch(),
      done: () => { m.done(); x.done?.(); },
      reset: v => { m.reset(); paint(v); x.reset?.(v); },
    });
  };

  // 3. Menu bar popover: the whole popover, both tools and the footer, at the app's own spacing.
  mine('Menu bar popover', el => { el.innerHTML = popover('lm3'); return popFlow(el); });

  // 4. Dark menu bar: the dark popover open under Switch's status item, on a dark desktop.
  const APPLE = '<svg class="lm4-ap" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"/></svg>';
  const BAT = '<svg class="lm4-bat" viewBox="0 0 25 12" aria-hidden="true"><rect x=".6" y=".6" width="21" height="10.8" rx="3.2" fill="none" stroke="currentColor" stroke-opacity=".5" stroke-width="1.1"/><rect x="2.2" y="2.2" width="15.6" height="7.6" rx="1.7" fill="currentColor"/><path d="M23.1 4.2v3.6a1.9 1.9 0 0 0 0-3.6z" fill="currentColor" fill-opacity=".5"/></svg>';
  const WIFI = '<svg class="lm4-wf" viewBox="0 0 16 12" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M1.4 4.6a9.3 9.3 0 0 1 13.2 0"/><path d="M3.8 7a5.9 5.9 0 0 1 8.4 0"/><path d="M6.3 9.5a2.4 2.4 0 0 1 3.4 0"/></svg>';
  mine('Dark menu bar', el => {
    el.innerHTML = `<div class="lm4"><div class="lm4-mb">${APPLE}<b class="lm4-x">Terminal</b><span class="lm4-x">Shell</span><span class="lm4-x">Edit</span><span class="lm4-x">View</span><span class="lm4-x lm4-y">Window</span><span class="lm4-x lm4-y">Help</span><i class="lm4-gap"></i>` +
      `<span class="lm4-st"><i style="${glyph(CL)}"></i><b>${ADA.windows[0][1]}%</b><i style="${glyph(CX)}"></i><b>${GRACE.windows[0][1]}%</b></span>${BAT}${WIFI}<span>9:41 AM</span></div>${popover('dark lm4-pop')}</div>`;
    const n = el.querySelector('.lm4-st b');
    return popFlow(el, { pct: v => set(n, v), done: () => count(n, KAT.windows[0][1]), reset: v => set(n, v) });
  });

  // 5. Desktop widgets: a Batteries-style medium widget with a ring for each account, and a small widget for each tool.
  mine('Desktop widgets', el => {
    const ring = (p, c, d) => `<svg viewBox="0 0 64 64" aria-hidden="true"><circle class="lm5-tr" cx="32" cy="32" r="28"/><circle class="lm5-v${isLow(p) ? ' low' : ''}" cx="32" cy="32" r="28" pathLength="100" style="--v:${p};--c:${c};--d:${d}"/></svg>`;
    const cells = LIM.flatMap((s, si) => s.accounts.map((a, ai) => { const p = a.windows[0][1]; return `<div class="lm5-a${a.on ? ' on' : ''}"><span class="lm5-ring">${ring(p, s.color, si * 2 + ai)}${tile(s)}</span><b>${p}%</b><span class="lm5-n"><span class="lm5-m">${ck('lm5-ck')}${sp('lm5-sp')}</span><span>${nick(a)}</span></span></div>`; })).join('');
    const who = a => `<b>${nick(a)}</b><span>Resets in <span data-t="${nick(a)}Session">${short(secs(a, 'Session'))}</span></span>`;
    const small = (s, a, d) => `<div class="lm5-w lm5-s lmx-in" style="--d:${d}"><div class="lm5-h">${tile(s)}${s.name}</div><div class="lm5-big"><b>${a.windows[0][1]}</b>%</div><div class="lm5-cap">Session left</div>` +
      `<div class="lm5-wk"><span>Weekly</span><span class="lm5-b"><i class="lmx-wipe${isLow(a.windows[1][1]) ? ' low' : ''}" style="--w:${a.windows[1][1]}%;--c:${s.color};--d:${d + 4}"></i></span><b>${a.windows[1][1]}%</b></div><div class="lm5-who lmx-fd">${who(a)}</div></div>`;
    el.innerHTML = `<div class="lm5"><div class="lm5-w lm5-md lmx-in">${cells}</div>${small(CL, ADA, 2)}${small(CX, GRACE, 3)}</div>`;
    const [A, K] = el.querySelectorAll('.lm5-a'), v = A.querySelector('.lm5-v'), p = A.querySelector('b'), m = mark([A], [K]);
    const sm = el.querySelector('.lm5-s'), big = sm.querySelector('.lm5-big b'), wk = sm.querySelector('.lm5-wk'), wn = sm.querySelector('.lm5-who');
    let cur = ADA;
    const ringTo = x => { v.style.setProperty('--v', x); v.classList.toggle('low', isLow(x)); p.textContent = x + '%'; };
    const show = (a, x) => { cur = a; count(big, x, 700, num); sm.classList.toggle('low', isLow(x)); wk.querySelector('i').style.setProperty('--w', a.windows[1][1] + '%'); count(wk.querySelector('b'), a.windows[1][1]); fade(wn, who(a)); };
    tickAll(el);
    return flow({
      pct: x => { ringTo(x); if (cur === ADA) { set(big, x, num); sm.classList.toggle('low', isLow(x)); } },
      switch: m.switch,
      done: () => { m.done(); show(KAT, KAT.windows[0][1]); },
      reset: x => { m.reset(); ringTo(x); show(ADA, x); },
    });
  });

  // 6. Control Center: each account is a round toggle, lit for the default; the defaults' windows are sliders.
  mine('Control Center', el => {
    const sub = (a, r, v) => r.classList.contains('busy') ? 'Switching…' : (r.classList.contains('on') ? 'Default · ' : '') + `${v ?? a.windows[0][1]}% left`;
    const acc = (s, d) => `<div class="lm6-m lm6-acc lmx-in" style="--d:${d}"><div class="lm6-h">${tile(s)}${s.name}</div>` + s.accounts.map(a => `<div class="lm6-r${a.on ? ' on' : ''}"><span class="lm6-c"><i style="${glyph(s)}"></i>${sp('lm6-sp')}</span><span class="lm6-t"><b>${nick(a)}</b><small>${a.on ? 'Default · ' : ''}${a.windows[0][1]}% left</small></span></div>`).join('') + '</div>';
    const slider = (s, a, wi, d) => { const [w, p] = a.windows[wi]; return `<div class="lm6-m lm6-sl lmx-in" style="--d:${d}"><div class="lm6-sh"><span>${tile(s)}${w}</span><b>${p}%</b></div><div class="lm6-s"><i class="lmx-wipe${isLow(p) ? ' low' : ''}" style="--v:${p};--c:${s.color};--d:${d + 2}"></i></div><div class="lm6-sc"><span class="lmx-fd">${nick(a)}</span><span>Resets in <span data-t="${nick(a) + w}">${short(secs(a, w))}</span></span></div></div>`; };
    el.innerHTML = `<div class="lm6">${acc(CL, 0)}${acc(CX, 1)}${slider(CL, ADA, 0, 2)}${slider(CX, GRACE, 0, 3)}${slider(CL, ADA, 1, 4)}${slider(CX, GRACE, 1, 5)}</div>`;
    const [A, K] = el.querySelector('.lm6-acc').querySelectorAll('.lm6-r'), [sS, , sW] = el.querySelectorAll('.lm6-sl'), m = mark([A], [K]);
    let av = ADA.windows[0][1];
    const subs = () => { A.querySelector('small').textContent = sub(ADA, A, av); K.querySelector('small').textContent = sub(KAT, K); };
    const slide = (mod, v, anim) => { const i = mod.querySelector('.lm6-s i'); i.style.setProperty('--v', v); i.classList.toggle('low', isLow(v)); (anim ? count : set)(mod.querySelector('.lm6-sh b'), v); };
    const owner = (a, anim) => [[sS, 0], [sW, 1]].forEach(([mod, wi]) => { const [w, v] = a.windows[wi]; slide(mod, wi ? v : a === ADA ? av : v, anim); fade(mod.querySelector('.lm6-sc .lmx-fd'), nick(a)); const t = mod.querySelector('[data-t]'); t.dataset.t = nick(a) + w; t.textContent = short(secs(a, w)); });
    tickAll(el);
    return flow({
      pct: v => { av = v; slide(sS, v); subs(); },
      switch: () => { m.switch(); subs(); },
      done: () => { m.done(); subs(); owner(KAT, 1); },
      reset: v => { m.reset(); av = v; subs(); owner(ADA, 1); },
    });
  });

  // 7. System Settings: the Auto switch settings, then each tool's accounts in grouped rows with level indicators.
  mine('System Settings', el => {
    const chev = d => `<svg viewBox="0 0 10 16" aria-hidden="true"><path d="${d}" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
    const meter = (s, a) => a.windows.map(([w, p]) => `<span>${w}</span><span class="lm7-lv"><i class="lmx-wipe${isLow(p) ? ' low' : ''}" style="--w:${p}%;--c:${s.color}"></i></span><b>${p}%</b>`).join('');
    const row = (s, a) => `<div class="lm7-r${a.on ? ' on' : ''}"><span class="lm7-av">${initials(a)}</span><span class="lm7-tx"><b>${a.email}</b><small>${a.windows[0][0]} resets in <span data-t="${nick(a) + a.windows[0][0]}">${short(secs(a, a.windows[0][0]))}</span></small></span><span class="lm7-ms">${meter(s, a)}</span><span class="lm7-d"><span class="lm7-def">${ck('lm7-ck')}Default</span><span class="lm7-btn"><span>Switch</span>${sp('lm7-sp')}</span></span></div>`;
    el.innerHTML = `<div class="lm7"><div class="lm7-tb"><span class="lm7-nv">${chev('M7.5 2.5 2 8l5.5 5.5')}${chev('M2.5 2.5 8 8l-5.5 5.5')}</span><b>Auto switch</b></div><div class="lm7-bd">` +
      `<div class="lm7-g lmx-in"><div class="lm7-o"><span class="lm7-tx"><b>Switch accounts automatically</b><small>Make the next account in your Accounts order the default when one runs out.</small></span><span class="lm7-tg" aria-hidden="true"></span></div><div class="lm7-o"><span class="lm7-tx"><b>Switch when an account has</b></span><span class="lm7-pu">1% left<svg viewBox="0 0 8 12" aria-hidden="true"><path d="M1.5 4.5 4 2l2.5 2.5M1.5 7.5 4 10l2.5-2.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></span></div></div>` +
      LIM.map((s, si) => `<h4 class="lmx-in" style="--d:${si * 3 + 1}">${tile(s)}${s.name}</h4><div class="lm7-g lmx-in" style="--d:${si * 3 + 2}">${s.accounts.map(a => row(s, a)).join('')}</div>`).join('') + '</div></div>';
    const [A, K] = el.querySelectorAll('.lm7-r'), bar = A.querySelector('.lm7-lv i'), n = A.querySelector('.lm7-ms b'), m = mark([A], [K]);
    const paint = v => { n.textContent = v + '%'; bar.style.setProperty('--w', v + '%'); bar.classList.toggle('low', isLow(v)); };
    tickAll(el);
    return flow({ pct: paint, switch: m.switch, done: m.done, reset: v => { m.reset(); paint(v); } });
  });

  // 8. Activity Monitor: a table sorted by Session left, so the draining account sinks, over a live history graph.
  mine('Activity Monitor', el => {
    const rows = LIM.flatMap(s => s.accounts.map(a => { const w = Object.fromEntries(a.windows.map(([k, p]) => [k, p])); return { s, a, v: w.Session ?? null, wk: w.Weekly }; }));
    const mag = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="6.8" cy="6.8" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="m10.3 10.3 3.7 3.7" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>';
    el.innerHTML = `<div class="lm8"><div class="lm8-tb"><span class="lm8-tl"><i></i><i></i><i></i></span><span class="lm8-ti"><b>Limits</b><small>All accounts</small></span><i class="lm8-gap"></i><span class="lm8-seg"><span class="on">Session</span><span>Weekly</span></span><span class="lm8-q">${mag}Search</span></div>` +
      `<div class="lm8-th"><span></span><span>Account</span><span class="lm8-tool">Tool</span><span class="r lm8-so">Session left<svg viewBox="0 0 10 6" aria-hidden="true"><path d="m1.5 1.2 3.5 3.6 3.5-3.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></span><span class="r lm8-wk">Weekly</span><span class="r">Resets in</span></div>` +
      `<div class="lm8-tbd">${rows.map((r, i) => `<div class="lm8-r${r.a.on ? ' on' : ''}" style="--y:${i}"><span class="lm8-c">${ck('lm8-ck')}${sp('lm8-sp')}</span><span>${nick(r.a)}</span><span class="lm8-tool">${tile(r.s)}${r.s.name}</span><span class="r lm8-v">${r.v == null ? '–' : r.v + '%'}</span><span class="r lm8-wk">${r.wk}%</span><span class="r"${r.v == null ? '>–' : ` data-t="${nick(r.a)}Session">${short(secs(r.a, 'Session'))}`}</span></div>`).join('')}</div>` +
      `<div class="lm8-pn"><dl class="lm8-st"><dt>Default account</dt><dd class="lmx-fd">${nick(ADA)}</dd><dt>Session left</dt><dd>${ADA.windows[0][1]}%</dd><dt>Resets in</dt><dd>${fmt(secs(ADA, 'Session'))}</dd><dt>Weekly left</dt><dd>${ADA.windows[1][1]}%</dd></dl>` +
      `<div class="lm8-gr"><small>SESSION LEFT · CLAUDE CODE</small><div class="lm8-gb"><svg viewBox="0 0 300 100" preserveAspectRatio="none" aria-hidden="true"><path class="a"/><path class="l"/></svg></div></div></div></div>`;
    [...el.querySelectorAll('.lm8-r')].forEach((r, i) => { rows[i].el = r; rows[i].i = i; });
    const order = () => [...rows].sort((x, y) => (y.v ?? -1) - (x.v ?? -1) || x.i - y.i).forEach((r, i) => r.el.style.setProperty('--y', i));
    const [ra, rk] = rows, dd = el.querySelectorAll('.lm8-st dd'), m = mark([ra.el], [rk.el]);
    // About 15 s of history, one sample every 100 ms; the session was used a little before the page opened.
    const N = 150, buf = Array.from({ length: N }, (_, i) => 76 + Math.round(6 * (1 - Math.floor(i / 25) / 6)));
    const line = el.querySelector('.lm8-gb .l'), area = el.querySelector('.lm8-gb .a');
    let val = ADA.windows[0][1], cur = ADA;
    const draw = () => { const pts = buf.map((v, i) => `${(i * 300 / (N - 1)).toFixed(1)} ${(96 - v * 0.9).toFixed(1)}`).join('L'); line.setAttribute('d', 'M' + pts); area.setAttribute('d', `M0 100L${pts}L300 100Z`); };
    draw();
    setInterval(() => { if (el.hidden) return; buf.push(val); buf.shift(); draw(); }, 100);
    const paint = v => { ra.v = v; const c = ra.el.querySelector('.lm8-v'); c.textContent = v + '%'; c.classList.toggle('low', isLow(v)); order(); };
    const owner = (a, v) => { cur = a; val = v; fade(dd[0], nick(a)); count(dd[1], v); dd[1].classList.toggle('low', isLow(v)); dd[2].textContent = fmt(secs(a, 'Session')); count(dd[3], a.windows[1][1]); };
    ticks.push(() => { el.querySelectorAll('.lm8-tbd [data-t]').forEach(n => { n.textContent = short(left.get(n.dataset.t)); }); dd[2].textContent = fmt(secs(cur, 'Session')); });
    return flow({
      pct: v => { paint(v); if (cur === ADA) { val = v; set(dd[1], v); dd[1].classList.toggle('low', isLow(v)); } },
      switch: m.switch,
      done: () => { m.done(); owner(KAT, KAT.windows[0][1]); },
      reset: v => { m.reset(); paint(v); owner(ADA, v); },
    });
  });

  // 9. Big numbers: each tool's default account, its Session left in large rolling digits.
  mine('Big numbers', el => {
    const reel = '<span class="lm9-d"><span>' + [...'0123456789', '&nbsp;'].join('<br>') + '</span></span>';
    const mini = (lab, p, c) => `<div class="lm9-li"><span>${lab}</span><span class="lm9-b"><i class="lmx-wipe${isLow(p) ? ' low' : ''}" style="--w:${p}%;--c:${c}"></i></span><b>${p}%</b></div>`;
    const card = (s, a, o, d) => `<div class="lm9-c lmx-in" style="--d:${d}"><div class="lm9-h">${tile(s)}${s.name}</div><div class="lm9-who"><span class="lm9-m">${ck('lm9-ck')}${sp('lm9-sp')}</span><span class="lmx-fd">${nick(a)}</span></div>` +
      `<div class="lm9-big" role="img" aria-label="${a.windows[0][1]}% left"><span class="lm9-rl" aria-hidden="true">${reel}${reel}</span><small aria-hidden="true">%</small></div><div class="lm9-cap">${a.windows[0][0]} left</div><div class="lm9-rs">Resets in <span>${fmt(secs(a, a.windows[0][0]))}</span></div>` +
      `<div class="lm9-ls">${mini('Weekly', a.windows[1][1], s.color)}${mini(nick(o), o.windows[0][1], s.color)}</div></div>`;
    el.innerHTML = `<div class="lm9">${card(CL, ADA, KAT, 0)}${card(CX, GRACE, CX.accounts[1], 2)}</div>`;
    const roll = (big, v) => { const [t, o] = big.querySelectorAll('.lm9-d'); t.style.setProperty('--n', v >= 10 ? Math.floor(v / 10) % 10 : 10); t.classList.toggle('off', v < 10); o.style.setProperty('--n', v % 10); big.setAttribute('aria-label', v + '% left'); };
    const cards = [...el.querySelectorAll('.lm9-c')];
    cards.forEach((c, i) => roll(c.querySelector('.lm9-big'), [ADA, GRACE][i].windows[0][1]));
    const c = cards[0], big = c.querySelector('.lm9-big'), wh = c.querySelector('.lm9-who'), nm = wh.querySelector('.lmx-fd'), [wk, ot] = c.querySelectorAll('.lm9-li');
    const bar = (li, v) => { const i = li.querySelector('i'); i.style.setProperty('--w', v + '%'); i.classList.toggle('low', isLow(v)); };
    let cur = ADA, av = ADA.windows[0][1];
    const show = (a, o, v, ov) => { cur = a; roll(big, v); c.classList.toggle('low', isLow(v)); fade(nm, nick(a)); bar(wk, a.windows[1][1]); count(wk.querySelector('b'), a.windows[1][1]); fade(ot.querySelector('span'), nick(o)); bar(ot, ov); count(ot.querySelector('b'), ov); };
    ticks.push(() => cards.forEach((k, i) => { const a = i ? GRACE : cur; k.querySelector('.lm9-rs span').textContent = fmt(secs(a, a.windows[0][0])); }));
    return flow({
      pct: v => { av = v; if (cur === ADA) { roll(big, v); c.classList.toggle('low', isLow(v)); } else { bar(ot, v); set(ot.querySelector('b'), v); } },
      switch: () => wh.classList.add('busy'),
      done: () => { wh.classList.remove('busy'); show(KAT, ADA, KAT.windows[0][1], av); },
      reset: v => { av = v; show(ADA, KAT, v, KAT.windows[0][1]); },
    });
  });

  root.dataset.vary = 'meters';
  root.dataset.label = 'Limit cards';
  const handlers = designs.map(([name, build]) => {
    const o = document.createElement('div');
    o.className = 'opt lmo';
    o.dataset.name = name;
    root.append(o);
    return build(o);
  });
  document.addEventListener('k-auto', e => handlers.forEach(h => h && h(e.detail)));
})();
