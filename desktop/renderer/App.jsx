import React, { useCallback, useEffect, useState } from 'react';
import { Shell } from './components/Shell.jsx';
import { Busy } from './components/Common.jsx';
import { ProductIcon } from './components/ProductIcon.jsx';
import { Dashboard } from './pages/Dashboard.jsx';
import { Providers } from './pages/Providers.jsx';
import { Routing } from './pages/Routing.jsx';
import { Usage } from './pages/Usage.jsx';
import { Catalog } from './pages/Catalog.jsx';
import { Logs } from './pages/Logs.jsx';
import { Settings } from './pages/Settings.jsx';

export default function App() {
  const [active, setActive] = useState('dashboard');
  const [snapshot, setSnapshot] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const refresh = useCallback(async () => {
    try { setSnapshot(await window.spi.snapshot()); setError(null); }
    catch (cause) { setError(cause.message); }
  }, []);
  useEffect(() => { refresh(); const timer = setInterval(refresh, 5000); return () => clearInterval(timer); }, [refresh]);
  useEffect(() => {
    const theme = snapshot?.config?.appearance?.theme ?? 'system';
    const resolved = theme === 'system' ? snapshot?.theme ?? 'dark' : theme;
    document.documentElement.dataset.theme = resolved;
    document.documentElement.classList.toggle('dark', resolved === 'dark');
    document.body.classList.toggle('compact', snapshot?.config?.appearance?.compact !== false);
    document.body.classList.toggle('reduce-motion', Boolean(snapshot?.config?.appearance?.reduceMotion));
  }, [snapshot]);
  const mutate = async (operation) => {
    setBusy(true);
    try {
      await operation();
      await refresh();
      setError(null);
      return true;
    } catch (cause) {
      setError(cause.message);
      return false;
    } finally {
      setBusy(false);
    }
  };
  if (!snapshot) return (
    <div className="boot-screen">
      <ProductIcon size={72} className="boot-icon" />
      <Busy label={error ?? 'Starting local gateway'} />
    </div>
  );
  const pages = {
    dashboard: <Dashboard snapshot={snapshot} navigate={setActive} />,
    providers: <Providers snapshot={snapshot} mutate={mutate} />,
    routing: <Routing snapshot={snapshot} mutate={mutate} />,
    catalog: <Catalog snapshot={snapshot} mutate={mutate} />,
    usage: <Usage snapshot={snapshot} />,
    logs: <Logs snapshot={snapshot} refresh={refresh} />,
    settings: <Settings snapshot={snapshot} mutate={mutate} />,
  };
  return <Shell active={active} onNavigate={setActive} snapshot={snapshot}>
    {error ? <div className="error-banner" role="alert">{error}<button onClick={() => setError(null)}>Dismiss</button></div> : null}
    {busy ? <div className="busy-overlay" aria-live="polite"><Busy /></div> : null}
    <div className="page-scroll" key={active}>{pages[active]}</div>
  </Shell>;
}
