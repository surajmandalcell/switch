import React, { useState } from 'react';
import { Check, ExternalLink, KeyRound, LockKeyhole, MonitorCog, Trash2 } from 'lucide-react';
import { Field, PageHeader, Panel } from '../components/Common.jsx';

export function Settings({ snapshot, mutate }) {
  const [server, setServer] = useState(snapshot.config.server);
  const [appearance, setAppearance] = useState(snapshot.config.appearance);
  const [retentionDays, setRetentionDays] = useState(snapshot.config.retentionDays);
  const [apiKey, setApiKey] = useState('');
  React.useEffect(() => {
    setServer(snapshot.config.server);
    setAppearance(snapshot.config.appearance);
    setRetentionDays(snapshot.config.retentionDays);
  }, [snapshot]);
  const save = () => mutate(() => window.spi.updateConfig({
    server: {
      ...server,
      corsOrigins: typeof server.corsOrigins === 'string'
        ? server.corsOrigins.split(',').map((item) => item.trim()).filter(Boolean)
        : server.corsOrigins,
    },
    appearance,
    retentionDays: Number(retentionDays),
  }));
  const saveApiKey = async () => {
    await mutate(() => window.spi.setApiKey(apiKey));
    setApiKey('');
  };
  const clearApiKey = () => mutate(() => window.spi.clearApiKey());

  return <>
    <PageHeader eyebrow="Application settings" title="Local service and appearance" description="Configure the loopback gateway, exact CORS origins, local authentication, request lifecycle, retention, theme, and compact density." actions={<button className="primary-button" onClick={save}><Check size={15} /> Save settings</button>} />
    <div className="two-column">
      <Panel title="Compatibility server" description="The process refuses non-loopback bind addresses.">
        <div className="form-grid single-column">
          <Field label="Host" hint="Locked to loopback for credential safety"><input value={server.host} disabled /></Field>
          <Field label="Port"><input type="number" min="1024" max="65535" value={server.port} onChange={(event) => setServer({ ...server, port: Number(event.target.value) })} /></Field>
          <Field label="Request timeout"><div className="unit-input"><input type="number" min="1000" value={server.requestTimeoutMs} onChange={(event) => setServer({ ...server, requestTimeoutMs: Number(event.target.value) })} /><span>ms</span></div></Field>
          <Field label="Allowed browser origins" hint="Exact comma-separated origins; empty denies cross-origin browser access"><input value={Array.isArray(server.corsOrigins) ? server.corsOrigins.join(', ') : server.corsOrigins} onChange={(event) => setServer({ ...server, corsOrigins: event.target.value })} placeholder="http://127.0.0.1:3000" /></Field>
          <Field label="Usage retention"><div className="unit-input"><input type="number" min="1" max="3650" value={retentionDays} onChange={(event) => setRetentionDays(Number(event.target.value))} /><span>days</span></div></Field>
          <Field label="Start on login"><label className="switch-row"><input type="checkbox" checked={server.startOnLogin} onChange={(event) => setServer({ ...server, startOnLogin: event.target.checked })} /><span>Launch the desktop gateway after sign-in</span></label></Field>
        </div>
      </Panel>
      <Panel title="Appearance" description="One renderer keeps geometry consistent on macOS, Windows, and Linux.">
        <div className="form-grid single-column">
          <Field label="Theme"><select value={appearance.theme} onChange={(event) => setAppearance({ ...appearance, theme: event.target.value })}><option value="system">System</option><option value="dark">Dark</option><option value="light">Light</option></select></Field>
          <Field label="Compact density"><label className="switch-row"><input type="checkbox" checked={appearance.compact} onChange={(event) => setAppearance({ ...appearance, compact: event.target.checked })} /><span>Tighter controls and tables</span></label></Field>
          <Field label="Reduce motion"><label className="switch-row"><input type="checkbox" checked={appearance.reduceMotion} onChange={(event) => setAppearance({ ...appearance, reduceMotion: event.target.checked })} /><span>Disable nonessential transitions</span></label></Field>
        </div>
        <div className="info-strip"><MonitorCog size={17} /><div><strong>Shared pixel system</strong><span>Native vibrancy and acrylic are backdrops beneath the same renderer.</span></div></div>
      </Panel>
    </div>
    <Panel title="Local API authentication" description="Protect every route except /health with one encrypted bearer key.">
      <div className="api-key-row">
        <div className="security-copy"><KeyRound size={18} /><div><strong>{server.hasApiKey ? 'Authentication enabled' : 'No local key configured'}</strong><span>The key is encrypted in the main process and never returned to this screen.</span></div></div>
        <input type="password" autoComplete="new-password" value={apiKey} onChange={(event) => setApiKey(event.target.value)} placeholder={server.hasApiKey ? 'Enter a replacement key' : 'Enter a strong local key'} />
        <button className="primary-button" disabled={!apiKey.trim()} onClick={saveApiKey}>{server.hasApiKey ? 'Replace key' : 'Enable key'}</button>
        {server.hasApiKey ? <button className="icon-button danger" title="Disable local API key" onClick={clearApiKey}><Trash2 size={15} /></button> : null}
      </div>
    </Panel>
    <Panel title="Security boundary" description="Credentials never enter the renderer snapshot.">
      <div className="security-grid"><div><LockKeyhole size={18} /><strong>Encrypted vault</strong><span>Electron safeStorage with AES-256-GCM fallback.</span></div><div><LockKeyhole size={18} /><strong>Sandboxed renderer</strong><span>Context isolation, no Node integration, finite IPC bridge.</span></div><button className="secondary-button" onClick={() => window.spi.openExternal('https://github.com/surajmandalcell/subscription-proxy-inator/blob/master/docs/SECURITY.md')}>Security model <ExternalLink size={14} /></button></div>
    </Panel>
  </>;
}
