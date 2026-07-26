(() => {
  const root = document.documentElement;
  const themeButton = document.querySelector('[data-theme-toggle]');
  const menuButton = document.querySelector('[data-menu-toggle]');
  const menu = document.querySelector('[data-menu]');
  const header = document.querySelector('[data-site-header]');
  const storageKey = 'spi-theme';

  const preferredTheme = () => {
    const stored = localStorage.getItem(storageKey);
    if (stored === 'dark' || stored === 'light') return stored;
    return matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
  };

  const setTheme = (theme, persist = false) => {
    root.dataset.theme = theme;
    if (persist) localStorage.setItem(storageKey, theme);
    if (themeButton) {
      const next = theme === 'dark' ? 'light' : 'dark';
      themeButton.setAttribute('aria-label', `Use ${next} theme`);
      themeButton.title = `Use ${next} theme`;
    }
  };

  setTheme(preferredTheme());
  themeButton?.addEventListener('click', () => {
    setTheme(root.dataset.theme === 'dark' ? 'light' : 'dark', true);
  });

  const closeMenu = () => {
    menu?.classList.remove('open');
    menuButton?.setAttribute('aria-expanded', 'false');
    menuButton?.setAttribute('aria-label', 'Open navigation');
  };

  menuButton?.addEventListener('click', () => {
    const open = !menu?.classList.contains('open');
    menu?.classList.toggle('open', open);
    menuButton.setAttribute('aria-expanded', String(open));
    menuButton.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
  });
  menu?.querySelectorAll('a').forEach((link) => link.addEventListener('click', closeMenu));
  addEventListener('resize', () => { if (innerWidth > 820) closeMenu(); }, { passive: true });

  const setHeaderState = () => header?.classList.toggle('scrolled', scrollY > 16);
  setHeaderState();
  addEventListener('scroll', setHeaderState, { passive: true });

  document.querySelectorAll('[data-current-year]').forEach((node) => {
    node.textContent = String(new Date().getFullYear());
  });

  document.querySelectorAll('[data-copy-target]').forEach((button) => {
    button.addEventListener('click', async () => {
      const target = document.getElementById(button.dataset.copyTarget);
      if (!target) return;
      const original = button.textContent;
      try {
        await navigator.clipboard.writeText(target.innerText);
        button.textContent = 'Copied';
      } catch {
        button.textContent = 'Select text';
      }
      setTimeout(() => { button.textContent = original; }, 1600);
    });
  });

  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const revealNodes = document.querySelectorAll('.reveal');
  if (reducedMotion || !('IntersectionObserver' in window)) {
    revealNodes.forEach((node) => node.classList.add('visible'));
  } else {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('visible');
        observer.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
    revealNodes.forEach((node) => observer.observe(node));
  }
})();
