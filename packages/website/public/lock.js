// Shows the chosen design in each region that offers several.
(() => {
  const PICK = { mzoom: 1, limring: 0, meters: 4 };
  document.querySelectorAll('[data-vary]').forEach(r => {
    const i = PICK[r.dataset.vary] ?? 0;
    if (r.dataset.modes) r.dispatchEvent(new CustomEvent('vary-before', { detail: i }));
    else [...r.children].filter(c => c.classList.contains('opt')).forEach((o, j) => { o.hidden = j !== i; });
    r.dataset.cur = i;
    r.dispatchEvent(new CustomEvent('vary', { detail: i }));
  });
  dispatchEvent(new Event('resize'));
})();
