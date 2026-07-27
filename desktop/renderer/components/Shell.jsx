import React from 'react';
import {
  Cable,
  ChartNoAxesCombined,
  FileText,
  Gauge,
  Minus,
  Network,
  Settings,
  Square,
  Tags,
  X,
} from 'lucide-react';
import { ProductIcon } from './ProductIcon.jsx';

const navigation = [
  ['dashboard', 'Overview', Gauge],
  ['providers', 'Providers', Cable],
  ['routing', 'Routing', Network],
  ['catalog', 'Models and pricing', Tags],
  ['usage', 'Usage', ChartNoAxesCombined],
  ['logs', 'Logs', FileText],
  ['settings', 'Settings', Settings],
];

export function Shell({ active, onNavigate, snapshot, children }) {
  const enabledProviders = snapshot?.config?.providers?.filter((provider) => provider.enabled).length ?? 0;
  return (
    <div className="app-shell">
      <Titlebar snapshot={snapshot} enabledProviders={enabledProviders} />
      <div className="workspace">
        <aside className="side-nav">
          <div className="product-block">
            <div className="product-mark" aria-hidden="true">
              <ProductIcon size={36} />
            </div>
            <div className="product-copy">
              <strong>Proxy-Inator</strong>
              <span>Local AI gateway</span>
            </div>
          </div>

          <nav className="nav-list" aria-label="Application">
            {navigation.map(([id, label, Icon]) => (
              <button
                key={id}
                className={`nav-item ${active === id ? 'active' : ''}`}
                type="button"
                aria-current={active === id ? 'page' : undefined}
                title={label}
                onClick={() => onNavigate(id)}
              >
                <Icon size={18} />
                <span>{label}</span>
              </button>
            ))}
          </nav>

          <div className="side-nav-status">
            <span className={`status-dot ${snapshot ? 'online' : ''}`} aria-hidden="true" />
            <div>
              <strong>{snapshot ? 'Gateway available' : 'Connecting'}</strong>
              <span>{snapshot?.serverUrl ?? 'Starting local service'}</span>
            </div>
          </div>
        </aside>
        <main className="main-view">{children}</main>
      </div>
    </div>
  );
}

function Titlebar({ snapshot, enabledProviders }) {
  return (
    <header className="titlebar">
      <div className="titlebar-product">
        <ProductIcon size={24} />
        <span>Subscription Proxy Inator</span>
      </div>

      <div className="titlebar-meta" role="group" aria-label="Gateway status">
        <span className={`topbar-status ${snapshot ? 'online' : 'starting'}`}>
          <i aria-hidden="true" />
          {snapshot ? 'Online' : 'Starting'}
        </span>
        <span className="topbar-count">{enabledProviders} enabled provider{enabledProviders === 1 ? '' : 's'}</span>
      </div>

      <div className="window-controls" aria-label="Window controls">
        <button type="button" aria-label="Minimize" onClick={() => window.spi.minimize()}>
          <Minus size={16} />
        </button>
        <button type="button" aria-label="Maximize" onClick={() => window.spi.maximize()}>
          <Square size={13} />
        </button>
        <button className="window-close" type="button" aria-label="Close" onClick={() => window.spi.close()}>
          <X size={16} />
        </button>
      </div>
    </header>
  );
}
