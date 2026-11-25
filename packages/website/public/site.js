(() => {
  const GH = 'https://github.com/samhqapp/switch';
  // The typed version is the fallback; the fetch at the end swaps in the live one from api.samhq.app.
  const zip = v => GH + `/releases/download/v${v}/Switch-v${v}-mac-arm64.zip`;
  const DL = zip('3.8.2');
  const base = document.body.dataset.base || '';
  const COLS = [
    ['Downloads', [['Download', DL], ['Homebrew', 'https://github.com/samhqapp/homebrew-tap/blob/main/Casks/switch.rb'], ['Release notes', GH + '/blob/master/docs/release-notes.md'], ['All releases', GH + '/releases']]],
    ['Project', [['About', base + 'about/'], ['GitHub', GH], ['Report an issue', GH + '/issues'], ['npm package', 'https://www.npmjs.com/package/@smdl/switch']]],
    ['Legal', [['Privacy', base + 'privacy/'], ['Terms', base + 'terms/'], ['Security', base + 'security/'], ['MIT License', GH + '/blob/master/LICENSE']]],
  ];
  const ext = u => u.startsWith('http') ? ' target="_blank" rel="noopener"' : '';
  document.querySelectorAll('[data-links]').forEach(el => { el.innerHTML = COLS.map(([h, ls]) => `<div><h4>${h}</h4>${ls.map(([t, u]) => `<a href="${u}"${ext(u)}>${t}</a>`).join('')}</div>`).join(''); });
  document.querySelectorAll('[data-gh]').forEach(a => { a.href = GH; });
  document.querySelectorAll('[data-notes]').forEach(a => { a.href = GH + '/releases/tag/v3.8.2'; });
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
      if (!dtoast) return;
      dtoast.classList.add('show'); clearTimeout(timer); timer = setTimeout(() => dtoast.classList.remove('show'), 4800);
    });
  });

  const nav = document.querySelector('.nav');
  const tick = () => nav && nav.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', tick, { passive: true });
  tick();
})();
