import React, { useState } from 'react';
import { Check, RotateCcw, Shuffle, Waypoints } from 'lucide-react';
import { Field, PageHeader, Panel } from '../components/Common.jsx';

const strategies = [
  ['priority', 'Priority', 'Lowest numeric account priority first.'],
  ['round-robin', 'Round robin', 'Cycle evenly through eligible routes.'],
  ['weighted-random', 'Weighted random', 'Distribute probability using account weights.'],
  ['least-inflight', 'Least in-flight', 'Prefer the route handling the fewest active requests.'],
  ['lowest-latency', 'Lowest latency', 'Use exponentially weighted recent latency.'],
  ['lowest-cost', 'Lowest estimated cost', 'Use your pricing catalog for the requested model.'],
  ['sticky', 'Sticky session', 'Pin a client session to a healthy account temporarily.'],
];

export function Routing({ snapshot, mutate }) {
  const [routing, setRouting] = useState(snapshot.config.routing);
  React.useEffect(() => setRouting(snapshot.config.routing), [snapshot.config.routing]);
  const save = () => mutate(() => window.spi.updateConfig({ routing }));
  return <>
    <PageHeader eyebrow="Routing domain" title="Load balancing and failover" description="Set one global policy, override it per provider, and define how aggressively transient failures are isolated." actions={<><button className="secondary-button" title="Clear every provider override" onClick={() => mutate(() => window.spi.resetRoutingOverrides(routing.strategy))}><RotateCcw size={15} /> Replace overrides</button><button className="primary-button" onClick={save}><Check size={15} /> Apply routing</button></>} />
    <Panel title="Global strategy" description="The default used by every provider without an override.">
      <div className="strategy-grid">{strategies.map(([id, name, description]) => <button key={id} className={`strategy-card ${routing.strategy === id ? 'selected' : ''}`} onClick={() => setRouting({ ...routing, strategy: id })}><div>{id === 'weighted-random' ? <Shuffle size={18} /> : <Waypoints size={18} />}{routing.strategy === id ? <Check size={15} className="strategy-check" /> : null}</div><strong>{name}</strong><span>{description}</span></button>)}</div>
    </Panel>
    <div className="two-column">
      <Panel title="Retry policy" description="Caps apply across accounts and providers for a single request.">
        <div className="form-grid single-column">
          <Field label="Maximum attempts"><input type="number" min="1" max="20" value={routing.maxAttempts} onChange={(event) => setRouting({ ...routing, maxAttempts: Number(event.target.value) })} /></Field>
          <Field label="Base cooldown"><div className="unit-input"><input type="number" min="100" value={routing.baseCooldownMs} onChange={(event) => setRouting({ ...routing, baseCooldownMs: Number(event.target.value) })} /><span>ms</span></div></Field>
          <Field label="Maximum cooldown"><div className="unit-input"><input type="number" min="1000" value={routing.maxCooldownMs} onChange={(event) => setRouting({ ...routing, maxCooldownMs: Number(event.target.value) })} /><span>ms</span></div></Field>
          <Field label="Fail over on auth errors"><label className="switch-row"><input type="checkbox" checked={routing.failoverOnAuthError} onChange={(event) => setRouting({ ...routing, failoverOnAuthError: event.target.checked })} /><span>Try another account while flagging the failed one</span></label></Field>
        </div>
      </Panel>
      <Panel title="Sticky sessions" description="Session keys come from x-session-id or compatible client metadata.">
        <Field label="Sticky TTL"><div className="unit-input"><input type="number" min="1000" value={routing.stickyTtlMs} onChange={(event) => setRouting({ ...routing, stickyTtlMs: Number(event.target.value) })} /><span>ms</span></div></Field>
        <div className="info-strip"><Waypoints size={17} /><div><strong>Safe streaming boundary</strong><span>A failed stream can move only before any text or tool invocation reaches the client.</span></div></div>
      </Panel>
    </div>
    <Panel title="Provider overrides" description="Overrides remain local to one provider. The reset icon above clears all of them at once.">
      <div className="override-list">{snapshot.config.providers.map((provider) => <div className="override-row" key={provider.id}><div className="provider-glyph">{provider.name.slice(0, 2).toUpperCase()}</div><div><strong>{provider.name}</strong><span>{provider.type}</span></div><select value={provider.strategyOverride ?? ''} onChange={(event) => mutate(() => window.spi.updateProvider(provider.id, { strategyOverride: event.target.value || null }))}><option value="">Inherit {routing.strategy}</option>{strategies.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select></div>)}</div>
    </Panel>
  </>;
}
