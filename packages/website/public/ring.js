// Limits, live (bento tile): design options for the vary.js picker. Styles live in ring.css.
// Every option tells one story: ada.lovelace drains live, runs low, and Switch moves Claude Code to
// katherine.johnson before the limit. Only the shown option animates, and only while it is on screen.
(() => {
  const host = document.querySelector('[data-limring]');
  if (!host) return;
  const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const LOW = 5, FROM = 76, TO = 65;
  const INK = '#1D1D1F', CL = '#D97757', CX = '#10A37F', RED = '#E5484D';
  const ADA = 'ada.lovelace', KAT = 'katherine.johnson', GRACE = 'grace.hopper', LINUS = 'linus.torvalds';
  const IMG = { cc: 'assets/tools/claude-code.webp', cx: 'assets/tools/openai.webp', sw: 'assets/icon-256.webp' };
  const GL = { cc: 'url(assets/glyphs/claude.svg)', cx: 'url(assets/glyphs/openai.svg)' };
  const SVC = { cc: 'Claude Code', cx: 'Codex CLI' };

  const lerp = (a, b, t) => a + (b - a) * t;
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const mix = (a, b, t) => { const x = hex(a), y = hex(b); return `rgb(${x.map((v, i) => Math.round(lerp(v, y[i], t))).join(',')})`; };
  // Low is a calm shift toward red between 15% and 5% left, never a flash.
  const lowT = v => clamp((15 - v) / 10, 0, 1);
  const tint = (c, v) => mix(c, RED, lowT(v));
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const E = {
    lin: t => t,
    in: t => t * t * t,
    out: t => 1 - Math.pow(1 - t, 3),
    out5: t => 1 - Math.pow(1 - t, 5),
    io: t => (t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
    // Damped springs on a 0..1 clock: about 6% and 18% overshoot.
    spring: t => 1 - Math.exp(-7 * t) * (Math.cos(8 * t) + 7 / 8 * Math.sin(8 * t)),
    bounce: t => 1 - Math.exp(-6.5 * t) * (Math.cos(12 * t) + 6.5 / 12 * Math.sin(12 * t)),
  };
  // Usage burns in bursts: monotonic, with faster and slower stretches.
  const burst = t => { const u = E.io(t); return u - Math.sin(u * Math.PI * 8) / (Math.PI * 8) * .55; };

  const STOP = Symbol('stop');
  let run = 0;
  const ctxFor = g => {
    const alive = () => g === run;
    const wait = ms => new Promise((res, rej) => setTimeout(() => (alive() ? res() : rej(STOP)), ms));
    const tw = (ms, fn, ease = E.out) => new Promise((res, rej) => {
      let t0 = 0;
      const f = now => {
        if (!alive()) return rej(STOP);
        if (!t0) t0 = now;
        const t = Math.min(1, (now - t0) / ms);
        fn(ease(t), t);
        if (t < 1) requestAnimationFrame(f); else res();
      };
      requestAnimationFrame(f);
    });
    const frame = fn => {
      let last = 0;
      const f = now => { if (!alive()) return; const dt = last ? Math.min(.05, (now - last) / 1000) : 1 / 60; last = now; fn(dt, now / 1000); requestAnimationFrame(f); };
      requestAnimationFrame(f);
    };
    return { alive, wait, tw, frame };
  };

  // Applies a state with transitions off, so a reset never animates.
  const snap = (st, fn) => { st.classList.add('lr-snap'); fn(); void st.offsetWidth; st.classList.remove('lr-snap'); };
  const put = (el, s) => { el.getAnimations().forEach(a => a.cancel()); el.textContent = s; };
  const BLUR_OUT = [{ opacity: 1, filter: 'blur(0px)', transform: 'none' }, { opacity: 0, filter: 'blur(4px)', transform: 'translateY(-4px)' }];
  const BLUR_IN = [{ opacity: 0, filter: 'blur(4px)', transform: 'translateY(5px)' }, { opacity: 1, filter: 'blur(0px)', transform: 'none' }];
  async function swap(ctx, el, s) {
    if (el.textContent === s) return;
    await el.animate(BLUR_OUT, { duration: 180, easing: 'cubic-bezier(.4,0,1,1)', fill: 'forwards' }).finished.catch(() => {});
    if (!ctx.alive()) return;
    put(el, s);
    el.animate(BLUR_IN, { duration: 480, easing: 'cubic-bezier(.22,1,.36,1)' });
  }
  const spell = (el, s) => { el.getAnimations({ subtree: true }).forEach(a => a.cancel()); el.innerHTML = [...s].map(c => `<span>${c}</span>`).join(''); };
  // Letters leave and arrive one by one, with a short blur.
  async function respell(ctx, el, s, gap = 14) {
    const old = [...el.children];
    old.forEach((c, i) => c.animate([{ opacity: 1, transform: 'none', filter: 'blur(0px)' }, { opacity: 0, transform: 'translateY(-.32em)', filter: 'blur(3px)' }], { duration: 200, delay: i * gap * .5, easing: 'cubic-bezier(.4,0,1,1)', fill: 'forwards' }));
    await sleep(200 + old.length * gap * .5);
    if (!ctx.alive()) return;
    spell(el, s);
    [...el.children].forEach((c, i) => c.animate([{ opacity: 0, transform: 'translateY(.42em)', filter: 'blur(4px)' }, { opacity: 1, transform: 'none', filter: 'blur(0px)' }], { duration: 580, delay: i * gap, easing: 'cubic-bezier(.22,1,.36,1)', fill: 'backwards' }));
  }
  const HID = { opacity: 0, filter: 'blur(6px)', transform: 'scale(.985)' }, SHOWN = { opacity: 1, filter: 'blur(0px)', transform: 'none' };
  async function fade(ctx, st, out) {
    const a = st.animate(out ? [SHOWN, HID] : [HID, SHOWN], { duration: out ? 380 : 620, easing: out ? 'cubic-bezier(.4,0,1,1)' : 'cubic-bezier(.22,1,.36,1)', fill: out ? 'forwards' : 'none' });
    await a.finished.catch(() => {});
    if (!ctx.alive()) throw STOP;
  }

  // Rolling digits: each column chases its odometer value, so 70 to 69 rolls one step, never the long way.
  function Roll(el, n) {
    const strip = `<span class="lr-rs">${[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0].map(d => `<i>${d}</i>`).join('')}</span>`;
    el.classList.add('lr-roll');
    el.innerHTML = `<span class="lr-rc">${strip}</span><span class="lr-rc">${strip}</span>`;
    const cols = [...el.children].map((c, k) => ({ c, s: c.firstChild, d: k ? 1 : 10, p: 0 }));
    let target = n, raf = 0, last = 0;
    const paint = () => cols.forEach(o => { const d = ((o.p % 10) + 10) % 10; o.s.style.transform = `translateY(${(-d / 11 * 100).toFixed(3)}%)`; });
    const step = now => {
      const dt = last ? Math.min(.05, (now - last) / 1000) : 1 / 60;
      last = now;
      let moving = false;
      cols.forEach(o => {
        const v = Math.floor(target / o.d);
        if (Math.abs(v - o.p) > 12) o.p = v - Math.sign(v - o.p) * 12;
        o.p += (v - o.p) * (1 - Math.exp(-dt * 13));
        if (Math.abs(v - o.p) < .003) o.p = v; else moving = true;
      });
      paint();
      if (moving) raf = requestAnimationFrame(step); else { raf = 0; last = 0; }
    };
    const api = {
      set(v, now) {
        target = clamp(Math.round(v), 0, 99);
        cols[0].c.classList.toggle('z', target < 10);
        if (now) { cancelAnimationFrame(raf); raf = 0; last = 0; cols.forEach(o => { o.p = Math.floor(target / o.d); }); paint(); }
        else if (!raf) raf = requestAnimationFrame(step);
      },
    };
    api.set(n, true);
    return api;
  }

  // A split-flap cell: the top half falls, then the bottom half lands.
  function Flap(el, ch) {
    el.classList.add('lr-fp');
    el.innerHTML = '<span class="lr-fp-t"><b></b></span><span class="lr-fp-b"><b></b></span><span class="lr-fp-ft"><b></b></span><span class="lr-fp-fb"><b></b></span>';
    const [T, B, FT, FB] = [...el.children], [t, b, ft, fb] = [T, B, FT, FB].map(x => x.firstChild);
    let cur = ch, want = ch, busy = false, gen = 0;
    const show = c => { t.textContent = b.textContent = ft.textContent = fb.textContent = c; };
    const flip = async (to, ms, g) => {
      t.textContent = to; ft.textContent = cur; b.textContent = cur; fb.textContent = to;
      FT.style.visibility = 'visible';
      await FT.animate([{ transform: 'rotateX(0deg)', filter: 'brightness(1)' }, { transform: 'rotateX(-90deg)', filter: 'brightness(.6)' }], { duration: ms, easing: 'cubic-bezier(.55,0,.85,.35)' }).finished.catch(() => {});
      if (g !== gen) return false;
      FT.style.visibility = 'hidden'; FB.style.visibility = 'visible';
      await FB.animate([{ transform: 'rotateX(90deg)', filter: 'brightness(1.5)' }, { transform: 'rotateX(0deg)', filter: 'brightness(1)' }], { duration: ms * 1.15, easing: 'cubic-bezier(.2,.75,.35,1.12)' }).finished.catch(() => {});
      if (g !== gen) return false;
      b.textContent = to; FB.style.visibility = 'hidden'; cur = to;
      return true;
    };
    const pump = async (ms, g) => { busy = true; while (want !== cur && g === gen) { if (!(await flip(want, ms, g))) break; } if (g === gen) busy = false; };
    show(ch); FT.style.visibility = FB.style.visibility = 'hidden';
    return {
      set(c, ms = 85) { want = c; if (!busy) pump(ms, gen); },
      async spin(c, n, ms = 70) { const g = gen; busy = true; const L = 'abcdefghijklmnopqrstuvwxyz.'; for (let k = 0; k < n && g === gen; k++) if (!(await flip(L[(Math.random() * L.length) | 0], ms, g))) return; want = c; if (g === gen) { busy = false; pump(ms, g); } },
      now(c) { gen++; busy = false; [T, B, FT, FB].forEach(x => x.getAnimations().forEach(a => a.cancel())); cur = want = c; show(c); FT.style.visibility = FB.style.visibility = 'hidden'; },
    };
  }

  const src = k => `<span class="lr-src"><img src="${IMG[k]}" alt="">${SVC[k]}</span>`;
  const ck = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2 6.4 4.8 9 10 3" pathLength="1"/></svg>';

  // 1. A large rolling numeral over a hairline.
  const num = {
    id: 'num', name: 'Numeral',
    html: `<div class="lr-nm"><div class="lr-nm-hd">${src('cc')}<span class="lr-src lr-nm-msg"><img src="${IMG.sw}" alt="">Switched before the limit</span></div>` +
      '<div class="lr-nm-big"><span class="lr-r"></span><span class="lr-nm-pc">%</span></div><div class="lr-nm-bar"><i></i><u></u></div>' +
      '<div class="lr-nm-ft"><span class="lr-nm-who lr-sp"></span><span class="lr-nm-sub">Session left</span></div></div>',
    make(st) {
      const $ = s => st.querySelector(s), roll = Roll($('.lr-r'), FROM), big = $('.lr-nm-big'), bar = $('.lr-nm-bar i'), who = $('.lr-nm-who'), sub = $('.lr-nm-sub'), hd = $('.lr-nm-hd');
      const fill = v => { bar.style.clipPath = `inset(0 ${(100 - v).toFixed(2)}% 0 0 round 2px)`; bar.style.background = tint(CL, v); big.style.color = mix(INK, RED, lowT(v)); };
      const state = (v, w, x) => { roll.set(v, true); fill(v); spell(who, w); put(sub, 'Session left'); sub.classList.remove('lr-lo'); hd.classList.toggle('lr-x', x); };
      return {
        reset: () => snap(st, () => state(FROM, ADA, false)),
        final: () => snap(st, () => state(TO, KAT, true)),
        v(v, ctx) { roll.set(v); fill(v); if (v <= 10 && !sub.classList.contains('lr-lo')) { sub.classList.add('lr-lo'); swap(ctx, sub, 'Almost out'); } },
        async hand(ctx) {
          hd.classList.add('lr-x');
          sub.classList.remove('lr-lo'); swap(ctx, sub, 'Session left');
          await respell(ctx, who, KAT);
          roll.set(TO);
          await ctx.tw(1300, e => fill(lerp(LOW, TO, e)), E.spring);
        },
        v2(v) { roll.set(v); fill(v); },
      };
    },
  };

  // 2. Activity rings, one per tool. The Claude Code ring spins back in for the next account.
  const rings = {
    id: 'rings', name: 'Rings',
    html: `<div class="lr-rg"><div class="lr-rg-d"><svg viewBox="0 0 120 120" aria-hidden="true">` +
      `<circle class="lr-rg-t" cx="60" cy="60" r="52" style="stroke:${CL}"/><circle class="lr-rg-a" cx="60" cy="60" r="52" pathLength="100"/>` +
      `<circle class="lr-rg-t" cx="60" cy="60" r="37" style="stroke:${CX}"/><circle class="lr-rg-a" cx="60" cy="60" r="37" pathLength="100" style="stroke:${CX}"/></svg>` +
      `<i class="lr-gl lr-rg-g" style="--g:${GL.cc};top:6.67%"></i><i class="lr-gl lr-rg-g" style="--g:${GL.cx};top:19.17%"></i></div><div class="lr-rg-lg">` +
      [['cc', CL, ADA], ['cx', CX, GRACE]].map(([k, c, w]) => `<div class="lr-rg-it" style="--c:${c}"><span class="lr-rg-k">${SVC[k]}</span><b><span class="lr-r"></span>%</b><span class="lr-rg-w">${w}</span></div>`).join('') + '</div></div>',
    make(st) {
      const arcs = st.querySelectorAll('.lr-rg-a'), gls = st.querySelectorAll('.lr-rg-g'), rolls = [...st.querySelectorAll('.lr-r')].map((el, i) => Roll(el, i ? 59 : FROM)), ws = st.querySelectorAll('.lr-rg-w');
      const arc = (i, v, rot = -90) => { const a = arcs[i]; a.style.strokeDasharray = `${Math.max(0, v).toFixed(2)} 200`; a.style.opacity = v > .4 ? 1 : 0; a.setAttribute('transform', `rotate(${rot.toFixed(2)} 60 60)`); gls[i].style.opacity = v > 4 && rot > -100 ? 1 : 0; };
      const cx = v => 59 - (FROM - v) / (FROM - LOW) * 4;
      const paint = (v, c) => { arc(0, v); arcs[0].style.stroke = tint(CL, v); rolls[0].set(v); arc(1, c); rolls[1].set(c); };
      return {
        reset: () => snap(st, () => { paint(FROM, 59); rolls.forEach((r, i) => r.set(i ? 59 : FROM, true)); put(ws[0], ADA); }),
        final: () => snap(st, () => { paint(TO, 55); rolls.forEach((r, i) => r.set(i ? 55 : TO, true)); put(ws[0], KAT); }),
        v(v) { paint(v, cx(v)); },
        async hand(ctx) {
          await ctx.tw(340, e => arc(0, LOW * (1 - e)), E.out);
          arcs[0].style.stroke = CL;
          swap(ctx, ws[0], KAT); rolls[0].set(TO);
          await ctx.tw(1500, e => arc(0, TO * e, -90 - 360 * (1 - e)), E.out5);
        },
        v2(v) { arc(0, v); rolls[0].set(v); },
      };
    },
  };

  // 3. macOS battery glyphs on a rail. The spent one slides away and the next one takes the middle.
  const bat = {
    id: 'bat', name: 'Battery',
    html: `<div class="lr-bt"><div class="lr-bt-hd">${src('cc')}</div><div class="lr-bt-rl">` + [[ADA, 'Session · in use'], [KAT, 'Session · up next']].map(([w, s]) =>
      `<div class="lr-bt-c"><div class="lr-bt-g"><div class="lr-bt-b"><span class="lr-bt-n"><b></b><small>%</small></span><div class="lr-bt-k"><i></i><span class="lr-bt-n"><b></b><small>%</small></span></div></div><i class="lr-bt-nub"></i></div><b class="lr-bt-w">${w}</b><span class="lr-bt-s">${s}</span></div>`).join('') + '</div></div>',
    make(st) {
      const rl = st.querySelector('.lr-bt-rl'), cs = [...st.querySelectorAll('.lr-bt-c')], ss = cs.map(c => c.querySelector('.lr-bt-s'));
      const lvl = (i, v) => { const k = cs[i].querySelector('.lr-bt-k'); k.style.clipPath = `inset(0 ${(100 - v).toFixed(2)}% 0 0 round 10px)`; k.firstChild.style.background = tint(CL, v); cs[i].querySelectorAll('.lr-bt-n b').forEach(b => { b.textContent = Math.round(v); }); };
      const at = p => {
        const W = rl.clientWidth, g = Math.min(196, W * .5);
        cs.forEach((c, i) => { const d = i - p, a = Math.min(1, Math.abs(d)); c.style.transform = `translateX(${(W / 2 + d * g).toFixed(1)}px) translateX(-50%) scale(${(1 - .22 * a).toFixed(4)})`; c.style.opacity = (1 - .45 * a).toFixed(3); c.style.setProperty('--lab', clamp(1 - a * 1.6, 0, 1).toFixed(3)); });
      };
      const state = (p, a, s0, s1) => { lvl(0, a); lvl(1, TO); at(p); put(ss[0], s0); put(ss[1], s1); };
      return {
        reset: () => snap(st, () => state(0, FROM, 'Session · in use', 'Session · up next')),
        final: () => snap(st, () => state(1, LOW, 'Resets in 3h 19m', 'Session · in use')),
        v(v) { lvl(0, v); },
        async hand(ctx) { swap(ctx, ss[0], 'Resets in 3h 19m'); swap(ctx, ss[1], 'Session · in use'); await ctx.tw(1200, e => at(e), E.spring); },
        v2(v) { lvl(1, v); },
      };
    },
  };

  // 4. A rounded tank with a live wave surface. It refills with a slosh for the next account.
  const liq = {
    id: 'liq', name: 'Liquid',
    html: `<div class="lr-lq"><div class="lr-lq-tk"><svg viewBox="0 0 100 100" aria-hidden="true"><defs><clipPath id="lr-lq-r"><rect width="100" height="100" rx="25"/></clipPath><clipPath id="lr-lq-w"><path/></clipPath></defs>` +
      '<g clip-path="url(#lr-lq-r)"><rect class="lr-lq-bg" width="100" height="100"/><path class="lr-lq-b"/><path class="lr-lq-f"/></g>' +
      '<text class="lr-lq-t" x="50" y="58" text-anchor="middle"><tspan></tspan><tspan class="lr-lq-p" dx="1">%</tspan></text>' +
      '<g clip-path="url(#lr-lq-w)"><text class="lr-lq-t lr-lq-wt" x="50" y="58" text-anchor="middle"><tspan></tspan><tspan class="lr-lq-p" dx="1">%</tspan></text></g>' +
      '<rect class="lr-lq-rim" x=".5" y=".5" width="99" height="99" rx="24.5"/></svg></div>' +
      `<div class="lr-lq-cap">${src('cc')}<b class="lr-lq-who lr-sp"></b><span class="lr-lq-s">Session left</span><span class="lr-lq-th">Switches at 5% left</span></div></div>`,
    make(st) {
      const $ = s => st.querySelector(s), fp = $('.lr-lq-f'), bp = $('.lr-lq-b'), cp = $('#lr-lq-w path'), nums = st.querySelectorAll('.lr-lq-t tspan:first-child'), who = $('.lr-lq-who'), sub = $('.lr-lq-s');
      let lvl = FROM, tgt = FROM, amp = 2, ampT = 2, ph = 0, spd = 1.7, shown = FROM;
      const wave = (y0, a, k, p) => { let d = `M0 ${(y0 + a * Math.sin(p)).toFixed(2)}`; for (let x = 4; x <= 100; x += 4) d += `L${x} ${(y0 + a * Math.sin(x / 100 * Math.PI * 2 * k + p)).toFixed(2)}`; return d + 'L100 102L0 102Z'; };
      const draw = () => { const y0 = 100 - lvl, f = wave(y0, amp, 1.1, ph); fp.setAttribute('d', f); cp.setAttribute('d', f); bp.setAttribute('d', wave(y0 - 1.8, amp * .85, .8, -ph * .75 + 2.1)); };
      const color = v => { const c = tint(CL, v); fp.style.fill = c; bp.style.fill = c; };
      const n = v => { const r = Math.round(v); if (r !== shown) { shown = r; nums.forEach(t => { t.textContent = r; }); } };
      const state = (v, w) => { lvl = tgt = v; amp = ampT = 2; spd = 1.7; shown = -1; n(v); color(v); spell(who, w); put(sub, 'Session left'); sub.classList.remove('lr-lo'); draw(); };
      return {
        begin(ctx) { ctx.frame(dt => { ph += dt * spd; amp += (ampT - amp) * (1 - Math.exp(-dt * 1.5)); lvl += (tgt - lvl) * (1 - Math.exp(-dt * 7)); draw(); }); },
        reset: () => state(FROM, ADA),
        final: () => state(TO, KAT),
        v(v, ctx) { tgt = v; n(v); color(v); if (v <= 10 && !sub.classList.contains('lr-lo')) { sub.classList.add('lr-lo'); swap(ctx, sub, 'Almost out'); } },
        async hand(ctx) {
          sub.classList.remove('lr-lo'); swap(ctx, sub, 'Session left');
          respell(ctx, who, KAT);
          amp = 7; spd = 3.4;
          await ctx.tw(1700, e => { const v = lerp(LOW, TO, e); tgt = v; n(v); color(v); spd = lerp(3.4, 1.7, e); }, E.out);
        },
        v2(v) { tgt = v; n(v); },
      };
    },
  };

  // 5. Twenty segments, five percent each. They switch off one by one, then refill in a wave.
  const seg = {
    id: 'seg', name: 'Segments',
    html: `<div class="lr-sg"><div class="lr-sg-hd"><b class="lr-sg-n"><span class="lr-r"></span><small>%</small></b><span class="lr-sg-id"><b class="lr-sg-who lr-sp"></b>${src('cc')}</span></div>` +
      `<div class="lr-sg-bars">${'<i></i>'.repeat(20)}</div><div class="lr-sg-ax"><span>Switches at 5%</span><span>100%</span></div></div>`,
    make(st) {
      const bars = [...st.querySelectorAll('.lr-sg-bars i')], roll = Roll(st.querySelector('.lr-r'), FROM), who = st.querySelector('.lr-sg-who'), n0 = st.querySelector('.lr-sg-n');
      const lit = v => {
        const n = v > 0 ? Math.max(1, Math.round(v / 5)) : 0, c = n <= 2 ? RED : CL;
        bars.forEach((b, i) => { b.classList.toggle('lr-on', i < n); b.style.setProperty('--c', c); });
        n0.style.color = mix(INK, RED, lowT(v));
      };
      const state = (v, w) => { bars.forEach(b => { b.style.transitionDelay = ''; }); lit(v); roll.set(v, true); spell(who, w); };
      return {
        reset: () => snap(st, () => state(FROM, ADA)),
        final: () => snap(st, () => state(TO, KAT)),
        v(v) { lit(v); roll.set(v); },
        async hand(ctx) {
          respell(ctx, who, KAT);
          roll.set(TO);
          bars.forEach((b, i) => { b.style.transitionDelay = `${Math.max(0, i - 1) * 42}ms`; });
          lit(TO);
          bars.slice(1, 13).forEach((b, i) => b.animate([{ transform: 'scaleY(.3)' }, { transform: 'scaleY(1.07)', offset: .55 }, { transform: 'scaleY(1)' }], { duration: 760, delay: i * 42, easing: 'cubic-bezier(.22,1,.36,1)', fill: 'backwards' }));
          await ctx.wait(1300);
          bars.forEach(b => { b.style.transitionDelay = ''; });
        },
        v2(v) { lit(v); roll.set(v); },
      };
    },
  };

  // 6. A Wallet-style stack. The spent card drops to the back and the next one comes forward.
  const deck = {
    id: 'deck', name: 'Wallet',
    html: '<div class="lr-dk"><div class="lr-dk-s">' + [['cc', ADA, FROM], ['cc', KAT, TO], ['cx', GRACE, 59]].map(([k, w, p]) =>
      `<div class="lr-dk-c" style="--c:${k === 'cc' ? CL : CX}"><div class="lr-dk-t"><img src="${IMG[k]}" alt=""><span>${SVC[k]}</span><small>Session</small></div><b class="lr-dk-n"><span>${p}</span>%</b><span class="lr-dk-w">${w}</span><div class="lr-dk-bar"><i></i></div></div>`).join('') + '</div></div>',
    make(st) {
      const cs = [...st.querySelectorAll('.lr-dk-c')], sm = cs.map(c => c.querySelector('small')), P = 30;
      const pose = (c, s, y = 0, rx = 0, op = 1) => { c.style.transform = `translateY(${(y - P * s).toFixed(2)}px) rotateX(${rx.toFixed(2)}deg) scale(${(1 - .06 * s).toFixed(4)})`; c.style.setProperty('--s', s.toFixed(3)); c.style.opacity = op; };
      const lv = (i, v) => { const c = cs[i], b = c.querySelector('.lr-dk-bar i'); c.querySelector('.lr-dk-n span').textContent = Math.round(v); b.style.clipPath = `inset(0 ${(100 - v).toFixed(2)}% 0 0 round 2px)`; b.style.background = tint(i === 2 ? CX : CL, v); c.querySelector('.lr-dk-n').style.color = mix(INK, RED, lowT(v)); };
      const state = (sl, a, k, s0) => { [0, 1, 2].forEach(i => { pose(cs[i], sl[i]); cs[i].style.zIndex = 10 - sl[i]; }); lv(0, a); lv(1, k); lv(2, 59); put(sm[0], s0); };
      return {
        reset: () => state([0, 1, 2], FROM, TO, 'Session'),
        final: () => state([2, 0, 1], LOW, TO, 'Resets 3h 19m'),
        v(v) { lv(0, v); },
        async hand(ctx) {
          cs.forEach((c, i) => { c.style.zIndex = 30 - i * 10; });
          const fwd = ctx.tw(1050, e => { pose(cs[1], 1 - e); pose(cs[2], 2 - e); }, E.spring);
          // The card stays opaque and leaves through the bottom of the tile, so two cards never show through each other.
          await ctx.tw(520, e => pose(cs[0], 0, 170 * e, 12 * e, 1), E.in);
          cs[0].style.zIndex = 5; put(sm[0], 'Resets 3h 19m');
          await ctx.tw(760, e => pose(cs[0], lerp(2.8, 2, e), 0, 0, clamp(e * 1.6, 0, 1)), E.out);
          await fwd;
        },
        v2(v) { lv(1, v); },
      };
    },
  };

  // 7. A needle gauge on spring physics. Lit ticks follow the needle; the needle swings up for the next account.
  const gauge = {
    id: 'gauge', name: 'Gauge',
    html() {
      let t = '';
      for (let i = 0; i <= 40; i++) {
        const v = i * 2.5, a = Math.PI * (1 - v / 100), mj = i % 10 === 0, r0 = mj ? 80 : 85, c = Math.cos(a), s = Math.sin(a);
        t += `<line data-v="${v}" class="${mj ? 'mj' : ''}${v <= LOW ? ' lw' : ''}" x1="${(100 + r0 * c).toFixed(2)}" y1="${(100 - r0 * s).toFixed(2)}" x2="${(100 + 91 * c).toFixed(2)}" y2="${(100 - 91 * s).toFixed(2)}"/>`;
      }
      const lab = [0, 25, 50, 75, 100].map(v => { const a = Math.PI * (1 - v / 100); return `<text x="${(100 + 69 * Math.cos(a)).toFixed(1)}" y="${(100 - 69 * Math.sin(a) + 3).toFixed(1)}">${v}</text>`; }).join('');
      return `<div class="lr-ga"><svg viewBox="0 0 200 108" aria-hidden="true"><g class="lr-ga-tk">${t}</g><g class="lr-ga-lb">${lab}</g>` +
        '<g class="lr-ga-nd"><path d="M18 100 100 98.4 110 99.2v1.6l-10 .8z"/></g><circle cx="100" cy="100" r="5.5" class="lr-ga-hb"/><circle cx="100" cy="100" r="2" fill="#fff"/></svg>' +
        '<div class="lr-ga-r"><b><span class="lr-r"></span>%</b><span class="lr-ga-l"><span class="lr-ga-w"></span> · Session</span></div></div>';
    },
    make(st) {
      const ticks = [...st.querySelectorAll('.lr-ga-tk line')].map(l => ({ l, v: +l.dataset.v, on: null })), nd = st.querySelector('.lr-ga-nd'), roll = Roll(st.querySelector('.lr-r'), FROM), w = st.querySelector('.lr-ga-w'), rd = st.querySelector('.lr-ga-r b');
      let n = FROM, vel = 0, T = FROM, col = '';
      const paint = () => {
        nd.setAttribute('transform', `rotate(${(clamp(n, -2, 102) * 1.8).toFixed(2)} 100 100)`);
        const c = tint(CL, n), cc = c !== col; col = c;
        ticks.forEach(k => { const on = k.v <= n + .01; if (on !== k.on || (on && cc)) { k.on = on; k.l.style.stroke = on ? c : ''; } });
      };
      const state = (v, who) => { n = T = v; vel = 0; roll.set(v, true); put(w, who); rd.style.color = ''; paint(); };
      return {
        begin(ctx) { ctx.frame(dt => { for (let i = 0; i < 2; i++) { const h = dt / 2; vel += (64 * (T - n) - 9.5 * vel) * h; n += vel * h; } paint(); }); },
        reset: () => state(FROM, ADA),
        final: () => state(TO, KAT),
        v(v) { T = v; roll.set(v); rd.style.color = mix(INK, RED, lowT(v)); },
        async hand(ctx) { await ctx.wait(80); T = TO; roll.set(TO); rd.style.color = ''; swap(ctx, w, KAT); await ctx.wait(1500); },
        v2(v) { T = v; roll.set(v); },
      };
    },
  };

  // 8. A burn-down of today. Time-lapse to the threshold, then the line carries on from the next account.
  const burn = {
    id: 'burn', name: 'Burn-down',
    html: `<div class="lr-bd"><div class="lr-bd-hd"><b class="lr-bd-n"><span class="lr-r"></span>%</b><span class="lr-bd-ck">10:41 AM</span><span class="lr-bd-w"><span class="lr-bd-who"></span> · Session</span></div>` +
      `<div class="lr-bd-ch"><svg aria-hidden="true"><defs><linearGradient id="lr-bd-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${CL}" stop-opacity=".22"/><stop offset="1" stop-color="${CL}" stop-opacity="0"/></linearGradient></defs>` +
      '<line class="lr-bd-th"/><path class="lr-bd-a"/><path class="lr-bd-a"/><path class="lr-bd-l"/><path class="lr-bd-l"/><path class="lr-bd-pj"/><line class="lr-bd-cn"/><circle class="lr-bd-dot" r="4"/></svg><span class="lr-bd-tl">Switch at 5%</span></div>' +
      '<div class="lr-bd-ax"><span>9 AM</span><span>12 PM</span><span>3 PM</span></div></div>',
    make(st) {
      const $ = s => st.querySelector(s), svg = $('svg'), ch = $('.lr-bd-ch'), roll = Roll($('.lr-r'), FROM), who = $('.lr-bd-who'), clk = $('.lr-bd-ck'), dot = $('.lr-bd-dot'), [l1, l2] = st.querySelectorAll('.lr-bd-l'), [a1, a2] = st.querySelectorAll('.lr-bd-a'), pj = $('.lr-bd-pj'), cn = $('.lr-bd-cn'), th = $('.lr-bd-th'), tl = $('.lr-bd-tl'), nb = $('.lr-bd-n');
      const H0 = 1.68, H1 = 3.05, SPAN = 6;
      let W = 1, H = 1, p1 = [], p2 = [];
      const X = h => h / SPAN * W, Y = v => 5 + (1 - v / 100) * (H - 7);
      const line = ps => ps.map((p, i) => `${i ? 'L' : 'M'}${X(p[0]).toFixed(1)} ${Y(p[1]).toFixed(1)}`).join('');
      const area = ps => (ps.length < 2 ? '' : `${line(ps)}L${X(ps[ps.length - 1][0]).toFixed(1)} ${H}L${X(ps[0][0]).toFixed(1)} ${H}Z`);
      const clock = h => { const m = Math.round(h * 60) + 540, hh = Math.floor(m / 60); return `${((hh + 11) % 12) + 1}:${String(m % 60).padStart(2, '0')} ${hh < 12 ? 'AM' : 'PM'}`; };
      const size = () => {
        W = ch.clientWidth || 236; H = ch.clientHeight || 110;
        svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
        [['x1', 0], ['x2', W], ['y1', Y(LOW)], ['y2', Y(LOW)]].forEach(([k, v]) => th.setAttribute(k, v));
        tl.style.top = `${Y(LOW) - 17}px`;
      };
      const hist = () => { const ps = []; for (let h = 0; h < H0; h += .06) ps.push([h, 100 - 24 * h / H0 + 1.4 * Math.sin(h * 7) * Math.sin(Math.PI * h / H0)]); ps.push([H0, FROM]); return ps; };
      const draw = (h, v, live) => {
        l1.setAttribute('d', line(p1)); a1.setAttribute('d', area(p1));
        l2.setAttribute('d', p2.length > 1 ? line(p2) : ''); a2.setAttribute('d', area(p2));
        dot.setAttribute('cx', X(h).toFixed(1)); dot.setAttribute('cy', Y(v).toFixed(1));
        dot.style.stroke = tint(CL, v); nb.style.color = mix(INK, RED, lowT(v));
        let d = '';
        if (live) {
          const back = p1.find(p => p[0] >= h - .3) || p1[0], s = (v - back[1]) / Math.max(.01, h - back[0]);
          if (s < -1) { const ho = Math.min(SPAN, h + v / -s), vo = v + s * (ho - h); d = `M${X(h).toFixed(1)} ${Y(v).toFixed(1)}L${X(ho).toFixed(1)} ${Y(vo).toFixed(1)}`; }
        }
        pj.setAttribute('d', d);
      };
      const state = (fin) => {
        size(); p1 = hist(); p2 = [];
        if (fin) { for (let t = 0; t <= 1.0001; t += .02) p1.push([lerp(H0, H1, t), lerp(FROM, LOW, burst(t))]); p2 = [[H1, TO], [H1 + .4, 64.2], [H1 + .8, 63.6], [H1 + 1.1, 63]]; }
        roll.set(fin ? 63 : FROM, true); put(who, fin ? KAT : ADA); put(clk, fin ? `Switched at ${clock(H1)}` : clock(H0));
        cn.setAttribute('x1', X(H1)); cn.setAttribute('x2', X(H1)); cn.setAttribute('y1', Y(LOW)); cn.setAttribute('y2', Y(TO)); cn.classList.toggle('lr-x', fin);
        snap(st, () => { pj.style.opacity = fin ? 0 : 1; });
        draw(fin ? H1 + 1.1 : H0, fin ? 63 : FROM, !fin);
      };
      return {
        reset: () => state(false), final: () => state(true),
        v(v, ctx, t) { const h = lerp(H0, H1, t); if (h - p1[p1.length - 1][0] > .012) p1.push([h, v]); draw(h, v, true); roll.set(v); clk.textContent = clock(h); },
        async hand(ctx) {
          p1.push([H1, LOW]); pj.style.opacity = 0; cn.classList.add('lr-x');
          swap(ctx, clk, `Switched at ${clock(H1)}`); swap(ctx, who, KAT); roll.set(TO);
          p2 = [[H1, TO]];
          await ctx.tw(900, e => draw(H1, lerp(LOW, TO, e), false), E.spring);
        },
        v2(v, ctx, t) { const h = H1 + t * 1.1, w = v + Math.sin(t * 19) * .45; if (h - p2[p2.length - 1][0] > .012) p2.push([h, w]); draw(h, w, false); roll.set(v); },
      };
    },
  };

  // 9. A hundred dots, one per percent. They empty in reading order and refill in a ripple from the middle.
  const dots = {
    id: 'dots', name: 'Dots',
    html: `<div class="lr-dt"><div class="lr-dt-g">${'<i></i>'.repeat(100)}</div><div class="lr-dt-tx"><b class="lr-dt-n"><span class="lr-r"></span>%</b><span class="lr-dt-s">Session left</span></div><div class="lr-dt-w"><b class="lr-dt-who lr-sp"></b><span>Claude Code</span></div></div>`,
    make(st) {
      const g = st.querySelector('.lr-dt-g'), ds = [...g.children], roll = Roll(st.querySelector('.lr-r'), FROM), who = st.querySelector('.lr-dt-who'), nb = st.querySelector('.lr-dt-n');
      const lit = v => { const n = Math.round(v); ds.forEach((d, i) => d.classList.toggle('lr-on', i >= 100 - n)); g.style.setProperty('--c', tint(CL, v)); nb.style.color = mix(INK, RED, lowT(v)); };
      const state = (v, w) => { ds.forEach(d => { d.style.transitionDelay = ''; }); lit(v); roll.set(v, true); spell(who, w); };
      return {
        reset: () => snap(st, () => state(FROM, ADA)),
        final: () => snap(st, () => state(TO, KAT)),
        v(v) { lit(v); roll.set(v); },
        async hand(ctx) {
          respell(ctx, who, KAT); roll.set(TO);
          ds.forEach((d, i) => { d.style.transitionDelay = `${Math.round(Math.hypot(i % 10 - 4.5, Math.floor(i / 10) - 4.5) * 46)}ms`; });
          lit(TO);
          await ctx.wait(1200);
          ds.forEach(d => { d.style.transitionDelay = ''; });
        },
        v2(v) { lit(v); roll.set(v); },
      };
    },
  };

  // 10. A split-flap board. Digits flip as the limit drains; the name row clatters to the next account.
  const NAME = 17;
  const pad = s => s.padEnd(NAME, ' ');
  const flap = {
    id: 'flap', name: 'Split-flap',
    html: `<div class="lr-fl"><div class="lr-fl-k">${src('cc')}<span class="lr-fl-s">Session left</span></div><div class="lr-fl-top"><span class="lr-fl-big"><i></i><i></i></span><span class="lr-fl-pc">%</span></div><div class="lr-fl-nm">${'<i></i>'.repeat(NAME)}</div></div>`,
    drain: 7200,
    make(st) {
      const big = [...st.querySelectorAll('.lr-fl-big i')].map(e => Flap(e, ' ')), nm = [...st.querySelectorAll('.lr-fl-nm i')].map(e => Flap(e, ' ')), sub = st.querySelector('.lr-fl-s'), pc = st.querySelector('.lr-fl-pc');
      const digits = v => { const r = Math.round(v); return [r >= 10 ? String(Math.floor(r / 10)) : ' ', String(r % 10)]; };
      const setNum = v => { const d = digits(v); big.forEach((f, i) => f.set(d[i], 80)); pc.style.color = mix('#6E6E73', RED, lowT(v)); };
      const state = (v, w) => { const d = digits(v); big.forEach((f, i) => f.now(d[i])); [...pad(w)].forEach((c, i) => nm[i].now(c)); put(sub, 'Session left'); sub.classList.remove('lr-lo'); pc.style.color = ''; };
      return {
        reset: () => state(FROM, ADA),
        final: () => state(TO, KAT),
        v(v, ctx) { setNum(v); if (v <= 10 && !sub.classList.contains('lr-lo')) { sub.classList.add('lr-lo'); swap(ctx, sub, 'Almost out'); } },
        async hand(ctx) {
          sub.classList.remove('lr-lo'); swap(ctx, sub, 'Session left');
          [...pad(KAT)].forEach((c, i) => setTimeout(() => ctx.alive() && nm[i].spin(c, 2 + (i % 3)), i * 34));
          await ctx.wait(260);
          setNum(TO);
          await ctx.wait(1500);
        },
        v2(v) { setNum(v); },
      };
    },
  };

  // 11. A Smart Stack widget that scrolls to the next account's widget.
  const wdg = (k, w, p) => `<div class="lr-wg-p"><div class="lr-wg-t"><img src="${IMG[k]}" alt=""><span>${SVC[k]}</span><svg class="lr-wg-rg" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" style="stroke:${k === 'cc' ? CL : CX}"/><circle cx="12" cy="12" r="9" pathLength="100" transform="rotate(-90 12 12)"/></svg></div><b class="lr-wg-n"><span>${p}</span>%</b><span class="lr-wg-s">Session left</span><span class="lr-wg-w">${w}</span><div class="lr-wg-bar"><i></i></div></div>`;
  const stack = {
    id: 'stack', name: 'Smart Stack',
    html: `<div class="lr-wg"><div class="lr-wg-x"><div class="lr-wg-f"><div class="lr-wg-sc">${wdg('cc', ADA, FROM)}${wdg('cc', KAT, TO)}</div></div><span class="lr-wg-dots"><i></i><i></i></span></div><div class="lr-wg-x lr-wg-2"><div class="lr-wg-f">${wdg('cx', GRACE, 59)}</div></div></div>`,
    make(st) {
      const f = st.querySelector('.lr-wg-f'), sc = st.querySelector('.lr-wg-sc'), ps = [...st.querySelectorAll('.lr-wg-p')], dts = [...st.querySelectorAll('.lr-wg-dots i')], dw = st.querySelector('.lr-wg-dots');
      const lv = (i, v) => { const p = ps[i], b = p.querySelector('.lr-wg-bar i'), a = p.querySelector('.lr-wg-rg circle:last-child'), c = tint(i === 2 ? CX : CL, v); p.querySelector('.lr-wg-n span').textContent = Math.round(v); b.style.clipPath = `inset(0 ${(100 - v).toFixed(2)}% 0 0 round 2px)`; b.style.background = c; a.style.stroke = c; a.style.strokeDasharray = `${v.toFixed(2)} 200`; p.querySelector('.lr-wg-n').style.color = mix(INK, RED, lowT(v)); };
      const at = p => { sc.style.transform = `translateY(${(-p * 50).toFixed(3)}%)`; ps.slice(0, 2).forEach((x, i) => { const d = Math.min(1, Math.abs(i - p)); x.style.transform = `scale(${(1 - .08 * d).toFixed(4)})`; x.style.opacity = (1 - .6 * d).toFixed(3); }); dts.forEach((d, i) => d.classList.toggle('lr-on', Math.round(p) === i)); };
      const cx = v => 59 - (FROM - v) / (FROM - LOW) * 4;
      const state = (p, a, c) => { at(p); lv(0, a); lv(1, TO); lv(2, c); dw.classList.remove('lr-on'); f.style.transform = ''; };
      return {
        reset: () => snap(st, () => state(0, FROM, 59)),
        final: () => snap(st, () => state(1, LOW, 55)),
        v(v) { lv(0, v); lv(2, cx(v)); },
        async hand(ctx) {
          dw.classList.add('lr-on');
          await ctx.tw(1100, e => { at(e); f.style.transform = `scale(${(1 - .035 * Math.sin(Math.PI * clamp(e, 0, 1))).toFixed(4)})`; }, E.spring);
          await ctx.wait(700); dw.classList.remove('lr-on');
        },
        v2(v) { lv(1, v); },
      };
    },
  };

  // 12. Bubbles sized by what is left. The solid color flows from the spent account into the next one.
  const R = p => 56 * Math.sqrt(Math.max(0, p) / 100);
  const goo = {
    id: 'goo', name: 'Bubbles',
    html: `<div class="lr-gb"><svg viewBox="0 0 240 150" aria-hidden="true"><defs><filter id="lr-goo" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur in="SourceGraphic" stdDeviation="4.5" result="b"/><feColorMatrix in="b" values="1 0 0 0 0 0 1 0 0 0 0 0 1 0 0 0 0 0 22 -9" result="g"/><feComposite in="SourceGraphic" in2="g" operator="atop"/></filter></defs>` +
      `<circle class="lr-gb-t" cx="66" cy="64"/><circle class="lr-gb-t" cx="174" cy="64"/><g filter="url(#lr-goo)"><circle class="lr-gb-s" cx="66" cy="64"/><circle class="lr-gb-s"/><circle class="lr-gb-s" cx="174" cy="64"/></g>` +
      `<text class="lr-gb-n" x="66" y="64"></text><text class="lr-gb-n" x="174" y="64"></text><text class="lr-gb-l" x="66" y="138">${ADA}</text><text class="lr-gb-l" x="174" y="138">${KAT}</text></svg></div>`,
    make(st) {
      const [ta, tk] = st.querySelectorAll('.lr-gb-t'), [sa, sm, sk] = st.querySelectorAll('.lr-gb-s'), [na, nk] = st.querySelectorAll('.lr-gb-n');
      const label = (t, cx, p, solid) => { const r = R(p), fs = clamp(r * .38, 9, 18); t.textContent = `${Math.round(p)}%`; t.setAttribute('font-size', fs.toFixed(2)); t.setAttribute('y', (64 + fs * .36).toFixed(2)); t.style.fill = solid ? '#fff' : CL; };
      const paint = (a, k, sA, sK, m) => {
        ta.setAttribute('r', R(a).toFixed(2)); tk.setAttribute('r', R(k).toFixed(2));
        sa.setAttribute('r', (R(a) * sA).toFixed(2)); sk.setAttribute('r', (R(k) * sK).toFixed(2));
        sa.style.fill = tint(CL, a);
        if (m) { sm.setAttribute('cx', m[0].toFixed(2)); sm.setAttribute('cy', m[1].toFixed(2)); sm.setAttribute('r', m[2].toFixed(2)); } else sm.setAttribute('r', 0);
        label(na, 66, a, sA > .55); label(nk, 174, k, sK > .55);
      };
      return {
        reset: () => paint(FROM, TO, 1, 0),
        final: () => paint(LOW, TO, 0, 1),
        v(v) { paint(v, TO, 1, 0); },
        async hand(ctx) {
          const r0 = R(LOW);
          const go = ctx.tw(980, e => { const x = lerp(66, 174, e), y = 64 - Math.sin(Math.PI * e) * 10; paint(LOW, TO, clamp(1 - e * 3, 0, 1), 0, [x, y, lerp(r0, 9, Math.sin(Math.PI * e * .5))]); }, E.io);
          await ctx.wait(560);
          await ctx.tw(1100, e => { const u = clamp(e * 1.6, 0, 1); sk.setAttribute('r', (R(TO) * clamp(E.spring(u), 0, 1.2)).toFixed(2)); label(nk, 174, TO, u > .35); }, E.lin);
          await go; sm.setAttribute('r', 0);
        },
        v2(v) { paint(LOW, v, 0, 1); },
      };
    },
  };

  // 13. A macOS grouped list. The check mark travels to the next account.
  const row = (w, p, on) => `<div class="lr-ls-r${on ? ' lr-on' : ''}"><span class="lr-ls-n">${w}</span><span class="lr-ls-bar"><i></i></span><b class="lr-ls-p"><span class="lr-r"></span>%</b></div>`;
  const list = {
    id: 'list', name: 'List',
    html: `<div class="lr-ls"><div class="lr-ls-g"><div class="lr-ls-h">${src('cc')}</div><div class="lr-ls-box"><i class="lr-ls-hl"></i><span class="lr-ls-ck">${ck}</span>${row(ADA, FROM, 1)}${row(KAT, TO)}</div></div>` +
      `<div class="lr-ls-g"><div class="lr-ls-h">${src('cx')}</div><div class="lr-ls-box"><span class="lr-ls-ck">${ck}</span>${row(GRACE, 59, 1)}${row(LINUS, 33)}</div></div></div>`,
    make(st) {
      const rs = [...st.querySelectorAll('.lr-ls-r')], rolls = rs.map((r, i) => Roll(r.querySelector('.lr-r'), [FROM, TO, 59, 33][i])), bars = rs.map(r => r.querySelector('.lr-ls-bar i')), [c0] = st.querySelectorAll('.lr-ls-ck'), hl = st.querySelector('.lr-ls-hl');
      const lv = (i, v) => { rolls[i].set(v); bars[i].style.clipPath = `inset(0 ${(100 - v).toFixed(2)}% 0 0 round 2px)`; bars[i].style.background = tint(i < 2 ? CL : CX, v); rs[i].querySelector('.lr-ls-p').style.color = mix(INK, RED, lowT(v)); };
      const cx = v => 59 - (FROM - v) / (FROM - LOW) * 4;
      const ckAt = (y, s, d) => { c0.style.transform = `translateY(${y.toFixed(2)}px) scale(${s.toFixed(3)})`; c0.querySelector('path').style.strokeDashoffset = d.toFixed(3); };
      const rowH = () => rs[1].offsetTop - rs[0].offsetTop;
      const state = (a, k, c, idx) => {
        snap(st, () => { [a, k, c, 33].forEach((v, i) => { lv(i, v); rolls[i].set(v, true); }); ckAt(idx * rowH(), 1, 0); hl.style.opacity = 0; hl.style.transform = `translateY(${idx * rowH()}px)`; rs[0].classList.toggle('lr-on', !idx); rs[1].classList.toggle('lr-on', !!idx); });
      };
      return {
        reset: () => state(FROM, TO, 59, 0),
        final: () => state(LOW, TO, 55, 1),
        v(v) { lv(0, v); lv(2, cx(v)); },
        async hand(ctx) {
          const h = rowH();
          hl.style.opacity = 1;
          await ctx.tw(220, e => ckAt(0, 1 - .25 * e, e * .85), E.in);
          rs[0].classList.remove('lr-on'); rs[1].classList.add('lr-on');
          hl.style.transform = `translateY(${h}px)`;
          await ctx.tw(620, e => ckAt(h * e, .75 + .25 * clamp(e, 0, 1), .85 * (1 - clamp(e, 0, 1))), E.spring);
          await ctx.wait(500); hl.style.opacity = 0;
        },
        v2(v) { lv(1, v); },
      };
    },
  };

  // 14. Type only. The numeral thins as the limit drains; the name re-spells letter by letter.
  const kin = {
    id: 'kin', name: 'Kinetic type',
    html: `<div class="lr-kn"><div class="lr-kn-k">${src('cc')}<span class="lr-kn-s">Session left</span></div><div class="lr-kn-n"><span class="lr-kn-d lr-sp"></span><span class="lr-kn-pc">%</span></div><div class="lr-kn-w lr-sp"></div></div>`,
    make(st) {
      const d = st.querySelector('.lr-kn-d'), w = st.querySelector('.lr-kn-w'), nn = st.querySelector('.lr-kn-n'), sub = st.querySelector('.lr-kn-s');
      let shown = '';
      const wt = v => lerp(220, 680, clamp((v - LOW) / (FROM - LOW), 0, 1));
      const paint = (v, weight = wt(v)) => { const s = String(Math.round(v)); if (s !== shown) { shown = s; spell(d, s); } nn.style.fontWeight = weight.toFixed(1); nn.style.color = mix(INK, RED, lowT(v)); };
      const state = (v, who) => { shown = ''; paint(v); spell(w, who); put(sub, 'Session left'); sub.classList.remove('lr-lo'); };
      return {
        reset: () => state(FROM, ADA),
        final: () => state(TO, KAT),
        v(v, ctx) { paint(v); if (v <= 10 && !sub.classList.contains('lr-lo')) { sub.classList.add('lr-lo'); swap(ctx, sub, 'Almost out'); } },
        async hand(ctx) {
          sub.classList.remove('lr-lo'); swap(ctx, sub, 'Session left');
          const wd = respell(ctx, w, KAT, 18);
          await respell(ctx, d, String(TO), 70); shown = String(TO);
          await ctx.tw(1100, e => { nn.style.fontWeight = lerp(wt(LOW), 680, e).toFixed(1); nn.style.color = mix(INK, RED, lowT(LOW) * (1 - clamp(e * 2, 0, 1))); }, E.spring);
          await wd;
        },
        v2(v) { paint(v, 680); },
      };
    },
  };

  // 15. An iOS picker wheel of accounts. It turns one notch to the next account.
  const WH = [['cx', GRACE, 59], ['cx', LINUS, 33], ['cc', ADA, FROM], ['cc', KAT, TO], ['cx', GRACE, 59]];
  const wheel = {
    id: 'wheel', name: 'Picker wheel',
    html: `<div class="lr-wh"><i class="lr-wh-band"></i><div class="lr-wh-cy">${WH.map(([k, w, p]) => `<div class="lr-wh-r"><i class="lr-gl" style="--g:${GL[k]};color:${k === 'cc' ? CL : CX}"></i><span class="lr-wh-n">${w}</span><b class="lr-wh-p"><span>${p}</span>%</b></div>`).join('')}</div></div>`,
    make(st) {
      const rs = [...st.querySelectorAll('.lr-wh-r')], ps = rs.map(r => r.querySelector('.lr-wh-p'));
      const STEP = 23 * Math.PI / 180;
      const at = pos => {
        const rh = rs[0].offsetHeight || 32, Rr = rh / Math.sin(STEP);
        rs.forEach((r, i) => {
          const a = (i - pos) * STEP, c = Math.cos(a), vis = Math.abs(a) < 1.2;
          r.style.transform = `translateY(-50%) translateY(${(Rr * Math.sin(a)).toFixed(2)}px) scaleY(${Math.max(0, c).toFixed(4)}) scaleX(${(1 - (1 - c) * .12).toFixed(4)})`;
          r.style.opacity = vis ? (c * c * c * lerp(1, .55, Math.min(1, Math.abs(i - pos) * 2))).toFixed(3) : 0;
        });
      };
      const lv = (i, v) => { ps[i].firstChild.textContent = Math.round(v); ps[i].style.color = mix(INK, RED, lowT(v)); };
      return {
        reset: () => { lv(2, FROM); lv(3, TO); at(2); },
        final: () => { lv(2, LOW); lv(3, TO); at(3); },
        v(v) { lv(2, v); },
        async hand(ctx) { await ctx.tw(1050, e => at(2 + e), E.spring); },
        v2(v) { lv(3, v); },
      };
    },
  };

  const DEFS = [num, rings, bat, liq, seg, deck, gauge, burn, dots, flap, stack, goo, list, kin, wheel];

  host.classList.add('lr');
  host.dataset.vary = 'limring';
  host.dataset.label = 'Limits, live';
  host.setAttribute('role', 'img');
  host.setAttribute('aria-label', 'Remaining limits update live. When ada.lovelace runs low, Switch moves Claude Code to katherine.johnson before the limit.');
  const saved = (+(localStorage.getItem('vary:limring') || 0) % DEFS.length + DEFS.length) % DEFS.length;
  const opts = DEFS.map((d, i) => {
    const el = document.createElement('div');
    el.className = `opt lr-o lr-${d.id}`;
    el.dataset.name = d.name;
    el.hidden = i !== saved;
    el.innerHTML = `<div class="lr-st">${typeof d.html === 'function' ? d.html() : d.html}</div>`;
    host.append(el);
    const o = d.make(el.firstElementChild);
    return Object.assign(o, { el, st: el.firstElementChild, drain: d.drain });
  });

  async function story(ctx, o) {
    o.st.getAnimations({ subtree: true }).forEach(a => a.cancel());
    o.reset();
    await fade(ctx, o.st, false);
    await ctx.wait(450);
    await ctx.tw(o.drain || 6400, (e, t) => o.v(lerp(FROM, LOW, e), ctx, t), burst);
    await ctx.wait(480);
    await o.hand(ctx);
    await ctx.tw(3600, (e, t) => o.v2(lerp(TO, TO - 2, e), ctx, t), E.lin);
    await fade(ctx, o.st, true);
  }

  let seen = false;
  function start() {
    const g = ++run, o = opts.find(x => !x.el.hidden) || opts[0];
    o.st.getAnimations({ subtree: true }).forEach(a => a.cancel());
    if (calm) { o.reset(); o.final(); return; }
    if (!seen) { o.reset(); return; }
    const ctx = ctxFor(g);
    o.begin?.(ctx);
    (async () => { for (;;) await story(ctx, o); })().catch(e => { if (e !== STOP && ctx.alive()) console.error(e); });
  }
  host.addEventListener('vary', start);
  new IntersectionObserver(es => { const s = es[es.length - 1].isIntersecting; if (s !== seen) { seen = s; if (s) start(); else run++; } }, { threshold: .2 }).observe(host);
  let size = '';
  new ResizeObserver(() => { const s = `${host.clientWidth}x${host.clientHeight}`; if (size && s !== size && seen) start(); size = s; }).observe(host);
  start();
})();
