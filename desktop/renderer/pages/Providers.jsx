import React, { useMemo, useState } from 'react';
import {
  ChevronDown,
  ChevronRight,
  CirclePlus,
  KeyRound,
  Save,
  Trash2,
  UserRoundPlus,
} from 'lucide-react';
import { Empty, Field, PageHeader, Panel } from '../components/Common.jsx';

const strategies = ['priority', 'round-robin', 'weighted-random', 'least-inflight', 'lowest-latency', 'lowest-cost', 'sticky'];
const emptyLimits = {
  requestsPerMinute: null,
  tokensPerDay: null,
  tokensPerMonth: null,
  costPerMonthUsd: null,
};

export function Providers({ snapshot, mutate }) {
  const [expanded, setExpanded] = useState(new Set());
  const [presetType, setPresetType] = useState('openai');
  const preset = useMemo(
    () => snapshot.providerPresets.find((item) => item.type === presetType),
    [snapshot, presetType],
  );
  const providers = snapshot.config.providers;

  const toggle = (id) => setExpanded((current) => {
    const next = new Set(current);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    return next;
  });

  const add = () => mutate(async () => {
    const result = await window.spi.addProvider(preset);
    const newest = result.providers.at(-1);
    if (newest) setExpanded((current) => new Set([...current, newest.id]));
  });

  return (
    <>
      <PageHeader
        eyebrow="Configuration"
        title="Providers"
        description="Configure upstream adapters and one or more encrypted accounts for each provider."
        actions={(
          <div className="page-action-group">
            <label className="action-select">
              <span className="visually-hidden">Provider preset</span>
              <select value={presetType} onChange={(event) => setPresetType(event.target.value)}>
                {snapshot.providerPresets.map((item) => (
                  <option value={item.type} key={item.type}>{item.name}</option>
                ))}
              </select>
            </label>
            <button className="primary-button" type="button" onClick={add}>
              <CirclePlus size={16} /> Add provider
            </button>
          </div>
        )}
      />

      <div className="provider-stack">
        {providers.length ? providers.map((provider) => (
          <ProviderEditor
            key={provider.id}
            provider={provider}
            open={expanded.has(provider.id)}
            toggle={() => toggle(provider.id)}
            mutate={mutate}
            globalStrategy={snapshot.config.routing.strategy}
          />
        )) : (
          <Panel title="Provider list">
            <Empty
              title="No providers configured"
              description="Select a provider preset and add at least one account."
            />
          </Panel>
        )}
      </div>
    </>
  );
}

function ProviderEditor({ provider, open, toggle, mutate, globalStrategy }) {
  const [draft, setDraft] = useState(provider);
  const [headersText, setHeadersText] = useState(pretty(provider.headers));
  const [adapterText, setAdapterText] = useState(pretty(provider.adapter));

  React.useEffect(() => {
    setDraft(provider);
    setHeadersText(pretty(provider.headers));
    setAdapterText(pretty(provider.adapter));
  }, [provider]);

  const patch = (key, value) => setDraft((current) => ({ ...current, [key]: value }));
  const save = () => mutate(() => window.spi.updateProvider(provider.id, {
    ...draft,
    headers: parseObject(headersText, 'Custom headers'),
    adapter: parseObject(adapterText, 'Adapter options'),
  }));

  return (
    <section className={`provider-card ${open ? 'open' : ''}`}>
      <header className="provider-header">
        <button
          className="disclosure"
          type="button"
          aria-label={`${open ? 'Collapse' : 'Expand'} ${provider.name}`}
          aria-expanded={open}
          onClick={toggle}
        >
          {open ? <ChevronDown size={18} /> : <ChevronRight size={18} />}
        </button>
        <div className="provider-glyph large">{provider.name.slice(0, 2).toUpperCase()}</div>
        <div className="provider-title">
          <strong>{provider.name}</strong>
          <span>{provider.type} · {provider.accounts.length} account{provider.accounts.length === 1 ? '' : 's'}</span>
        </div>
        <span className={`badge ${provider.enabled ? 'success' : 'muted'}`}>
          {provider.enabled ? 'Enabled' : 'Disabled'}
        </span>
        <button
          className="icon-button danger"
          type="button"
          title="Remove provider"
          aria-label={`Remove ${provider.name}`}
          onClick={() => mutate(() => window.spi.removeProvider(provider.id))}
        >
          <Trash2 size={16} />
        </button>
      </header>

      {open ? (
        <div className="provider-detail">
          <section className="editor-section">
            <header className="editor-section-heading">
              <h3>Connection and routing</h3>
              <p>Provider identity, endpoint, model eligibility, and routing behavior.</p>
            </header>
            <div className="form-grid">
              <Field label="Display name">
                <input value={draft.name} onChange={(event) => patch('name', event.target.value)} />
              </Field>
              <Field label="Adapter type">
                <input value={draft.type} disabled />
              </Field>
              <Field label="Base URL" wide>
                <input
                  value={draft.baseUrl}
                  onChange={(event) => patch('baseUrl', event.target.value)}
                  placeholder="Provider API base URL"
                />
              </Field>
              <Field label="Eligible models" hint="Comma-separated globs, for example gpt-* or gemini-2.*">
                <input
                  value={draft.modelGlobs.join(', ')}
                  onChange={(event) => patch(
                    'modelGlobs',
                    event.target.value.split(',').map((item) => item.trim()).filter(Boolean),
                  )}
                />
              </Field>
              <Field label="Routing override">
                <select
                  value={draft.strategyOverride ?? ''}
                  onChange={(event) => patch('strategyOverride', event.target.value || null)}
                >
                  <option value="">Inherit {globalStrategy}</option>
                  {strategies.map((item) => <option key={item}>{item}</option>)}
                </select>
              </Field>
              <Field label="Maximum attempts">
                <input
                  type="number"
                  min="1"
                  max="20"
                  value={draft.maxAttempts ?? ''}
                  placeholder="Use global value"
                  onChange={(event) => patch('maxAttempts', event.target.value ? Number(event.target.value) : null)}
                />
              </Field>
              <Field label="Enabled">
                <label className="switch-row">
                  <input
                    type="checkbox"
                    checked={draft.enabled}
                    onChange={(event) => patch('enabled', event.target.checked)}
                  />
                  <span>{draft.enabled ? 'Accept new traffic' : 'Excluded from routing'}</span>
                </label>
              </Field>
            </div>
          </section>

          <section className="editor-section">
            <header className="editor-section-heading">
              <h3>Advanced adapter configuration</h3>
              <p>JSON is validated before the provider is saved.</p>
            </header>
            <div className="form-grid">
              <Field label="Custom headers" hint="Credential-shaped header names are rejected." wide>
                <textarea
                  rows="5"
                  value={headersText}
                  onChange={(event) => setHeadersText(event.target.value)}
                  spellCheck="false"
                />
              </Field>
              <Field label="Adapter options" hint="CLI commands, polling, service tiers, or trusted modules." wide>
                <textarea
                  rows="7"
                  value={adapterText}
                  onChange={(event) => setAdapterText(event.target.value)}
                  spellCheck="false"
                />
              </Field>
            </div>
          </section>

          <div className="editor-actions">
            <button
              className="secondary-button"
              type="button"
              onClick={() => {
                setDraft(provider);
                setHeadersText(pretty(provider.headers));
                setAdapterText(pretty(provider.adapter));
              }}
            >
              Discard
            </button>
            <button className="primary-button" type="button" onClick={save}>
              <Save size={16} /> Save provider
            </button>
          </div>

          <Accounts provider={provider} mutate={mutate} />
        </div>
      ) : null}
    </section>
  );
}

function Accounts({ provider, mutate }) {
  const [showAdd, setShowAdd] = useState(false);
  const [account, setAccount] = useState({
    label: '',
    secret: '',
    enabled: true,
    priority: 100,
    weight: 1,
    limits: emptyLimits,
  });

  const update = (key, value) => setAccount((current) => ({ ...current, [key]: value }));
  const updateLimit = (key, value) => update('limits', {
    ...account.limits,
    [key]: nullableNumber(value),
  });
  const reset = () => setAccount({
    label: '',
    secret: '',
    enabled: true,
    priority: 100,
    weight: 1,
    limits: emptyLimits,
  });
  const submit = async () => {
    await mutate(() => window.spi.addAccount(provider.id, account));
    reset();
    setShowAdd(false);
  };

  return (
    <section className="accounts-block">
      <div className="subheading">
        <div>
          <h3>Accounts</h3>
          <p>Credentials are encrypted in the main process. Limits are local safeguards.</p>
        </div>
        <button className="secondary-button" type="button" onClick={() => setShowAdd((value) => !value)}>
          <UserRoundPlus size={16} /> Add account
        </button>
      </div>

      {showAdd ? (
        <div className="account-form form-grid">
          <Field label="Label">
            <input value={account.label} onChange={(event) => update('label', event.target.value)} placeholder="Primary" />
          </Field>
          <Field label="API key or token">
            <input
              type="password"
              value={account.secret}
              onChange={(event) => update('secret', event.target.value)}
              placeholder="Encrypted after save"
            />
          </Field>
          <Field label="Priority">
            <input type="number" min="0" value={account.priority} onChange={(event) => update('priority', Number(event.target.value))} />
          </Field>
          <Field label="Weight">
            <input type="number" min="0.01" step="0.1" value={account.weight} onChange={(event) => update('weight', Number(event.target.value))} />
          </Field>
          <Field label="Requests per minute">
            <input type="number" min="0" value={account.limits.requestsPerMinute ?? ''} onChange={(event) => updateLimit('requestsPerMinute', event.target.value)} placeholder="Unlimited" />
          </Field>
          <Field label="Tokens per day">
            <input type="number" min="0" value={account.limits.tokensPerDay ?? ''} onChange={(event) => updateLimit('tokensPerDay', event.target.value)} placeholder="Unlimited" />
          </Field>
          <Field label="Tokens per month">
            <input type="number" min="0" value={account.limits.tokensPerMonth ?? ''} onChange={(event) => updateLimit('tokensPerMonth', event.target.value)} placeholder="Unlimited" />
          </Field>
          <Field label="Monthly cost limit (USD)">
            <input type="number" min="0" step="0.01" value={account.limits.costPerMonthUsd ?? ''} onChange={(event) => updateLimit('costPerMonthUsd', event.target.value)} placeholder="Unlimited" />
          </Field>
          <Field label="Enabled">
            <label className="switch-row">
              <input type="checkbox" checked={account.enabled} onChange={(event) => update('enabled', event.target.checked)} />
              <span>Eligible immediately after save</span>
            </label>
          </Field>
          <div className="editor-actions wide">
            <button className="secondary-button" type="button" onClick={() => { reset(); setShowAdd(false); }}>Cancel</button>
            <button className="primary-button" type="button" disabled={!account.label || !account.secret} onClick={submit}>
              <KeyRound size={16} /> Encrypt and add
            </button>
          </div>
        </div>
      ) : null}

      {provider.accounts.length ? (
        <div className="account-list">
          {provider.accounts.map((item) => (
            <AccountEditor key={item.id} providerId={provider.id} account={item} mutate={mutate} />
          ))}
        </div>
      ) : (
        <Empty title="No accounts" description="Add a credential to make this provider eligible for routing." />
      )}
    </section>
  );
}

function AccountEditor({ providerId, account, mutate }) {
  const [draft, setDraft] = useState({
    ...account,
    secret: '',
    limits: { ...emptyLimits, ...account.limits },
  });

  React.useEffect(() => {
    setDraft({
      ...account,
      secret: '',
      limits: { ...emptyLimits, ...account.limits },
    });
  }, [account]);

  const update = (key, value) => setDraft((current) => ({ ...current, [key]: value }));
  const updateLimit = (key, value) => update('limits', {
    ...draft.limits,
    [key]: nullableNumber(value),
  });

  return (
    <article className="account-card">
      <header>
        <div className="account-main">
          <div className="avatar">{account.label.slice(0, 1).toUpperCase()}</div>
          <div>
            <strong>{account.label}</strong>
            <span>{account.hasSecret ? 'Credential stored' : 'Credential missing'} · {account.enabled ? 'enabled' : 'disabled'}</span>
          </div>
        </div>
        <div className="account-actions">
          <button className="icon-button" type="button" title="Save account" onClick={() => mutate(() => window.spi.updateAccount(providerId, account.id, draft))}>
            <Save size={16} />
          </button>
          <button className="icon-button danger" type="button" title="Remove account" onClick={() => mutate(() => window.spi.removeAccount(providerId, account.id))}>
            <Trash2 size={16} />
          </button>
        </div>
      </header>
      <div className="form-grid account-details">
        <Field label="Label">
          <input value={draft.label} onChange={(event) => update('label', event.target.value)} />
        </Field>
        <Field label="Replace credential">
          <input type="password" value={draft.secret} placeholder="Leave unchanged" onChange={(event) => update('secret', event.target.value)} />
        </Field>
        <Field label="Priority">
          <input type="number" min="0" value={draft.priority} onChange={(event) => update('priority', Number(event.target.value))} />
        </Field>
        <Field label="Weight">
          <input type="number" min="0.01" step="0.1" value={draft.weight} onChange={(event) => update('weight', Number(event.target.value))} />
        </Field>
        <Field label="Requests per minute">
          <input type="number" min="0" value={draft.limits.requestsPerMinute ?? ''} onChange={(event) => updateLimit('requestsPerMinute', event.target.value)} placeholder="Unlimited" />
        </Field>
        <Field label="Tokens per day">
          <input type="number" min="0" value={draft.limits.tokensPerDay ?? ''} onChange={(event) => updateLimit('tokensPerDay', event.target.value)} placeholder="Unlimited" />
        </Field>
        <Field label="Tokens per month">
          <input type="number" min="0" value={draft.limits.tokensPerMonth ?? ''} onChange={(event) => updateLimit('tokensPerMonth', event.target.value)} placeholder="Unlimited" />
        </Field>
        <Field label="Monthly cost limit (USD)">
          <input type="number" min="0" step="0.01" value={draft.limits.costPerMonthUsd ?? ''} onChange={(event) => updateLimit('costPerMonthUsd', event.target.value)} placeholder="Unlimited" />
        </Field>
        <Field label="Enabled">
          <label className="switch-row">
            <input type="checkbox" checked={draft.enabled} onChange={(event) => update('enabled', event.target.checked)} />
            <span>{draft.enabled ? 'Eligible for routing' : 'Disabled'}</span>
          </label>
        </Field>
      </div>
    </article>
  );
}

function pretty(value) {
  return JSON.stringify(value ?? {}, null, 2);
}

function parseObject(value, label) {
  let parsed;
  try {
    parsed = JSON.parse(value || '{}');
  } catch (error) {
    throw new Error(`${label} must be valid JSON: ${error.message}`);
  }
  if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
    throw new Error(`${label} must be a JSON object.`);
  }
  return parsed;
}

function nullableNumber(value) {
  return value === '' ? null : Number(value);
}
