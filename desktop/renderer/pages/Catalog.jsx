import React, { useEffect, useState } from 'react';
import { CirclePlus, Save, Tags, Trash2 } from 'lucide-react';
import { Empty, Field, PageHeader, Panel } from '../components/Common.jsx';

const newId = (prefix) => `${prefix}_${globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2)}`;

export function Catalog({ snapshot, mutate }) {
  const [aliases, setAliases] = useState(snapshot.config.modelAliases ?? []);
  const [pricing, setPricing] = useState(snapshot.config.pricing ?? []);
  useEffect(() => {
    setAliases(snapshot.config.modelAliases ?? []);
    setPricing(snapshot.config.pricing ?? []);
  }, [snapshot.config.modelAliases, snapshot.config.pricing]);

  const save = () => mutate(() => window.spi.updateConfig({ modelAliases: aliases, pricing }));
  const addAlias = () => setAliases((items) => [...items, { id: newId('alias'), requested: '', providerId: null, target: '' }]);
  const addPrice = () => setPricing((items) => [...items, {
    id: newId('price'), providerId: null, providerType: null, modelGlob: '*',
    inputPerMillionUsd: 0, outputPerMillionUsd: 0, cacheReadPerMillionUsd: 0,
    cacheWritePerMillionUsd: 0, sourceUrl: '', verifiedAt: new Date().toISOString().slice(0, 10),
  }]);

  return <>
    <PageHeader eyebrow="Model domain" title="Aliases and pricing" description="Map client-facing model names to provider targets, then maintain the source-linked pricing catalog used by lowest-cost routing and local estimates." actions={<button className="primary-button" onClick={save}><Save size={15} /> Save catalog</button>} />
    <Panel title="Model aliases" description="Provider-specific aliases take precedence over global aliases.">
      <div className="catalog-toolbar"><button className="secondary-button" onClick={addAlias}><CirclePlus size={14} /> Add alias</button></div>
      {aliases.length ? <div className="catalog-list">{aliases.map((alias, index) => <div className="alias-row" key={alias.id ?? index}>
        <Field label="Requested model"><input value={alias.requested ?? ''} onChange={(event) => setAliases(updateAt(aliases, index, { requested: event.target.value }))} placeholder="claude-sonnet" /></Field>
        <Field label="Provider scope"><select value={alias.providerId ?? ''} onChange={(event) => setAliases(updateAt(aliases, index, { providerId: event.target.value || null }))}><option value="">All providers</option>{snapshot.config.providers.map((provider) => <option key={provider.id} value={provider.id}>{provider.name}</option>)}</select></Field>
        <Field label="Upstream target"><input value={alias.target ?? ''} onChange={(event) => setAliases(updateAt(aliases, index, { target: event.target.value }))} placeholder="gpt-5" /></Field>
        <button className="icon-button danger catalog-delete" title="Remove alias" onClick={() => setAliases(aliases.filter((_, itemIndex) => itemIndex !== index))}><Trash2 size={14} /></button>
      </div>)}</div> : <Empty title="No aliases" description="Direct model IDs pass through unchanged until an alias is added." />}
    </Panel>
    <Panel title="Pricing catalog" description="Rates are USD per one million tokens. Exact provider and model rules outrank broad type or glob rules." action={<button className="secondary-button" onClick={addPrice}><CirclePlus size={14} /> Add price</button>}>
      {pricing.length ? <div className="price-list">{pricing.map((rule, index) => <article className="price-card" key={rule.id ?? index}>
        <div className="price-card-title"><Tags size={16} /><strong>{rule.modelGlob || 'Unnamed rule'}</strong><button className="icon-button danger" title="Remove price" onClick={() => setPricing(pricing.filter((_, itemIndex) => itemIndex !== index))}><Trash2 size={14} /></button></div>
        <div className="form-grid price-grid">
          <Field label="Provider"><select value={rule.providerId ?? ''} onChange={(event) => setPricing(updateAt(pricing, index, { providerId: event.target.value || null, providerType: event.target.value ? null : rule.providerType }))}><option value="">Any provider</option>{snapshot.config.providers.map((provider) => <option key={provider.id} value={provider.id}>{provider.name}</option>)}</select></Field>
          <Field label="Provider type"><select value={rule.providerType ?? ''} disabled={Boolean(rule.providerId)} onChange={(event) => setPricing(updateAt(pricing, index, { providerType: event.target.value || null }))}><option value="">Any type</option>{snapshot.providerPresets.map((preset) => <option key={preset.type} value={preset.type}>{preset.name}</option>)}</select></Field>
          <Field label="Model glob"><input value={rule.modelGlob ?? '*'} onChange={(event) => setPricing(updateAt(pricing, index, { modelGlob: event.target.value }))} /></Field>
          <Field label="Input / 1M"><input type="number" min="0" step="0.000001" value={rule.inputPerMillionUsd ?? 0} onChange={(event) => setPricing(updateAt(pricing, index, { inputPerMillionUsd: Number(event.target.value) }))} /></Field>
          <Field label="Output / 1M"><input type="number" min="0" step="0.000001" value={rule.outputPerMillionUsd ?? 0} onChange={(event) => setPricing(updateAt(pricing, index, { outputPerMillionUsd: Number(event.target.value) }))} /></Field>
          <Field label="Cache read / 1M"><input type="number" min="0" step="0.000001" value={rule.cacheReadPerMillionUsd ?? 0} onChange={(event) => setPricing(updateAt(pricing, index, { cacheReadPerMillionUsd: Number(event.target.value) }))} /></Field>
          <Field label="Cache write / 1M"><input type="number" min="0" step="0.000001" value={rule.cacheWritePerMillionUsd ?? 0} onChange={(event) => setPricing(updateAt(pricing, index, { cacheWritePerMillionUsd: Number(event.target.value) }))} /></Field>
          <Field label="Verified"><input type="date" value={(rule.verifiedAt ?? '').slice(0, 10)} onChange={(event) => setPricing(updateAt(pricing, index, { verifiedAt: event.target.value }))} /></Field>
          <Field label="Source URL" wide><input type="url" value={rule.sourceUrl ?? ''} onChange={(event) => setPricing(updateAt(pricing, index, { sourceUrl: event.target.value }))} placeholder="https://provider.example/pricing" /></Field>
        </div>
      </article>)}</div> : <Empty title="No pricing rules" description="Usage is still recorded, but cost remains unknown and lowest-cost routing treats routes as zero only until you add verified rates." />}
    </Panel>
  </>;
}

function updateAt(items, index, patch) {
  return items.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item);
}
