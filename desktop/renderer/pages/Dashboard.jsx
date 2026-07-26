import React from 'react';
import { Activity, CircleDollarSign, Clock3, Cpu, MoveRight, Route, ShieldCheck, Waves } from 'lucide-react';
import { Metric, PageHeader, Panel, Empty, formatNumber, formatUsd } from '../components/Common.jsx';

export function Dashboard({ snapshot, navigate }) {
  const summary = snapshot.usageSummary ?? {};
  const providers = snapshot.config.providers ?? [];
  const accounts = providers.flatMap((provider) => provider.accounts ?? []);
  const healthy = accounts.filter((account) => !snapshot.runtime?.[account.id]?.attention && (snapshot.runtime?.[account.id]?.cooldownUntil ?? 0) <= Date.now()).length;
  return <>
    <PageHeader eyebrow="Local gateway" title="One endpoint. Every subscription." description="Route compatible AI clients through encrypted accounts, resilient failover, and protocol translation without giving up local control." actions={<button className="primary-button" onClick={() => navigate('providers')}>Configure providers <MoveRight size={15} /></button>} />
    <div className="metric-grid">
      <Metric icon={Route} label="Enabled providers" value={providers.filter((provider) => provider.enabled).length} detail={`${accounts.length} configured accounts`} />
      <Metric icon={ShieldCheck} label="Healthy accounts" value={healthy} detail="Eligible for new requests" />
      <Metric icon={Activity} label="Requests" value={formatNumber(summary.requests)} detail={`${formatNumber(summary.successes)} completed`} />
      <Metric icon={CircleDollarSign} label="Estimated spend" value={formatUsd(summary.estimatedCostUsd)} detail="Based on your pricing catalog" />
    </div>
    <div className="two-column">
      <Panel title="Route health" description="Live account state maintained by the routing domain.">
        {accounts.length ? <div className="route-list">{providers.map((provider) => <div className="route-row" key={provider.id}><div className="provider-glyph">{provider.name.slice(0, 2).toUpperCase()}</div><div className="route-copy"><strong>{provider.name}</strong><span>{provider.accounts.length} account{provider.accounts.length === 1 ? '' : 's'} · {provider.strategyOverride ?? snapshot.config.routing.strategy}</span></div><span className={`badge ${provider.enabled ? 'success' : 'muted'}`}>{provider.enabled ? 'Active' : 'Disabled'}</span></div>)}</div> : <Empty title="No providers yet" description="Add OpenAI, Anthropic, Gemini, Grok, compatible endpoints, or a trusted CLI adapter." />}
      </Panel>
      <Panel title="Gateway contract" description="Stable local endpoints for existing developer tools.">
        <div className="endpoint-stack">
          {['POST /v1/chat/completions','POST /v1/responses','POST /v1/messages','GET /v1/models'].map((endpoint) => <code key={endpoint}>{endpoint}</code>)}
        </div>
        <div className="info-strip"><Waves size={17} /><div><strong>Streaming-safe failover</strong><span>Routes may change only before text or a tool call becomes visible.</span></div></div>
      </Panel>
    </div>
    <Panel title="Recent activity" description="The latest normalized requests across all client protocols.">
      {snapshot.recentUsage?.length ? <div className="table-wrap"><table><thead><tr><th>Status</th><th>Model</th><th>Provider</th><th>Tokens</th><th>Latency</th><th>Cost</th></tr></thead><tbody>{snapshot.recentUsage.slice(0, 8).map((record) => <tr key={record.id}><td><span className={`badge ${record.status === 'success' ? 'success' : record.status === 'cancelled' ? 'muted' : 'danger'}`}>{record.status}</span></td><td>{record.requestedModel ?? '—'}</td><td>{providers.find((provider) => provider.id === record.providerId)?.name ?? '—'}</td><td>{formatNumber((record.inputTokens ?? 0) + (record.outputTokens ?? 0))}</td><td><span className="inline-icon"><Clock3 size={13} />{record.latencyMs ?? '—'} ms</span></td><td>{formatUsd(record.estimatedCostUsd)}</td></tr>)}</tbody></table></div> : <Empty title="No traffic recorded" description="Requests will appear here after a client uses the local compatibility API." />}
    </Panel>
  </>;
}
