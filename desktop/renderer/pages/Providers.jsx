import React, { useMemo, useState } from 'react';
import { ChevronDown, ChevronRight, CirclePlus, KeyRound, Save, Trash2, UserRoundPlus } from 'lucide-react';
import { Empty, Field, PageHeader, Panel } from '../components/Common.jsx';

const strategies = ['priority','round-robin','weighted-random','least-inflight','lowest-latency','lowest-cost','sticky'];
const emptyLimits = { requestsPerMinute: null, tokensPerDay: null, tokensPerMonth: null, costPerMonthUsd: null };

export function Providers({ snapshot, mutate }) {
  const [expanded, setExpanded] = useState(new Set());
  const [presetType, setPresetType] = useState('openai');
  const preset = useMemo(() => snapshot.providerPresets.find((item) => item.type === presetType), [snapshot, presetType]);
  const providers = snapshot.config.providers;
  const toggle = (id) => setExpanded((current) => { const next = new Set(current); next.has(id) ? next.delete(id) : next.add(id); return next; });
  const add = () => mutate(async () => {
    const result = await window.spi.addProvider(preset);
    const newest = result.providers.at(-1);
    if (newest) setExpanded((current) => new Set([...current, newest.id]));
  });
  return <>
    <PageHeader eyebrow="Provider domain" title="Providers and accounts" description="Each provider is a protocol adapter. Add multiple encrypted accounts, then tune endpoint details, custom headers, adapter options, priority, weight, local budgets, and provider-specific routing." actions={<div className="inline-form"><select value={presetType} onChange={(event) => setPresetType(event.target.value)}>{snapshot.providerPresets.map((item) => <option value={item.type} key={item.type}>{item.name}</option>)}</select><button className="primary-button" onClick={add}><CirclePlus size={15} /> Add provider</button></div>} />
    <div className="provider-stack">
      {providers.length ? providers.map((provider) => <ProviderEditor key={provider.id} provider={provider} open={expanded.has(provider.id)} toggle={() => toggle(provider.id)} mutate={mutate} globalStrategy={snapshot.config.routing.strategy} />) : <Panel title="Provider catalog"><Empty title="Build your first route" description="Choose a provider preset above. Credentials are encrypted outside the configuration file and never sent to the renderer." /></Panel>}
    </div>
  </>;
}

function ProviderEditor({ provider, open, toggle, mutate, globalStrategy }) {
  const [draft, setDraft] = useState(provider);
  const [headersText, setHeadersText] = useState(pretty(provider.headers));
  const [adapterText, setAdapterText] = useState(pretty(provider.adapter));
  React.useEffect(() => { setDraft(provider); setHeadersText(pretty(provider.headers)); setAdapterText(pretty(provider.adapter)); }, [provider]);
  const patch = (key, value) => setDraft((current) => ({ ...current, [key]: value }));
  const save = () => mutate(() => window.spi.updateProvider(provider.id, {
    ...draft,
    headers: parseObject(headersText, 'Custom headers'),
    adapter: parseObject(adapterText, 'Adapter options'),
  }));
  return <section className={`provider-card ${open ? 'open' : ''}`}>
    <header className="provider-header">
      <button className="disclosure" onClick={toggle}>{open ? <ChevronDown size={16} /> : <ChevronRight size={16} />}</button>
      <div className="provider-glyph large">{provider.name.slice(0, 2).toUpperCase()}</div>
      <div className="provider-title"><strong>{provider.name}</strong><span>{provider.type} · {provider.accounts.length} account{provider.accounts.length === 1 ? '' : 's'}</span></div>
      <span className={`badge ${provider.enabled ? 'success' : 'muted'}`}>{provider.enabled ? 'Enabled' : 'Disabled'}</span>
      <button className="icon-button danger" title="Remove provider" onClick={() => mutate(() => window.spi.removeProvider(provider.id))}><Trash2 size={15} /></button>
    </header>
    {open ? <div className="provider-detail">
      <div className="form-grid">
        <Field label="Display name"><input value={draft.name} onChange={(event) => patch('name', event.target.value)} /></Field>
        <Field label="Adapter type"><input value={draft.type} disabled /></Field>
        <Field label="Base URL" wide><input value={draft.baseUrl} onChange={(event) => patch('baseUrl', event.target.value)} placeholder="Provider API base URL" /></Field>
        <Field label="Eligible models" hint="Comma-separated globs such as gpt-* or gemini-2.*"><input value={draft.modelGlobs.join(', ')} onChange={(event) => patch('modelGlobs', event.target.value.split(',').map((item) => item.trim()).filter(Boolean))} /></Field>
        <Field label="Routing override"><select value={draft.strategyOverride ?? ''} onChange={(event) => patch('strategyOverride', event.target.value || null)}><option value="">Inherit {globalStrategy}</option>{strategies.map((item) => <option key={item}>{item}</option>)}</select></Field>
        <Field label="Maximum attempts"><input type="number" min="1" max="20" value={draft.maxAttempts ?? ''} placeholder="Global" onChange={(event) => patch('maxAttempts', event.target.value ? Number(event.target.value) : null)} /></Field>
        <Field label="Enabled"><label className="switch-row"><input type="checkbox" checked={draft.enabled} onChange={(event) => patch('enabled', event.target.checked)} /><span>{draft.enabled ? 'Accept new traffic' : 'Excluded from routing'}</span></label></Field>
        <Field label="Custom headers" hint="JSON object. Credential-shaped header names are rejected." wide><textarea rows="5" value={headersText} onChange={(event) => setHeadersText(event.target.value)} spellCheck="false" /></Field>
        <Field label="Adapter options" hint="JSON for CLI commands, Deep Research polling, service tiers, or external modules." wide><textarea rows="7" value={adapterText} onChange={(event) => setAdapterText(event.target.value)} spellCheck="false" /></Field>
      </div>
      <div className="editor-actions"><button className="secondary-button" onClick={() => { setDraft(provider); setHeadersText(pretty(provider.headers)); setAdapterText(pretty(provider.adapter)); }}>Discard</button><button className="primary-button" onClick={save}><Save size={15} /> Save provider</button></div>
      <Accounts provider={provider} mutate={mutate} />
    </div> : null}
  </section>;
}

function Accounts({ provider, mutate }) {
  const [showAdd, setShowAdd] = useState(false);
  const [account, setAccount] = useState({ label: '', secret: '', enabled: true, priority: 100, weight: 1, limits: emptyLimits });
  const update = (key, value) => setAccount((current) => ({ ...current, [key]: value }));
  const updateLimit = (key, value) => update('limits', { ...account.limits, [key]: nullableNumber(value) });
  const reset = () => setAccount({ label: '', secret: '', enabled: true, priority: 100, weight: 1, limits: emptyLimits });
  const submit = async () => { await mutate(() => window.spi.addAccount(provider.id, account)); reset(); setShowAdd(false); };
  return <div className="accounts-block">
    <div className="subheading"><div><h3>Accounts</h3><p>Credentials remain encrypted in the main process. Limits are local safeguards, not quota bypasses.</p></div><button className="secondary-button" onClick={() => setShowAdd((value) => !value)}><UserRoundPlus size={15} /> Add account</button></div>
    {showAdd ? <div className="account-form form-grid">
      <Field label="Label"><input value={account.label} onChange={(event) => update('label', event.target.value)} placeholder="Team Pro" /></Field>
      <Field label="API key or token"><input type="password" value={account.secret} onChange={(event) => update('secret', event.target.value)} placeholder="Encrypted after save" /></Field>
      <Field label="Priority"><input type="number" min="0" value={account.priority} onChange={(event) => update('priority', Number(event.target.value))} /></Field>
      <Field label="Weight"><input type="number" min="0.01" step="0.1" value={account.weight} onChange={(event) => update('weight', Number(event.target.value))} /></Field>
      <Field label="Requests / minute"><input type="number" min="0" value={account.limits.requestsPerMinute ?? ''} onChange={(event) => updateLimit('requestsPerMinute', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Tokens / day"><input type="number" min="0" value={account.limits.tokensPerDay ?? ''} onChange={(event) => updateLimit('tokensPerDay', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Tokens / month"><input type="number" min="0" value={account.limits.tokensPerMonth ?? ''} onChange={(event) => updateLimit('tokensPerMonth', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Cost / month (USD)"><input type="number" min="0" step="0.01" value={account.limits.costPerMonthUsd ?? ''} onChange={(event) => updateLimit('costPerMonthUsd', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Enabled"><label className="switch-row"><input type="checkbox" checked={account.enabled} onChange={(event) => update('enabled', event.target.checked)} /><span>Eligible immediately after save</span></label></Field>
      <div className="editor-actions wide"><button className="secondary-button" onClick={() => { reset(); setShowAdd(false); }}>Cancel</button><button className="primary-button" disabled={!account.label || !account.secret} onClick={submit}><KeyRound size={15} /> Encrypt and add</button></div>
    </div> : null}
    {provider.accounts.length ? <div className="account-list">{provider.accounts.map((item) => <AccountEditor key={item.id} providerId={provider.id} account={item} mutate={mutate} />)}</div> : <Empty title="No accounts" description="Add at least one credential to make this provider eligible for routing." />}
  </div>;
}

function AccountEditor({ providerId, account, mutate }) {
  const [draft, setDraft] = useState({ ...account, secret: '', limits: { ...emptyLimits, ...account.limits } });
  React.useEffect(() => setDraft({ ...account, secret: '', limits: { ...emptyLimits, ...account.limits } }), [account]);
  const update = (key, value) => setDraft((current) => ({ ...current, [key]: value }));
  const updateLimit = (key, value) => update('limits', { ...draft.limits, [key]: nullableNumber(value) });
  return <article className="account-card">
    <header><div className="account-main"><div className="avatar">{account.label.slice(0, 1).toUpperCase()}</div><div><strong>{account.label}</strong><span>{account.hasSecret ? 'Credential stored' : 'Credential missing'} · {account.enabled ? 'enabled' : 'disabled'}</span></div></div><div className="account-actions"><button className="icon-button" title="Save account" onClick={() => mutate(() => window.spi.updateAccount(providerId, account.id, draft))}><Save size={15} /></button><button className="icon-button danger" title="Remove account" onClick={() => mutate(() => window.spi.removeAccount(providerId, account.id))}><Trash2 size={15} /></button></div></header>
    <div className="form-grid account-details">
      <Field label="Label"><input value={draft.label} onChange={(event) => update('label', event.target.value)} /></Field>
      <Field label="Replace credential"><input type="password" value={draft.secret} placeholder="Leave unchanged" onChange={(event) => update('secret', event.target.value)} /></Field>
      <Field label="Priority"><input type="number" min="0" value={draft.priority} onChange={(event) => update('priority', Number(event.target.value))} /></Field>
      <Field label="Weight"><input type="number" min="0.01" step="0.1" value={draft.weight} onChange={(event) => update('weight', Number(event.target.value))} /></Field>
      <Field label="Requests / minute"><input type="number" min="0" value={draft.limits.requestsPerMinute ?? ''} onChange={(event) => updateLimit('requestsPerMinute', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Tokens / day"><input type="number" min="0" value={draft.limits.tokensPerDay ?? ''} onChange={(event) => updateLimit('tokensPerDay', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Tokens / month"><input type="number" min="0" value={draft.limits.tokensPerMonth ?? ''} onChange={(event) => updateLimit('tokensPerMonth', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Cost / month (USD)"><input type="number" min="0" step="0.01" value={draft.limits.costPerMonthUsd ?? ''} onChange={(event) => updateLimit('costPerMonthUsd', event.target.value)} placeholder="Unlimited" /></Field>
      <Field label="Enabled"><label className="switch-row"><input type="checkbox" checked={draft.enabled} onChange={(event) => update('enabled', event.target.checked)} /><span>{draft.enabled ? 'Eligible for routing' : 'Temporarily disabled'}</span></label></Field>
    </div>
  </article>;
}

function pretty(value) { return JSON.stringify(value ?? {}, null, 2); }
function parseObject(value, label) {
  let parsed;
  try { parsed = JSON.parse(value || '{}'); } catch (error) { throw new Error(`${label} must be valid JSON: ${error.message}`); }
  if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') throw new Error(`${label} must be a JSON object.`);
  return parsed;
}
function nullableNumber(value) { return value === '' ? null : Number(value); }
