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

  return (
    <>
      <PageHeader
        eyebrow="Configuration"
        title="Settings"
        description="Configure the loopback server, local authentication, data retention, theme, density, and motion."
        actions={(
          <button className="primary-button" type="button" onClick={save}>
            <Check size={16} /> Save settings
          </button>
        )}
      />

      <div className="two-column">
        <Panel title="Compatibility server" description="The service accepts loopback addresses only.">
          <div className="form-grid single-column">
            <Field label="Host" hint="Fixed to loopback">
              <input value={server.host} disabled />
            </Field>
            <Field label="Port">
              <input type="number" min="1024" max="65535" value={server.port} onChange={(event) => setServer({ ...server, port: Number(event.target.value) })} />
            </Field>
            <Field label="Request timeout">
              <div className="unit-input">
                <input type="number" min="1000" value={server.requestTimeoutMs} onChange={(event) => setServer({ ...server, requestTimeoutMs: Number(event.target.value) })} />
                <span>ms</span>
              </div>
            </Field>
            <Field label="Allowed browser origins" hint="Exact comma-separated origins. Empty denies cross-origin browser requests.">
              <input
                value={Array.isArray(server.corsOrigins) ? server.corsOrigins.join(', ') : server.corsOrigins}
                onChange={(event) => setServer({ ...server, corsOrigins: event.target.value })}
                placeholder="http://127.0.0.1:3000"
              />
            </Field>
            <Field label="Usage retention">
              <div className="unit-input">
                <input type="number" min="1" max="3650" value={retentionDays} onChange={(event) => setRetentionDays(Number(event.target.value))} />
                <span>days</span>
              </div>
            </Field>
            <Field label="Start on login">
              <label className="switch-row">
                <input type="checkbox" checked={server.startOnLogin} onChange={(event) => setServer({ ...server, startOnLogin: event.target.checked })} />
                <span>Launch after the operating-system sign-in</span>
              </label>
            </Field>
          </div>
        </Panel>

        <Panel title="Appearance" description="One renderer and one layout system are used on every supported platform.">
          <div className="form-grid single-column">
            <Field label="Theme">
              <select value={appearance.theme} onChange={(event) => setAppearance({ ...appearance, theme: event.target.value })}>
                <option value="system">System</option>
                <option value="dark">Dark</option>
                <option value="light">Light</option>
              </select>
            </Field>
            <Field label="Compact density">
              <label className="switch-row">
                <input type="checkbox" checked={appearance.compact} onChange={(event) => setAppearance({ ...appearance, compact: event.target.checked })} />
                <span>Reduce control and row height</span>
              </label>
            </Field>
            <Field label="Reduce motion">
              <label className="switch-row">
                <input type="checkbox" checked={appearance.reduceMotion} onChange={(event) => setAppearance({ ...appearance, reduceMotion: event.target.checked })} />
                <span>Disable nonessential transitions</span>
              </label>
            </Field>
          </div>
          <p className="panel-note icon-note">
            <MonitorCog size={18} aria-hidden="true" />
            Layouts use a shared 8 px spacing grid and responsive column rules.
          </p>
        </Panel>
      </div>

      <Panel title="Local API authentication" description="Protect every route except /health with an encrypted bearer key.">
        <div className="api-key-row">
          <div className="security-copy">
            <KeyRound size={20} />
            <div>
              <strong>{server.hasApiKey ? 'Authentication enabled' : 'No local key configured'}</strong>
              <span>The key is stored in the main process and is never returned to this screen.</span>
            </div>
          </div>
          <input
            type="password"
            autoComplete="new-password"
            value={apiKey}
            onChange={(event) => setApiKey(event.target.value)}
            placeholder={server.hasApiKey ? 'Enter a replacement key' : 'Enter a local key'}
          />
          <button className="primary-button" type="button" disabled={!apiKey.trim()} onClick={saveApiKey}>
            {server.hasApiKey ? 'Replace key' : 'Enable key'}
          </button>
          {server.hasApiKey ? (
            <button className="icon-button danger" type="button" title="Disable local API key" onClick={clearApiKey}>
              <Trash2 size={16} />
            </button>
          ) : null}
        </div>
      </Panel>

      <Panel title="Security boundary" description="The renderer receives redacted configuration and operational data.">
        <div className="security-grid">
          <div>
            <LockKeyhole size={20} />
            <strong>Encrypted vault</strong>
            <span>Electron safeStorage with an AES-256-GCM fallback.</span>
          </div>
          <div>
            <LockKeyhole size={20} />
            <strong>Sandboxed renderer</strong>
            <span>Context isolation, no Node integration, and a finite IPC bridge.</span>
          </div>
          <button
            className="secondary-button"
            type="button"
            onClick={() => window.spi.openExternal('https://github.com/surajmandalcell/subscription-proxy-inator/blob/master/docs/SECURITY.md')}
          >
            Security documentation <ExternalLink size={15} />
          </button>
        </div>
      </Panel>
    </>
  );
}
