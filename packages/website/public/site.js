(() => {
  const GH = 'https://github.com/samhqapp/switch';
  // The typed version is the fallback; the fetch at the end swaps in the live one from api.samhq.app.
  const zip = v => GH + `/releases/download/v${v}/Switch-v${v}-mac-arm64.zip`;
  const DL = zip('3.10.0');
  const base = document.body.dataset.base || '';
  const COLS = [
    ['Downloads', [['Download', DL], ['Homebrew', 'https://github.com/samhqapp/homebrew-tap/blob/main/Casks/switch.rb'], ['Release notes', GH + '/blob/master/docs/release-notes.md'], ['All releases', GH + '/releases']]],
    ['Project', [['About', base + 'about/'], ['GitHub', GH], ['Report an issue', GH + '/issues'], ['npm package', 'https://www.npmjs.com/package/@smdl/switch']]],
    ['Legal', [['Privacy', base + 'privacy/'], ['Terms', base + 'terms/'], ['Security', base + 'security/'], ['MIT License', GH + '/blob/master/LICENSE']]],
  ];
  const ext = u => u.startsWith('http') ? ' target="_blank" rel="noopener"' : '';
  document.querySelectorAll('[data-links]').forEach(el => { el.innerHTML = COLS.map(([h, ls]) => `<div><h4>${h}</h4>${ls.map(([t, u]) => `<a href="${u}"${ext(u)}>${t}</a>`).join('')}</div>`).join(''); });
  document.querySelectorAll('[data-gh]').forEach(a => { a.href = GH; });
  document.querySelectorAll('[data-notes]').forEach(a => { a.href = GH + '/releases/tag/v3.10.0'; });
  document.querySelectorAll('[data-gh-report]').forEach(a => { a.href = GH + '/security/advisories/new'; });

  // Release scripts write samhq_backend/releases.json; this reads it, so a release needs no site edit.
  fetch('https://api.samhq.app/v1/releases').then(r => r.json()).then(j => {
    const v = j.switch.macos.version;
    if (!/^\d+\.\d+\.\d+$/.test(v)) return;
    document.querySelectorAll(`a[href="${DL}"]`).forEach(a => { a.href = zip(v); });
    document.querySelectorAll('[data-version]').forEach(el => { el.textContent = v; });
    document.querySelectorAll('[data-notes]').forEach(a => { a.href = GH + '/releases/tag/v' + v; });
    document.querySelectorAll('.dtoast b').forEach(b => { b.textContent = 'Downloading Switch ' + v; });
  }).catch(() => {});

  const dtoast = document.querySelector('.dtoast');
  let timer = 0;
  document.querySelectorAll('[data-dl]').forEach(a => {
    a.href = DL;
    a.addEventListener('click', () => {
      if (a.closest('[data-grab]')) return;
      a.classList.remove('going'); void a.offsetWidth; a.classList.add('going');
      setTimeout(() => a.classList.remove('going'), 1200);
      say('Downloading Switch ' + (document.querySelector('[data-version]')?.textContent || ''), 'Open it from Downloads, then move it to Applications.');
    });
  });

  // The split download button follows the visitor's OS; ?os=mac|linux|windows forces one for testing.
  const CURL = 'curl -fsSL https://raw.githubusercontent.com/samhqapp/switch/master/install.sh | sh';
  const plat = (navigator.userAgentData?.platform || navigator.platform || '') + ' ' + navigator.userAgent;
  const os = new URLSearchParams(location.search).get('os')
    || (/Android/i.test(plat) ? 'mac' : /Win/i.test(plat) ? 'windows' : /Linux|X11|CrOS/i.test(plat) && !/Mac/i.test(plat) ? 'linux' : 'mac');
  function say(t, s) {
    if (!dtoast) return;
    dtoast.querySelector('b').textContent = t; dtoast.querySelector('div span').textContent = s;
    dtoast.classList.add('show'); clearTimeout(timer); timer = setTimeout(() => dtoast.classList.remove('show'), 4800);
  }
  const mains = [...document.querySelectorAll('.dd > .bk1')];
  if (os !== 'mac') {
    const L = os === 'linux'
      ? ['<i class="ap os tux" aria-hidden="true"></i>', 'Install on Linux', 'Copies the install command']
      : ['<svg class="ap os" aria-hidden="true"><use href="#i-win"/></svg>', 'Windows: coming soon', 'Arrives with Switch 3.10'];
    mains.forEach(a => {
      a.innerHTML = `${L[0]}<span class="tx">${L[1]}<small>${L[2]}</small></span>`;
      a.parentElement.setAttribute('data-grab', ''); // the Mac download toast skips this button
      a.removeAttribute('href');
      if (os === 'windows') a.setAttribute('aria-disabled', 'true'); else { a.setAttribute('role', 'button'); a.tabIndex = 0; }
      a.addEventListener('click', () => { if (os === 'linux') { navigator.clipboard?.writeText(CURL).catch(() => {}); say('Install command copied', 'Paste it in a terminal. Needs glibc 2.38 or newer.'); } });
      a.addEventListener('keydown', e => { if (os === 'linux' && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); a.click(); } });
    });
    document.querySelectorAll('.brew').forEach(b => {
      if (os === 'windows') { b.hidden = true; return; }
      b.dataset.copy = CURL; b.setAttribute('aria-label', 'Copy the Linux install command');
      b.firstElementChild.textContent = 'Or in a terminal:'; b.querySelector('code').textContent = CURL;
    });
  }

  const menu = document.querySelector('.dmenu');
  if (menu) {
    document.body.appendChild(menu);
    menu.querySelectorAll(`[data-os="${os}"] b`).forEach((b, i) => { if (!i) b.closest('.dm-i').classList.add('you'); });
    const items = [...menu.querySelectorAll('.dm-i:not([aria-disabled])')];
    let owner = null, scrollAt = 0;
    const close = refocus => {
      if (!owner) return;
      menu.hidden = true; owner.setAttribute('aria-expanded', 'false');
      if (refocus) owner.focus();
      owner = null;
    };
    const open = (btn, first) => {
      if (owner === btn) return close();
      close(); owner = btn; btn.setAttribute('aria-expanded', 'true'); menu.hidden = false;
      const r = btn.closest('.dd').getBoundingClientRect(), w = menu.offsetWidth, W = document.documentElement.clientWidth;
      const left = Math.max(16, Math.min(r.left + r.width / 2 - w / 2, W - 16 - w));
      menu.style.left = left + scrollX + 'px'; menu.style.top = r.bottom + 8 + scrollY + 'px';
      menu.style.transformOrigin = `${r.right - 21 - left}px 0`;
      scrollAt = scrollY;
      if (first) items[0].focus();
    };
    document.querySelectorAll('.dd-c').forEach(b => {
      b.addEventListener('click', e => open(b, e.detail === 0));
      b.addEventListener('keydown', e => { if (e.key === 'ArrowDown') { e.preventDefault(); open(b, true); } });
    });
    menu.addEventListener('click', e => {
      const it = e.target.closest('.dm-i');
      if (!it || it.getAttribute('aria-disabled')) return;
      if (it.dataset.copy) say('Command copied', 'Paste it in a terminal.');
      close(true);
    });
    menu.addEventListener('keydown', e => {
      const i = items.indexOf(document.activeElement), n = items.length;
      if (e.key === 'ArrowDown') items[(i + 1) % n].focus();
      else if (e.key === 'ArrowUp') items[(i - 1 + n) % n].focus();
      else if (e.key === 'Home') items[0].focus();
      else if (e.key === 'End') items[n - 1].focus();
      else if (e.key === 'Escape') close(true);
      else if (e.key === 'Tab') return close();
      else if ((e.key === 'Enter' || e.key === ' ') && i >= 0) items[i].click();
      else return;
      e.preventDefault();
    });
    document.addEventListener('pointerdown', e => { if (owner && !menu.contains(e.target) && !owner.contains(e.target)) close(); });
    addEventListener('scroll', () => { if (owner && Math.abs(scrollY - scrollAt) > 40) close(); }, { passive: true });
    addEventListener('resize', () => close());
  }

  const nav = document.querySelector('.nav');
  const tick = () => nav && nav.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', tick, { passive: true });
  tick();
})();
