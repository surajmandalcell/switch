import React from 'react';
import { Activity, Cable, ChartNoAxesCombined, FileText, Gauge, Network, Settings, SlidersHorizontal, Tags } from 'lucide-react';

const navigation = [
  ['dashboard', 'Overview', Gauge],
  ['providers', 'Providers', Cable],
  ['routing', 'Routing', Network],
  ['catalog', 'Models & pricing', Tags],
  ['usage', 'Usage', ChartNoAxesCombined],
  ['logs', 'Logs', FileText],
  ['settings', 'Settings', Settings],
];

export function Shell({ active, onNavigate, snapshot, children }) {
  return <div className="app-window">
    <Titlebar snapshot={snapshot} />
    <div className="app-body">
      <aside className="sidebar">
        <div className="brand-block">
          <div className="brand-mark"><SlidersHorizontal size={17} /></div>
          <div><strong>Proxy Inator</strong><span>Local AI gateway</span></div>
        </div>
        <nav className="nav-list" aria-label="Application">
          {navigation.map(([id, label, Icon]) => <button key={id} className={`nav-item ${active === id ? 'active' : ''}`} onClick={() => onNavigate(id)}><Icon size={16} /><span>{label}</span></button>)}
        </nav>
        <div className="sidebar-footer">
          <div className={`status-dot ${snapshot ? 'online' : ''}`} />
          <div><strong>{snapshot ? 'Proxy ready' : 'Connecting'}</strong><span>{snapshot?.serverUrl ?? 'Loading local service'}</span></div>
        </div>
      </aside>
      <main className="content-frame">{children}</main>
    </div>
  </div>;
}

function Titlebar({ snapshot }) {
  return <header className="titlebar">
    <div className="traffic-lights" aria-label="Window controls">
      <button className="traffic close" aria-label="Close" onClick={() => window.spi.close()} />
      <button className="traffic minimize" aria-label="Minimize" onClick={() => window.spi.minimize()} />
      <button className="traffic maximize" aria-label="Maximize" onClick={() => window.spi.maximize()} />
    </div>
    <div className="titlebar-center"><Activity size={13} /><span>Subscription Proxy Inator</span></div>
    <div className="titlebar-status"><span className="status-pill"><i />{snapshot?.config?.providers?.filter((provider) => provider.enabled).length ?? 0} providers</span></div>
  </header>;
}
