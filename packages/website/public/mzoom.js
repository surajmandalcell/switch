// Always in your menu bar: designs for the magnified status item. Each design is an .opt inside [data-mzoom];
// vary.js shows one. Only the shown design animates, and only while the tile is on screen. See mzoom.css.
(() => {
  const root = document.querySelector('[data-mzoom]'), K = window.K;
  if (!root || !K) return;
  const tile = root.closest('.t') || root.parentElement, real = tile.querySelector('.mb-st');
  const RM = matchMedia('(prefers-reduced-motion: reduce)'), COL = matchMedia('(max-width: 820px)'), NARROW = matchMedia('(max-width: 560px)');
  // The height a design may fill: the row's height beside the copy, or a fixed cap once the tile stacks.
  const H = (el, pad, col = 210) => COL.matches ? col : el.clientHeight - pad;
  root.dataset.vary = 'mzoom';
  root.dataset.label = 'Menu bar zoom';
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const EASE = 'cubic-bezier(.22, 1, .36, 1)';
  const inout = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  const mk = (cls, html = '') => { const d = document.createElement('div'); d.className = cls; d.innerHTML = html; return d; };
  const frames = (ok, ms, on) => new Promise(res => { const t0 = performance.now(); const f = now => { if (!ok()) return res(); const t = Math.min(1, (now - t0) / ms); on(t); if (t < 1) requestAnimationFrame(f); else res(); }; requestAnimationFrame(f); });

  // The status item, with rolling digits. Every .mz-n of a tool rolls to its new value on k-switch.
  const pct = si => K.data[si].accounts[K.state[si]].windows[0][1];
  const who = si => K.data[si].accounts[K.state[si]].email.split('@')[0];
  const GL = si => `<i class="k-gl" style="--g:url(assets/glyphs/${K.data[si].icon === 'openai' ? 'openai' : 'claude'}.svg)"></i>`;
  const DIG = [...Array(10)].map((_, d) => `<i>${d}</i>`).join('');
  const odo = n => [...String(n)].map((d, k) => `<span class="mz-dc"><span style="--d:${d};--k:${k}">${DIG}</span></span>`).join('');
  const num = si => `<span class="mz-n" data-si="${si}">${odo(pct(si))}<span>%</span></span>`;
  const ST = (cls = '') => `<span class="mz-st ${cls}">${K.data.map((_, si) => GL(si) + num(si)).join('')}</span>`;
  const WHO = si => `<span class="mz-who" data-si="${si}">${who(si)}</span>`;
  function setNum(el, n) {
    const s = String(n), cols = [...el.querySelectorAll('.mz-dc')];
    if (cols.length !== s.length) { cols.forEach(c => c.remove()); el.insertAdjacentHTML('afterbegin', odo(n)); return; }
    cols.forEach((c, i) => c.firstElementChild.style.setProperty('--d', s[i]));
  }
  function swapText(el, s) {
    if (el.textContent === s) return;
    if (RM.matches) { el.textContent = s; return; }
    el.classList.add('swap');
    setTimeout(() => { el.textContent = s; el.classList.remove('swap'); }, 200);
  }

  // Menu bar items, in macOS order: app menus, then status items, then the clock.
  const CLK = { full: 'Mon Nov 2\u00a0 9:41 AM', mid: 'Mon 9:41 AM', short: '9:41 AM', night: 'Mon 9:41 PM' };
  const item = k => k === 'apple' ? '<i class="mb-apple"></i>' : k === 'sp' ? '<i class="mz-sp"></i>' : k === 'st' ? ST() : k === 'ghost' ? ST('mz-ghost')
    : k[0] === '@' ? `<b>${k.slice(1)}</b>` : k[0] === '#' ? `<span class="mz-clock">${CLK[k.slice(1)]}</span>` : K.MB[k] || `<span class="mz-m">${k}</span>`;
  const items = keys => keys.map(item).join('');
  const bar = (keys, cls = '') => `<div class="mz-bar ${cls}">${items(keys)}</div>`;
  const CHECK = '<svg class="ck" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 6.4 4.8 9 10 3"/></svg>';
  const PTR = '<svg class="mz-ptr" viewBox="0 0 19 28" aria-hidden="true"><path d="M2 2v20.5l5-4.7 3.2 7.4 3.4-1.5-3.2-7.3H17z" fill="#000" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';

  // Offsets, not client rects, so the tile's reveal and hover transforms never skew a measurement.
  const pos = (n, top) => { let x = 0, y = 0; for (let e = n; e && e !== top; e = e.offsetParent) { x += e.offsetLeft; y += e.offsetTop; } const w = n.offsetWidth, h = n.offsetHeight; return { x, y, w, h, cx: x + w / 2, cy: y + h / 2 }; };
  // Lays the stage out at 1x, runs at1x for measurements, then magnifies it to fit w by h.
  function fitZoom(stage, w, h, max, min = .5, at1x) {
    stage.style.zoom = 1;
    const w1 = stage.offsetWidth, h1 = stage.offsetHeight;
    if (at1x) at1x();
    const z = clamp(Math.min(w / w1, h / h1), min, max);
    stage.style.zoom = z.toFixed(4);
    return { z, w: w1 * z, h: h1 * z, w1, h1 };
  }
  const blurIn = (nodes, delay = 0, step = 60) => { if (RM.matches) return; [...nodes].forEach((n, i) => n.animate([{ opacity: 0, filter: 'blur(5px)', transform: 'translateY(3px) scale(.94)' }, { opacity: 1, filter: 'blur(0)', transform: 'none' }], { duration: 600, delay: delay + i * step, easing: EASE, fill: 'backwards' })); };
  const rise = (n, delay = 0) => { if (RM.matches) return; n.animate([{ opacity: 0, transform: 'translateY(14px) scale(.97)', filter: 'blur(6px)' }, { opacity: 1, transform: 'none', filter: 'blur(0)' }], { duration: 850, delay, easing: EASE, fill: 'backwards' }); };

  // Designs ---------------------------------------------------------------------------------------------------
  const opts = [];
  const add = (name, cls, make) => { const el = mk(`opt mz-o ${cls}`); el.dataset.name = name; root.append(el); opts.push(Object.assign({ el, t: 0 }, make(el) || {})); };
  const SVGNS = 'http://www.w3.org/2000/svg';
  const overlay = el => { const s = document.createElementNS(SVGNS, 'svg'); s.setAttribute('class', 'mz-ov'); s.setAttribute('aria-hidden', 'true'); el.prepend(s); return s; };
  // The real status item in the tile's menu bar, in tile coordinates, or null when the bar hides it.
  const realRect = () => real && real.offsetWidth && real.offsetLeft + real.offsetWidth <= tile.clientWidth - 2 ? pos(real, tile) : null;
  const placeOv = svg => { const b = pos(root, tile), W = tile.clientWidth, H = tile.clientHeight; Object.assign(svg.style, { left: -b.x + 'px', top: -b.y + 'px', width: W + 'px', height: H + 'px' }); svg.setAttribute('viewBox', `0 0 ${W} ${H}`); return b; };
  const drawIn = (svg, delay = 0) => { if (RM.matches) return; svg.querySelectorAll('[pathLength]').forEach((p, i) => p.animate([{ strokeDashoffset: 1 }, { strokeDashoffset: 0 }], { duration: 700, delay: delay + i * 80, easing: EASE, fill: 'backwards' })); };

  // 1. The original: a slice of the menu bar, 3.2 times.
  const strip = root.querySelector('.mbig');
  add('Menu bar strip', 'mz-strip', el => {
    if (strip) el.append(strip);
    return { layout() { if (strip) strip.style.setProperty('--w', Math.min(540, el.clientWidth) + 'px'); } };
  });

  // 2. The top right corner of the display: bezel, rounded screen corner, menu bar ending at the clock.
  function corner(dark) {
    return el => {
      const stage = mk(`mz-stage mz-cor${dark ? ' mz-dark' : ''}`); el.append(stage);
      let mode = '';
      const keys = { full: dark ? ['st', 'bat', 'wifi', 'cc', '#night'] : ['st', 'bat', 'wifi', 'cc', '#short'], sm: ['st', 'wifi', '#short'] };
      const draw = m => { mode = m; stage.innerHTML = `<div class="mz-cor-in ${dark ? 'mz-wall-d' : 'mz-wall'}">${bar(dark && m === 'sm' ? ['st', 'wifi', '#night'] : keys[m])}</div>`; };
      return {
        layout() { const w = el.clientWidth, m = w < 420 ? 'sm' : 'full'; if (m !== mode) draw(m); fitZoom(stage, w - 16, H(el, 24), 2, 1); },
        enter() { rise(stage); blurIn([...stage.querySelectorAll('.mz-bar > *')].reverse(), 260, 70); },
      };
    };
  }
  add('Screen corner', 'mz-cor-o', corner(false));

  // 3. A Liquid Glass capsule: the status item centered between its neighbors, nothing cut off.
  add('Glass capsule', 'mz-cap-o', el => {
    const stage = mk('mz-stage mz-cap'); el.append(stage);
    let mode = '';
    const draw = m => {
      mode = m;
      stage.classList.toggle('sm', m === 'sm');
      stage.innerHTML = m === 'sm' ? `<span class="mz-side l">${K.MB.spk}</span>${ST()}<span class="mz-side r">${K.MB.bat}</span>`
        : `<span class="mz-side l">${K.MB.bt}${K.MB.spk}</span>${ST()}<span class="mz-side r">${K.MB.bat}${K.MB.wifi}</span>`;
    };
    return {
      layout() { const w = el.clientWidth, m = w < 470 ? 'sm' : 'full'; if (m !== mode) draw(m); fitZoom(stage, w - 36, H(el, 40), 2.1, 1); },
      enter() {
        if (RM.matches) return;
        stage.animate([{ opacity: 0, transform: 'translateY(10px) scale(.94)' }, { opacity: 1, transform: 'none' }], { duration: 900, easing: 'cubic-bezier(.3, 1.3, .5, 1)', fill: 'backwards' });
        const st = stage.querySelector('.mz-st'), l = [...stage.querySelectorAll('.l svg')].reverse(), r = [...stage.querySelectorAll('.r svg')];
        blurIn([st], 200);
        l.forEach((n, i) => blurIn([n], 330 + i * 90)); r.forEach((n, i) => blurIn([n], 330 + i * 90));
      },
    };
  });

  // 4. The top of a MacBook Pro: the notch in the middle, menus on its left, the status item on its right.
  add('MacBook notch', 'mz-nt-o', el => {
    const stage = mk('mz-stage mz-nt'); el.append(stage);
    let mode = '';
    const draw = m => {
      mode = m;
      stage.classList.toggle('sm', m === 'sm');
      stage.innerHTML = `<div class="mz-nt-in mz-wall"><div class="mz-bar mz-ntb"><div class="mz-ntl">${m === 'sm' ? '' : items(['@Finder', 'File'])}</div><i class="mz-ntg"></i><div class="mz-ntr">${items(['st'])}</div></div></div><i class="mz-notch"></i>`;
    };
    return {
      layout() { const w = el.clientWidth, m = w < 470 ? 'sm' : 'full'; if (m !== mode) draw(m); fitZoom(stage, w - 8, H(el, 30), 1.75, .9); },
      enter() { rise(stage); blurIn(stage.querySelectorAll('.mz-ntr > *'), 300, 90); blurIn([...stage.querySelectorAll('.mz-ntl > *')].reverse(), 380, 70); },
    };
  });

  // 5. A detail callout: a ring on the real status item, and a magnified inset joined to it.
  add('Detail callout', 'mz-link mz-ins-o', el => {
    const svg = overlay(el), wrap = mk('mz-ins-w'), card = mk('mz-stage mz-ins mz-wall'); wrap.append(card); el.append(wrap);
    let mode = '', from = null;
    const draw = m => { mode = m; card.innerHTML = bar(m === 'sm' ? ['st', 'bat'] : ['spk', 'st', 'bat']); };
    return {
      layout() {
        const w = el.clientWidth, h = el.clientHeight, m = w < 420 ? 'sm' : 'full';
        if (m !== mode) draw(m);
        const f = fitZoom(card, w - 24, h - 74, 2.4, 1), b = placeOv(svg), it = realRect();
        const ix = it ? it.cx : b.x + b.w / 2, cx = clamp(ix, b.x + f.w / 2 + 6, b.x + b.w - f.w / 2 - 6);
        const ty = Math.max(b.y + (h - f.h) / 2 + 22, it ? it.y + it.h + 44 : 0), L = cx - f.w / 2, R = cx + f.w / 2;
        wrap.style.left = (L - b.x) + 'px'; wrap.style.top = (ty - b.y) + 'px';
        if (!it) { svg.innerHTML = ''; from = null; return; }
        const r = { x: it.x - 3, y: it.y + 1, w: it.w + 6, h: it.h - 2 }, o = 7 * f.z * (1 - Math.SQRT1_2), y1 = r.y + r.h;
        svg.innerHTML = `<path class="mz-cone" d="M${r.x} ${y1}L${L + o} ${ty + o}L${R - o} ${ty + o}L${r.x + r.w} ${y1}Z"/>` +
          `<path class="mz-cl" pathLength="1" d="M${r.x + 2} ${y1}L${L + o} ${ty + o}"/><path class="mz-cl" pathLength="1" d="M${r.x + r.w - 2} ${y1}L${R - o} ${ty + o}"/>` +
          `<rect class="mz-ring" pathLength="1" x="${r.x}" y="${r.y}" width="${r.w}" height="${r.h}" rx="7"/>`;
        from = { dx: r.x + r.w / 2 - cx, dy: r.y - ty, s: r.w / f.w };
      },
      enter() {
        if (RM.matches) return;
        drawIn(svg, 0);
        svg.querySelector('.mz-cone')?.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 600, delay: 350, fill: 'backwards' });
        const a = from ? [{ opacity: 0, transform: `translate(${from.dx}px, ${from.dy}px) scale(${from.s})` }, { opacity: 1, transform: 'none' }] : [{ opacity: 0, transform: 'scale(.9)' }, { opacity: 1, transform: 'none' }];
        wrap.animate(a, { duration: 900, delay: 220, easing: 'cubic-bezier(.25, 1.15, .4, 1)', fill: 'backwards' });
      },
    };
  });

  // 6. An annotation: a hairline from the real status item to the two numbers, written large.
  add('Annotation', 'mz-link mz-ann-o', el => {
    const svg = overlay(el), wrap = mk('mz-ann-w'), stage = mk('mz-stage mz-ann', K.data.map((s, si) => `<div class="mz-ac"><div class="mz-ah">${GL(si)}${num(si)}</div><div class="mz-al"><b>${s.name}</b>${WHO(si)}</div></div>`).join(''));
    wrap.append(stage); el.append(wrap);
    return {
      layout() {
        const w = el.clientWidth, h = el.clientHeight;
        const f = fitZoom(stage, w - 24, h - 86, 1, .5), b = placeOv(svg), it = realRect();
        const ix = it ? it.cx : b.x + b.w / 2, cx = clamp(ix, b.x + f.w / 2 + 6, b.x + b.w - f.w / 2 - 6);
        const ty = Math.max(b.y + (h - f.h) / 2 + 20, it ? it.y + it.h + 52 : 0), L = cx - f.w / 2, R = cx + f.w / 2;
        wrap.style.left = (L - b.x) + 'px'; wrap.style.top = (ty - b.y) + 'px';
        if (!it) { svg.innerHTML = ''; return; }
        const y0 = it.y + it.h + 5, yb = ty - 14, bl = Math.min(L + 4, ix), br = Math.max(R - 4, ix);
        svg.innerHTML = `<circle class="mz-dot" cx="${ix}" cy="${y0}" r="2.2"/><path class="mz-al1" pathLength="1" d="M${ix} ${y0}V${yb}"/>` +
          `<path class="mz-al2" pathLength="1" d="M${bl} ${yb + 7}V${yb}H${br}V${yb + 7}"/>`;
      },
      enter() {
        if (RM.matches) return;
        svg.querySelector('.mz-dot')?.animate([{ opacity: 0, transform: 'scale(0)' }, { opacity: 1, transform: 'none' }], { duration: 400, easing: EASE, fill: 'backwards' });
        drawIn(svg, 120);
        blurIn(stage.querySelectorAll('.mz-ah'), 620, 110);
        blurIn(stage.querySelectorAll('.mz-al'), 760, 110);
      },
    };
  });

  // 7. The status item's menu: the pointer opens it, picks another account, and the number follows.
  add('Menu open', 'mz-mn-o', el => {
    const stage = mk('mz-stage mz-mn mz-wall'); el.append(stage);
    let mode = '', P = null;
    const draw = m => {
      mode = m;
      stage.classList.toggle('sm', m === 'sm');
      stage.innerHTML = bar(m === 'sm' ? ['sp', 'st', 'bat', '#short'] : ['sp', 'st', 'bat', 'wifi', 'cc', '#short']) +
        `<div class="mz-pop">${K.data.map((s, si) => `<div class="mz-ph"><img src="assets/tools/${s.icon}.webp" alt="">${s.name}</div>` +
          s.accounts.map((a, ai) => `<div class="mz-pr${K.state[si] === ai ? ' on' : ''}" data-si="${si}" data-ai="${ai}">${CHECK}<span class="mz-pe">${a.email.split('@')[0]}</span><span class="mz-pb"><i style="width:${a.windows[0][1]}%;background:${s.color}"></i></span><span class="mz-pp">${a.windows[0][1]}%</span></div>`).join('')).join('<i class="mz-psep"></i>')}</div>${PTR}`;
    };
    const mark = () => stage.querySelectorAll('.mz-pr').forEach(r => r.classList.toggle('on', K.state[+r.dataset.si] === +r.dataset.ai));
    return {
      layout() {
        const w = el.clientWidth, m = w < 420 ? 'sm' : 'full';
        if (m !== mode) draw(m);
        fitZoom(stage, w - 16, H(el, 14, 250), 1.35, .8, () => {
          const st = stage.querySelector('.mz-st'), pop = stage.querySelector('.mz-pop'), s = pos(st, stage);
          pop.style.left = clamp(s.cx - pop.offsetWidth / 2, 6, stage.offsetWidth - pop.offsetWidth - 6) + 'px';
          const rows = [...stage.querySelectorAll('.mz-pr')].map(r => { const p = pos(r.querySelector('.mz-pe'), stage); return { r, x: p.x + Math.min(p.w, 70) * .6, y: p.cy + 2 }; });
          P = { st: { x: s.cx - 3, y: s.cy }, rows, rest: { x: stage.offsetWidth * .86, y: stage.offsetHeight - 22 } };
        });
      },
      sw: mark,
      async enter(ok) {
        const ptr = stage.querySelector('.mz-ptr'), st = stage.querySelector('.mz-st');
        const open = v => { stage.classList.toggle('open', v); st.classList.toggle('on', v); };
        const hover = r => stage.querySelectorAll('.mz-pr').forEach(x => x.classList.toggle('hov', x === r));
        const go = (p, ms) => { ptr.style.transitionDuration = ms + 'ms'; ptr.style.transform = `translate(${p.x.toFixed(1)}px, ${p.y.toFixed(1)}px)`; return sleep(ms + 40); };
        const click = async () => { ptr.classList.add('down'); await sleep(120); ptr.classList.remove('down'); await sleep(70); };
        mark();
        if (RM.matches) { open(true); ptr.style.opacity = 0; return; }
        open(false); hover(null); await go(P.rest, 0);
        for (let k = 0; ok(); k++) {
          await sleep(k ? 1500 : 700); if (!ok()) return;
          await go(P.st, 950); if (!ok()) return;
          await click(); open(true); await sleep(650); if (!ok()) return;
          const si = k % 2, ai = 1 - K.state[si], row = P.rows.find(r => +r.r.dataset.si === si && +r.r.dataset.ai === ai);
          await go(row, 800); hover(row.r); await sleep(380); if (!ok()) return;
          await click(); K.pick(si, ai); await sleep(1900); if (!ok()) return;
          hover(null); await go(P.rest, 950); await click(); open(false);
        }
      },
      leave() { stage.classList.remove('open'); stage.querySelector('.mz-st')?.classList.remove('on'); },
    };
  });

  // 8. Spotlight: a whole menu bar at real size; the rest dims and the status item lifts and grows in place.
  const DESK = { full: ['apple', '@Finder', 'File', 'Edit', 'sp', 'spk', 'st', 'bat', 'wifi', 'cc', '#mid'], sm: ['apple', 'sp', 'st', 'wifi', '#short'] };
  add('Spotlight', 'mz-spot-o', el => {
    const stage = mk('mz-stage mz-desk mz-spot mz-wall'); el.append(stage);
    let mode = '';
    const draw = m => { mode = m; stage.classList.toggle('sm', m === 'sm'); stage.innerHTML = bar(DESK[m]) + '<i class="mz-shade"></i>'; };
    return {
      layout() { const w = el.clientWidth, m = w < 470 ? 'sm' : 'full'; if (m !== mode) draw(m); fitZoom(stage, w - 16, H(el, 30), 1.1, .8); },
      async enter(ok) {
        stage.classList.remove('lit');
        if (RM.matches) { stage.classList.add('lit'); return; }
        rise(stage);
        for (let k = 0; ok(); k++) {
          await sleep(k ? 1700 : 1300); if (!ok()) return;
          stage.classList.add('lit'); await sleep(5600); if (!ok()) return;
          stage.classList.remove('lit');
        }
      },
      leave() { stage.classList.remove('lit'); },
    };
  });

  // 9. Magnifier: a reading glass glides along a real-size menu bar and rests on each number.
  add('Magnifier', 'mz-mag-o', el => {
    const stage = mk('mz-stage mz-mag'); el.append(stage);
    const R = 52, M = 2.2, TOP = 40, CY = 6 + 12;
    let mode = '', lens, cw, X = null, x = 0;
    const draw = m => {
      mode = m;
      const d = `<div class="mz-desk mz-bz mz-wall${m === 'sm' ? ' sm' : ''}">${bar(DESK[m])}</div>`;
      stage.innerHTML = d + `<div class="mz-lens"><div class="mz-lens-in"><div class="mz-cw"><div class="mz-copy" style="zoom:${M}">${d}</div></div></div><i class="mz-glass"></i></div>`;
      lens = stage.querySelector('.mz-lens'); cw = stage.querySelector('.mz-cw');
    };
    const put = v => { x = v; lens.style.transform = `translate(${(v - R).toFixed(2)}px, ${TOP + CY - R}px)`; cw.style.transform = `translate(${(R - M * v).toFixed(2)}px, ${(R - M * CY).toFixed(2)}px)`; };
    return {
      layout() {
        const w = el.clientWidth, m = w < 470 ? 'sm' : 'full';
        if (m !== mode) draw(m);
        fitZoom(stage, w - 16, H(el, 20), 1.1, .8, () => {
          const desk = stage.querySelector('.mz-desk'), g = s => pos(desk.querySelector(s), desk);
          const gl = [...desk.querySelectorAll('.mz-st .k-gl')].map(n => pos(n, desk)), ns = [...desk.querySelectorAll('.mz-st .mz-n')].map(n => pos(n, desk));
          X = { a: g('.mz-bar > :first-child').cx + 30, c0: (gl[0].x + ns[0].x + ns[0].w) / 2, c1: (gl[1].x + ns[1].x + ns[1].w) / 2, clk: g('.mz-clock').cx };
        });
        put(x || X.c0);
      },
      async enter(ok) {
        if (RM.matches) { put(X.c0); return; }
        put(X.a);
        rise(stage);
        const glide = async to => { const a = x, b = X[to]; await frames(ok, clamp(Math.abs(b - a) * 5.5, 650, 1900), t => put(a + (b - a) * inout(t))); };
        const path = [['c0', 2600], ['c1', 2600], ['clk', 1100], ['c1', 1500], ['c0', 1500], ['a', 900]];
        await sleep(500);
        while (ok()) for (const [to, dwell] of path) { await glide(to); if (!ok()) return; await sleep(dwell); if (!ok()) return; }
      },
    };
  });

  // 10. MacBook: a whole MacBook Pro, then the camera zooms into its menu bar and back out.
  const DOCK = ['icon-256', 'tools/claude-code', 'tools/openai', 'tools/cursor', 'tools/gemini-cli', 'tools/zed', 'tools/warp', 'tools/raycast', 'tools/notion'].map(p => `<img src="assets/${p}.webp" alt="">`).join('');
  add('MacBook zoom', 'mz-mbp-o', el => {
    const view = mk('mz-mbp'), cam = mk('mz-cam', `<div class="mz-lap"><div class="mz-lid"><div class="mz-scr mz-wall">${bar(['apple', '@Finder', 'File', 'Edit', 'View', 'Go', 'Window', 'Help', 'sp', 'bt', 'spk', 'st', 'bat', 'wifi', 'cc', '#full'], 'tall')}<div class="mz-dock">${DOCK}</div></div><i class="mz-notch"></i></div><i class="mz-base"></i></div>`);
    view.append(cam); el.append(view);
    let A = null, B = null, ph = 0;
    const set = c => { cam.style.transform = `translate(${c.x.toFixed(2)}px, ${c.y.toFixed(2)}px) scale(${c.s.toFixed(5)})`; };
    // A fixed point makes the move a pure zoom: the screen point under it never slides.
    const zoom = (ok, a, b, ms) => {
      const k = b.s - a.s, px = (a.x - b.x) / k, py = (a.y - b.y) / k, zx = a.x + a.s * px, zy = a.y + a.s * py;
      return frames(ok, ms, t => { const s = a.s * Math.pow(b.s / a.s, inout(t)); set({ s, x: zx - s * px, y: zy - s * py }); });
    };
    return {
      layout() {
        const vw = view.clientWidth, vh = view.clientHeight, lap = cam.firstElementChild, p = pos(cam.querySelector('.mz-st'), lap);
        // The close-up frames whole icons only, so each edge falls in the gap between two icons. Icon widths with
        // their 8 pt margins: Bluetooth 26, volume 34, battery 42, Wi-Fi 33, Control Center 32.
        const r = p.x + p.w + 5, spans = [[p.x - 4, r + 38], [p.x - 30, r + 71], [p.x - 56, r + 71], [p.x - 56, r + 103]];
        const [L, R] = spans.find(([a, b]) => vw / (b - a) <= 2.4) || spans[3];
        const sA = Math.min((vw - 40) / lap.offsetWidth, (vh - 28) / lap.offsetHeight), sB = vw / (R - L);
        A = { s: sA, x: (vw - lap.offsetWidth * sA) / 2, y: (vh - lap.offsetHeight * sA) / 2 + 2 };
        B = { s: sB, x: vw / 2 - sB * (L + R) / 2, y: vh * .42 - sB * p.cy };
        set(ph ? B : A); view.classList.toggle('in', !!ph);
      },
      async enter(ok) {
        if (RM.matches) { ph = 1; set(B); view.classList.add('in'); return; }
        ph = 0; set(A); view.classList.remove('in'); rise(view);
        await sleep(1300);
        while (ok()) {
          view.classList.add('in'); await zoom(ok, A, B, 2100); if (!ok()) return; ph = 1;
          await sleep(5200); if (!ok()) return;
          view.classList.remove('in'); await zoom(ok, B, A, 1800); if (!ok()) return; ph = 0;
          await sleep(2400);
        }
      },
      leave() { ph = 0; if (A) set(A); view.classList.remove('in'); },
    };
  });

  // 11. Actual size: the status item large, over the same item at its real size.
  add('Actual size', 'mz-act-o', el => {
    const stage = mk('mz-stage mz-act', `<svg class="mz-act-ln" aria-hidden="true"></svg><div class="mz-act-bw"><div class="mz-act-big">${ST()}</div></div><div class="mz-act-ref"><div class="mz-act-bar mz-wall">${bar(['spk', 'st', 'bat', 'wifi'])}</div><span>Actual size</span></div>`);
    el.append(stage);
    const bw = stage.querySelector('.mz-act-bw'), big = stage.querySelector('.mz-act-big'), svg = stage.querySelector('svg');
    return {
      layout() {
        big.style.zoom = clamp((el.clientWidth - 40) / 110, 1.6, 3.2).toFixed(3);
        // The real-size bar shifts so its status item sits right under the large one.
        const ref = stage.querySelector('.mz-act-ref'), sm = ref.querySelector('.mz-st');
        ref.style.left = '0px'; ref.style.left = (pos(bw, stage).cx - pos(sm, stage).cx).toFixed(1) + 'px';
        const z = +big.style.zoom, b = pos(bw, stage), s = pos(sm, stage), o = 7 * z * (1 - Math.SQRT1_2), y1 = b.y + b.h - o;
        svg.setAttribute('viewBox', `0 0 ${stage.offsetWidth} ${stage.offsetHeight}`);
        svg.innerHTML = `<path class="mz-cone" d="M${s.x + 2} ${s.y}L${b.x + o} ${y1}L${b.x + b.w - o} ${y1}L${s.x + s.w - 2} ${s.y}Z"/><path class="mz-cl" pathLength="1" d="M${s.x + 2} ${s.y}L${b.x + o} ${y1}"/><path class="mz-cl" pathLength="1" d="M${s.x + s.w - 2} ${s.y}L${b.x + b.w - o} ${y1}"/>`;
      },
      enter() {
        if (RM.matches) return;
        svg.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 700, delay: 1100, easing: EASE, fill: 'backwards' });
        const a = stage.querySelector('.mz-act-bar .mz-st').getBoundingClientRect(), b = big.getBoundingClientRect();
        bw.animate([{ transform: `translate(${a.left + a.width / 2 - (b.left + b.width / 2)}px, ${a.top + a.height / 2 - (b.top + b.height / 2)}px) scale(${a.width / b.width})`, opacity: .4 }, { transform: 'none', opacity: 1 }], { duration: 1000, delay: 450, easing: 'cubic-bezier(.25, 1.1, .35, 1)', fill: 'backwards' });
        rise(stage.querySelector('.mz-act-ref'));
      },
    };
  });

  // 12. Pop-out: the menu bar laid back in perspective, the status item standing up out of it.
  add('Pop-out', 'mz-3d-o', el => {
    const stage = mk('mz-stage mz-3d', `<div class="mz-3d-pl"><div class="mz-rib mz-wall">${bar(['apple', '@Finder', 'File', 'Edit', 'View', 'sp', 'bt', 'spk', 'ghost', 'bat', 'wifi', 'cc', '#mid'])}</div></div><div class="mz-3d-up"><div class="mz-3d-it">${ST()}</div></div>`);
    el.append(stage);
    const up = stage.querySelector('.mz-3d-up'), it = stage.querySelector('.mz-3d-it'), rib = stage.querySelector('.mz-rib');
    let raf = 0;
    return {
      layout() {
        const w = el.clientWidth;
        stage.classList.toggle('sm', w < 470);
        fitZoom(stage, w - 8, H(el, 16), 1.2, .62, () => {
          const ghost = stage.querySelector('.mz-ghost'), g = pos(ghost, rib);
          rib.style.left = (stage.offsetWidth / 2 - g.cx) + 'px';
          rib.style.transformOrigin = `${g.cx}px 50%`;
          // The ghost's projected box: client rects include the perspective; k undoes any ancestor scale.
          const a = ghost.getBoundingClientRect(), s = stage.getBoundingClientRect(), k = s.width / stage.offsetWidth;
          const gx = (a.left + a.width / 2 - s.left) / k, gy = (a.top + a.height / 2 - s.top) / k;
          stage.style.setProperty('--gx', gx.toFixed(1) + 'px'); stage.style.setProperty('--gy', gy.toFixed(1) + 'px');
        });
      },
      enter(ok) {
        if (RM.matches) return;
        rise(stage);
        it.animate([{ transform: 'translateY(12px) scale(.5)', opacity: 0 }, { transform: 'none', opacity: 1 }], { duration: 1100, delay: 500, easing: 'cubic-bezier(.3, 1.35, .5, 1)', fill: 'backwards' });
        const t0 = performance.now();
        const f = now => { if (!ok()) return; const s = Math.sin((now - t0) / 1000 * Math.PI * 2 / 4.2); up.style.translate = `0 ${(s * 3).toFixed(2)}px`; raf = requestAnimationFrame(f); };
        raf = requestAnimationFrame(f);
      },
      leave() { cancelAnimationFrame(raf); up.style.translate = ''; },
    };
  });

  // 13. Light and dark: one menu bar in both appearances, split by a handle that sweeps (and can be dragged).
  add('Light and dark', 'mz-ld-o', el => {
    const stage = mk('mz-stage mz-ld'); el.append(stage);
    let mode = '', x = .5, held = 0;
    const draw = m => {
      mode = m;
      stage.classList.toggle('sm', m === 'sm');
      const k = m === 'sm' ? ['st', 'wifi'] : ['spk', 'st', 'bat', 'wifi', 'cc'];
      stage.innerHTML = `<div class="mz-ld-a mz-wall">${bar(k)}<span class="mz-ld-t">Light</span></div><div class="mz-ld-b mz-dark mz-wall-d">${bar(k)}<span class="mz-ld-t">Dark</span></div><div class="mz-ld-h" data-noedit><i></i></div>`;
      const h = stage.querySelector('.mz-ld-h');
      h.addEventListener('pointerdown', e => {
        e.preventDefault(); e.stopPropagation(); h.setPointerCapture(e.pointerId); held = 1;
        const move = ev => { const r = stage.getBoundingClientRect(); put(clamp((ev.clientX - r.left) / r.width, .04, .96)); };
        const upf = () => { h.removeEventListener('pointermove', move); held = performance.now(); };
        h.addEventListener('pointermove', move); h.addEventListener('pointerup', upf, { once: true }); h.addEventListener('pointercancel', upf, { once: true });
      });
      h.addEventListener('click', e => e.stopPropagation());
      put(x);
    };
    const put = v => { x = v; stage.style.setProperty('--x', (v * 100).toFixed(2) + '%'); };
    return {
      layout() { const w = el.clientWidth, m = w < 470 ? 'sm' : 'full'; if (m !== mode) draw(m); fitZoom(stage, w - 16, H(el, 30), 2, 1); },
      async enter(ok) {
        put(.5); held = 0;
        if (RM.matches) return;
        rise(stage);
        await sleep(900);
        const ends = [.26, .74];
        for (let k = 0; ok(); k++) {
          while (held && (held === 1 || performance.now() - held < 3500)) { await sleep(300); if (!ok()) return; }
          held = 0;
          const a = x, b = ends[k % 2];
          await frames(() => ok() && !held, 2400, t => put(a + (b - a) * inout(t))); if (!ok()) return;
          await sleep(1500);
        }
      },
    };
  });

  // 14. Night: the display corner in dark mode.
  add('Night', 'mz-cor-o mz-night-o', corner(true));

  // 15. Every app: apps come forward with Command-Tab and the app menus change; the status item stays put.
  const APPS = [['Cursor', 'cursor', 'File', 'Edit', 'Selection'], ['Warp', 'warp', 'File', 'Edit', 'View'], ['Zed', 'zed', 'File', 'Edit', 'Selection'], ['Claude', 'claude-code', 'File', 'Edit', 'View'], ['Notion', 'notion', 'File', 'Edit', 'View']];
  add('Every app', 'mz-app-o', el => {
    const stage = mk('mz-stage mz-desk mz-app mz-wall'); el.append(stage);
    let mode = '', k = 0, grp = null, cmd = null;
    const menus = () => items(['@' + APPS[k][0], ...APPS[k].slice(2, mode === 'sm' ? 2 : 5)]);
    const draw = m => {
      mode = m;
      stage.classList.toggle('sm', m === 'sm');
      stage.innerHTML = `<div class="mz-bar">${item('apple')}<span class="mz-apps">${menus()}</span>${item('sp')}${items(m === 'sm' ? ['st', '#short'] : ['st', 'wifi', '#short'])}</div>` +
        `<div class="mz-cmd"><div class="mz-cmd-in"><i class="mz-cmd-sel"></i>${APPS.map(a => `<img src="assets/tools/${a[1]}.webp" alt="">`).join('')}</div><span class="mz-cmd-n">${APPS[k][0]}</span></div>`;
      grp = stage.querySelector('.mz-apps'); cmd = stage.querySelector('.mz-cmd');
    };
    const sel = j => { cmd.style.setProperty('--j', j); cmd.querySelector('.mz-cmd-n').textContent = APPS[j][0]; };
    return {
      layout() { const w = el.clientWidth, m = w < 470 ? 'sm' : 'full'; if (m !== mode) draw(m); fitZoom(stage, w - 16, H(el, 30), 1.3, .8); },
      async enter(ok) {
        if (k) { k = 0; grp.innerHTML = menus(); }
        cmd.classList.remove('on');
        if (RM.matches) return;
        rise(stage);
        while (ok()) {
          await sleep(2300); if (!ok()) return;
          const n = (k + 1) % APPS.length;
          sel(k); cmd.classList.add('on'); await sleep(520); if (!ok()) return;
          sel(n); await sleep(720); if (!ok()) return;
          cmd.classList.remove('on');
          await grp.animate([{ opacity: 1, filter: 'blur(0)' }, { opacity: 0, filter: 'blur(4px)' }], { duration: 150, easing: 'ease-in' }).finished;
          if (!ok()) return;
          k = n; grp.innerHTML = menus();
          blurIn(grp.children, 0, 45);
        }
      },
      leave() { cmd?.classList.remove('on'); },
    };
  });
  // Running only the shown design, only on screen ------------------------------------------------------------
  let cur = 0, seen = false, active = null;
  const live = o => { const t = ++o.t; return () => o.t === t && active === o && seen; };
  function sync() {
    const o = seen ? opts[cur] : null;
    if (o === active) return;
    if (active) { active.t++; active.leave?.(); }
    active = o;
    if (o) { o.layout?.(); o.enter?.(live(o)); }
  }
  root.addEventListener('vary', e => {
    cur = +e.detail;
    if (active && active !== opts[cur]) { active.t++; active.leave?.(); active = null; }
    opts[cur]?.layout?.();
    sync();
  });
  new IntersectionObserver(es => { seen = es[es.length - 1].isIntersecting; sync(); }, { threshold: .3 }).observe(tile);
  let rq = 0;
  const relayout = () => { if (rq) return; rq = requestAnimationFrame(() => { rq = 0; opts[cur]?.layout?.(); }); };
  new ResizeObserver(relayout).observe(root);
  addEventListener('resize', relayout);
  document.fonts?.ready.then(relayout);

  const press = n => { n.classList.remove('hit'); void n.offsetWidth; n.classList.add('hit'); };
  document.addEventListener('k-switch', e => {
    const { si, pct: p, who: w } = e.detail;
    root.querySelectorAll(`.mz-n[data-si="${si}"]`).forEach(n => setNum(n, p));
    root.querySelectorAll(`.mz-who[data-si="${si}"]`).forEach(n => swapText(n, w));
    if (active) { active.el.querySelectorAll('.mz-st').forEach(press); active.sw?.(e.detail); }
  });

  // On narrow screens the tile's menu bar drops app menus, as macOS does, so the status item stays visible.
  const clk = tile.querySelector('.mb-clock'), clkFull = clk && clk.innerHTML;
  const fitClock = () => { if (clk) clk.innerHTML = NARROW.matches ? CLK.short : clkFull; relayout(); };
  NARROW.addEventListener('change', fitClock);
  fitClock();
})();
