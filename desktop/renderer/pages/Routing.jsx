import React, { useState } from 'react';
import { Check, RotateCcw, Shuffle, Waypoints } from 'lucide-react';
import { Field, PageHeader, Panel } from '../components/Common.jsx';
import { useSyncedDraft } from '../hooks/useSyncedDraft.js';

const strategies = [
  ['priority', 'Priority', 'Use the lowest numeric account priority first.'],
  ['round-robin', 'Round robin', 'Cycle through eligible routes in order.'],
  ['weighted-random', 'Weighted random', 'Use account weights as selection probability.'],
  ['least-inflight', 'Least in-flight', 'Prefer the route with the fewest active requests.'],
  ['lowest-latency', 'Lowest latency', 'Prefer the lowest recent weighted latency.'],
  ['lowest-cost', 'Lowest estimated cost', 'Use the configured model pricing rules.'],
  ['sticky', 'Sticky session', 'Keep a session on one healthy account for a limited time.'],
];

export function Routing({ snapshot, mutate }) {
  const { draft: routing, setDraft: setRouting, markClean } = useSyncedDraft(snapshot.config.routing);

  const save = async () => {
    const succeeded = await mutate(() => window.spi.updateConfig({ routing }));
    if (succeeded) markClean();
  };

  return (
    <>
      <PageHeader
        eyebrow="Configuration"
        title="Routing"
        description="Set the default load-balancing strategy, retry limits, cooldowns, and provider overrides."
        actions={(
          <>
            <button
              className="secondary-button"
              type="button"
              title="Replace all provider overrides with the current default strategy"
              onClick={() => mutate(() => window.spi.resetRoutingOverrides(routing.strategy))}
            >
              <RotateCcw size={16} /> Replace all overrides
            </button>
            <button className="primary-button" type="button" onClick={save}>
              <Check size={16} /> Save routing
            </button>
          </>
        )}
      />

      <Panel title="Default strategy" description="Used by every provider without an explicit override.">
        <div className="strategy-grid">
          {strategies.map(([id, name, description]) => (
            <button
              key={id}
              type="button"
              className={`strategy-card ${routing.strategy === id ? 'selected' : ''}`}
              aria-pressed={routing.strategy === id}
              onClick={() => setRouting({ ...routing, strategy: id })}
            >
              <div className="strategy-card-top">
                {id === 'weighted-random' ? <Shuffle size={20} /> : <Waypoints size={20} />}
                {routing.strategy === id ? <Check size={17} className="strategy-check" /> : null}
              </div>
              <strong>{name}</strong>
              <span>{description}</span>
            </button>
          ))}
        </div>
      </Panel>

      <div className="two-column">
        <Panel title="Retry and cooldown" description="Limits apply to one client request across accounts and providers.">
          <div className="form-grid single-column">
            <Field label="Maximum attempts">
              <input type="number" min="1" max="20" value={routing.maxAttempts} onChange={(event) => setRouting({ ...routing, maxAttempts: Number(event.target.value) })} />
            </Field>
            <Field label="Base cooldown">
              <div className="unit-input">
                <input type="number" min="100" value={routing.baseCooldownMs} onChange={(event) => setRouting({ ...routing, baseCooldownMs: Number(event.target.value) })} />
                <span>ms</span>
              </div>
            </Field>
            <Field label="Maximum cooldown">
              <div className="unit-input">
                <input type="number" min="1000" value={routing.maxCooldownMs} onChange={(event) => setRouting({ ...routing, maxCooldownMs: Number(event.target.value) })} />
                <span>ms</span>
              </div>
            </Field>
            <Field label="Fail over on authentication errors">
              <label className="switch-row">
                <input type="checkbox" checked={routing.failoverOnAuthError} onChange={(event) => setRouting({ ...routing, failoverOnAuthError: event.target.checked })} />
                <span>Try another account and flag the failed account</span>
              </label>
            </Field>
          </div>
        </Panel>

        <Panel title="Sticky sessions" description="The session key comes from x-session-id or compatible client metadata.">
          <Field label="Sticky time to live">
            <div className="unit-input">
              <input type="number" min="1000" value={routing.stickyTtlMs} onChange={(event) => setRouting({ ...routing, stickyTtlMs: Number(event.target.value) })} />
              <span>ms</span>
            </div>
          </Field>
          <p className="panel-note">
            A stream can move to another route only before text or a tool invocation reaches the client.
          </p>
        </Panel>
      </div>

      <Panel title="Provider overrides" description="Each provider can inherit the default strategy or use a specific one.">
        <div className="override-list">
          {snapshot.config.providers.map((provider) => (
            <div className="override-row" key={provider.id}>
              <div className="provider-glyph">{provider.name.slice(0, 2).toUpperCase()}</div>
              <div>
                <strong>{provider.name}</strong>
                <span>{provider.type}</span>
              </div>
              <select
                aria-label={`${provider.name} strategy`}
                value={provider.strategyOverride ?? ''}
                onChange={(event) => mutate(() => window.spi.updateProvider(provider.id, {
                  strategyOverride: event.target.value || null,
                }))}
              >
                <option value="">Inherit {routing.strategy}</option>
                {strategies.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
              </select>
            </div>
          ))}
        </div>
      </Panel>
    </>
  );
}
