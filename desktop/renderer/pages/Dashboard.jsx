import React from 'react';
import { Activity, CircleDollarSign, Clock3, MoveRight, Route, ShieldCheck } from 'lucide-react';
import { Empty, Metric, PageHeader, Panel, formatNumber, formatUsd } from '../components/Common.jsx';

const endpoints = [
  ['POST', '/v1/chat/completions'],
  ['POST', '/v1/responses'],
  ['POST', '/v1/messages'],
  ['POST', '/v1/messages/count_tokens'],
  ['GET', '/v1/models'],
  ['GET', '/health'],
];

export function Dashboard({ snapshot, navigate }) {
  const summary = snapshot.usageSummary ?? {};
  const providers = snapshot.config.providers ?? [];
  const accounts = providers.flatMap((provider) => provider.accounts ?? []);
  const eligibleAccounts = accounts.filter((account) => {
    const runtime = snapshot.runtime?.[account.id] ?? {};
    return account.enabled !== false && !runtime.attention && (runtime.cooldownUntil ?? 0) <= Date.now();
  }).length;

  return (
    <>
      <PageHeader
        eyebrow="Overview"
        title="Gateway overview"
        description="Current provider, account, request, and local API state."
        actions={(
          <button className="primary-button" type="button" onClick={() => navigate('providers')}>
            Add provider <MoveRight size={16} />
          </button>
        )}
      />

      <div className="metric-grid">
        <Metric
          icon={Route}
          label="Enabled providers"
          value={providers.filter((provider) => provider.enabled).length}
          detail={`${accounts.length} configured account${accounts.length === 1 ? '' : 's'}`}
        />
        <Metric
          icon={ShieldCheck}
          label="Eligible accounts"
          value={eligibleAccounts}
          detail="Available for new requests"
        />
        <Metric
          icon={Activity}
          label="Recorded requests"
          value={formatNumber(summary.requests)}
          detail={`${formatNumber(summary.successes)} completed`}
        />
        <Metric
          icon={CircleDollarSign}
          label="Estimated cost"
          value={formatUsd(summary.estimatedCostUsd)}
          detail="Calculated from the pricing catalog"
        />
      </div>

      <div className="two-column">
        <Panel title="Provider availability" description="Configured routing state by provider.">
          {providers.length ? (
            <div className="route-list">
              {providers.map((provider) => (
                <div className="route-row" key={provider.id}>
                  <div className="provider-glyph">{provider.name.slice(0, 2).toUpperCase()}</div>
                  <div className="route-copy">
                    <strong>{provider.name}</strong>
                    <span>
                      {(provider.accounts ?? []).length} account{(provider.accounts ?? []).length === 1 ? '' : 's'} ·{' '}
                      {provider.strategyOverride ?? snapshot.config.routing.strategy}
                    </span>
                  </div>
                  <span className={`badge ${provider.enabled ? 'success' : 'muted'}`}>
                    {provider.enabled ? 'Enabled' : 'Disabled'}
                  </span>
                </div>
              ))}
            </div>
          ) : (
            <Empty
              title="No providers configured"
              description="Add a provider and at least one account before sending requests."
            />
          )}
        </Panel>

        <Panel title="Local API" description={snapshot.serverUrl ?? 'Loopback compatibility server'}>
          <div className="endpoint-table">
            {endpoints.map(([method, path]) => (
              <div className="endpoint-row" key={`${method}-${path}`}>
                <span className={`method method-${method.toLowerCase()}`}>{method}</span>
                <code>{path}</code>
              </div>
            ))}
          </div>
          <p className="panel-note">
            Failover can occur only before text or a tool call becomes visible to the client.
          </p>
        </Panel>
      </div>

      <Panel title="Recent requests" description="Latest normalized requests across all supported client protocols.">
        {snapshot.recentUsage?.length ? (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Status</th>
                  <th>Model</th>
                  <th>Provider</th>
                  <th>Tokens</th>
                  <th>Latency</th>
                  <th>Cost</th>
                </tr>
              </thead>
              <tbody>
                {snapshot.recentUsage.slice(0, 8).map((record) => (
                  <tr key={record.id}>
                    <td>
                      <span className={`badge ${record.status === 'success' ? 'success' : record.status === 'cancelled' ? 'muted' : 'danger'}`}>
                        {record.status}
                      </span>
                    </td>
                    <td>{record.requestedModel ?? '—'}</td>
                    <td>{providers.find((provider) => provider.id === record.providerId)?.name ?? '—'}</td>
                    <td>{formatNumber((record.inputTokens ?? 0) + (record.outputTokens ?? 0))}</td>
                    <td>
                      <span className="inline-icon">
                        <Clock3 size={14} />
                        {record.latencyMs ?? '—'} ms
                      </span>
                    </td>
                    <td>{formatUsd(record.estimatedCostUsd)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <Empty
            title="No requests recorded"
            description="Requests appear here after a client uses the local compatibility API."
          />
        )}
      </Panel>
    </>
  );
}
