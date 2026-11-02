(() => {
  const GH = 'https://github.com/surajmandalcell/switch';
  // Pinned to the current release until the release assets get a stable name for releases/latest/download.
  const DL = GH + '/releases/download/v3.8.2/Switch-v3.8.2-mac-arm64.zip';
  const base = document.body.dataset.base || '';
  const COLS = [
    ['Product', [['Download', DL], ['Release notes', GH + '/blob/master/docs/release-notes.md'], ['All releases', GH + '/releases']]],
    ['Project', [['GitHub', GH], ['Report an issue', GH + '/issues'], ['npm package', 'https://www.npmjs.com/package/@smdl/switch']]],
    ['Legal', [['Privacy', base + 'privacy/'], ['Terms', base + 'terms/'], ['Security', base + 'security/'], ['MIT License', GH + '/blob/master/LICENSE']]],
  ];
  const ext = u => u.startsWith('http') ? ' target="_blank" rel="noopener"' : '';
  document.querySelectorAll('[data-links]').forEach(el => { el.innerHTML = COLS.map(([h, ls]) => `<div><h4>${h}</h4>${ls.map(([t, u]) => `<a href="${u}"${ext(u)}>${t}</a>`).join('')}</div>`).join(''); });
  document.querySelectorAll('[data-gh]').forEach(a => { a.href = GH; });
  document.querySelectorAll('[data-notes]').forEach(a => { a.href = GH + '/releases/tag/v3.8.2'; });
  document.querySelectorAll('[data-gh-report]').forEach(a => { a.href = GH + '/security/advisories/new'; });

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
