const scriptUrl = document.currentScript?.src;
if (scriptUrl) {
  const polishHref = new URL('polish.css', scriptUrl).href;
  if (!document.querySelector('link[href$="polish.css"]')) {
    const polish = document.createElement('link');
    polish.rel = 'stylesheet';
    polish.href = polishHref;
    document.head.append(polish);
  }

  const iconHref = new URL('icon.svg', scriptUrl).href;
  for (const mark of document.querySelectorAll('.site-mark')) {
    if (mark.querySelector('img')) continue;
    const image = document.createElement('img');
    image.src = iconHref;
    image.width = 32;
    image.height = 32;
    image.alt = '';
    image.className = 'site-logo';
    mark.replaceChildren(image);
  }
}

const menuButton = document.querySelector('[data-menu-toggle]');
const menu = document.querySelector('[data-menu]');
const header = document.querySelector('[data-site-header]');

function closeMenu({ restoreFocus = false } = {}) {
  if (!menuButton || !menu) return;
  menuButton.setAttribute('aria-expanded', 'false');
  menuButton.setAttribute('aria-label', 'Open navigation');
  menu.classList.remove('open');
  if (restoreFocus) menuButton.focus();
}

if (menuButton && menu) {
  menuButton.addEventListener('click', () => {
    const open = menuButton.getAttribute('aria-expanded') === 'true';
    if (open) {
      closeMenu();
      return;
    }

    menuButton.setAttribute('aria-expanded', 'true');
    menuButton.setAttribute('aria-label', 'Close navigation');
    menu.classList.add('open');
    const firstLink = menu.querySelector('a');
    firstLink?.focus();
  });

  menu.addEventListener('click', (event) => {
    if (event.target.closest('a')) closeMenu();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && menu.classList.contains('open')) {
      closeMenu({ restoreFocus: true });
    }
  });

  const wideLayout = window.matchMedia('(min-width: 841px)');
  wideLayout.addEventListener('change', (event) => {
    if (event.matches) closeMenu();
  });
}

if (header) {
  const updateHeader = () => header.classList.toggle('scrolled', window.scrollY > 16);
  updateHeader();
  window.addEventListener('scroll', updateHeader, { passive: true });
}

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const revealNodes = [...document.querySelectorAll('[data-reveal]')];
for (const [index, node] of revealNodes.entries()) {
  node.classList.add('reveal');
  node.style.transitionDelay = `${Math.min(index * 40, 200)}ms`;
}

if (reducedMotion || !('IntersectionObserver' in window)) {
  for (const node of revealNodes) node.classList.add('is-visible');
} else {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });

  requestAnimationFrame(() => {
    for (const node of revealNodes) observer.observe(node);
  });
}

for (const button of document.querySelectorAll('[data-copy-target]')) {
  const originalLabel = button.textContent;
  let resetTimer = null;
  button.setAttribute('aria-live', 'polite');

  button.addEventListener('click', async () => {
    const target = document.getElementById(button.dataset.copyTarget);
    if (!target) return;
    const text = target.textContent.trim();

    if (resetTimer) window.clearTimeout(resetTimer);
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
    } catch {
      button.textContent = 'Copy failed';
    }

    resetTimer = window.setTimeout(() => {
      button.textContent = originalLabel;
      resetTimer = null;
    }, 1400);
  });
}

for (const node of document.querySelectorAll('[data-current-year]')) {
  node.textContent = String(new Date().getFullYear());
}
