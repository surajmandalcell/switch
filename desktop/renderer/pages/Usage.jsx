import React, { useEffect, useMemo, useState } from 'react';
import {
  ArrowDownToLine,
  CircleDollarSign,
  Database,
  Gauge,
  Layers3,
  LoaderCircle,
  Route,
} from 'lucide-react';
import { Empty, Metric, PageHeader, Panel, formatNumber, formatUsd } from '../components/Common.jsx';

export function Usage({ snapshot }) {
  const [filters, setFilters] = useState({
    status: '',
    providerId: '',
    accountId: '',
    protocol: '',
    from: '',
    to: '',
  });
  const [rows, setRows] = useState(snapshot.recentUsage ?? []);
  const [summary, setSummary] = useState(snapshot.usageSummary ?? {});
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useState(null);
  const [attempts, setAttempts] = useState([]);

  const accounts = useMemo(
    () => snapshot.config.providers.flatMap((provider) => provider.accounts.map((account) => ({
      ...account,
      providerId: provider.id,
      providerName: provider.name,
    }))),
    [snapshot.config.providers],
  );
  const query = useMemo(() => normalizeFilters(filters), [filters]);

  useEffect(() => {
    let active = true;
    setLoading(true);
    Promise.all([
      window.spi.listUsage(query, { limit: 1000 }),
      window.spi.summarizeUsage(query),
    ])
      .then(([records, nextSummary]) => {
        if (active) {
          setRows(records);
          setSummary(nextSummary);
        }
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [query]);

  const selectRequest = async (record) => {
    setSelected(record);
    setAttempts(await window.spi.listAttempts(record.id));
  };

  const exportCsv = async () => {
    const csv = await window.spi.exportUsageCsv(query);
    const blob = new Blob([csv], { type: 'text/csv' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = `subscription-proxy-usage-${new Date().toISOString().slice(0, 10)}.csv`;
    link.click();
    URL.revokeObjectURL(link.href);
  };

  const set = (key) => (event) => setFilters((current) => ({
    ...current,
    [key]: event.target.value,
  }));

  return (
    <>
      <PageHeader
        eyebrow="Operations"
        title="Usage"
        description="Request totals, token accounting, estimated cost, latency, and upstream route attempts."
        actions={(
          <button className="secondary-button" type="button" onClick={exportCsv}>
            <ArrowDownToLine size={16} /> Export CSV
          </button>
        )}
      />

      <div className="metric-grid">
        <Metric
          icon={Gauge}
          label="Filtered requests"
          value={formatNumber(summary.requests)}
          detail={`${formatNumber(summary.successes)} completed`}
        />
        <Metric
          icon={Layers3}
          label="Tokens"
          value={formatNumber(Number(summary.inputTokens ?? 0) + Number(summary.outputTokens ?? 0))}
          detail={`${formatNumber(Number(summary.cacheReadTokens ?? 0) + Number(summary.cacheWriteTokens ?? 0))} cache tokens`}
        />
        <Metric
          icon={CircleDollarSign}
          label="Estimated cost"
          value={formatUsd(summary.estimatedCostUsd)}
          detail="Reported upstream cost is used when available"
        />
        <Metric
          icon={Database}
          label="Retention"
          value={`${snapshot.config.retentionDays} days`}
          detail="Stored in local SQLite"
        />
      </div>

      <Panel
        title="Request ledger"
        description="The same filters apply to the table, summary, and CSV export."
        action={loading ? <LoaderCircle className="spin" size={18} /> : null}
      >
        <div className="usage-filter-grid">
          <label className="filter-field">
            <span>Status</span>
            <select value={filters.status} onChange={set('status')}>
              <option value="">All statuses</option>
              <option value="success">Success</option>
              <option value="error">Error</option>
              <option value="cancelled">Cancelled</option>
            </select>
          </label>
          <label className="filter-field">
            <span>Provider</span>
            <select
              value={filters.providerId}
              onChange={(event) => setFilters((current) => ({
                ...current,
                providerId: event.target.value,
                accountId: '',
              }))}
            >
              <option value="">All providers</option>
              {snapshot.config.providers.map((provider) => (
                <option key={provider.id} value={provider.id}>{provider.name}</option>
              ))}
            </select>
          </label>
          <label className="filter-field">
            <span>Account</span>
            <select value={filters.accountId} onChange={set('accountId')}>
              <option value="">All accounts</option>
              {accounts
                .filter((account) => !filters.providerId || account.providerId === filters.providerId)
                .map((account) => (
                  <option key={account.id} value={account.id}>
                    {account.providerName} · {account.label}
                  </option>
                ))}
            </select>
          </label>
          <label className="filter-field">
            <span>Protocol</span>
            <select value={filters.protocol} onChange={set('protocol')}>
              <option value="">All protocols</option>
              <option value="openai-chat">OpenAI Chat</option>
              <option value="openai-responses">OpenAI Responses</option>
              <option value="anthropic">Anthropic Messages</option>
            </select>
          </label>
          <label className="filter-field">
            <span>From</span>
            <input type="date" value={filters.from} onChange={set('from')} />
          </label>
          <label className="filter-field">
            <span>To</span>
            <input type="date" value={filters.to} onChange={set('to')} />
          </label>
          <button
            className="tertiary-button filter-reset"
            type="button"
            onClick={() => setFilters({
              status: '',
              providerId: '',
              accountId: '',
              protocol: '',
              from: '',
              to: '',
            })}
          >
            Clear
          </button>
        </div>

        {rows.length ? (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Started</th>
                  <th>Status</th>
                  <th>Protocol</th>
                  <th>Model</th>
                  <th>Provider and account</th>
                  <th>Input</th>
                  <th>Output</th>
                  <th>Cache</th>
                  <th>Latency</th>
                  <th>Cost</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((record) => (
                  <tr
                    key={record.id}
                    className={selected?.id === record.id ? 'selected-row' : ''}
                    onClick={() => selectRequest(record)}
                  >
                    <td>{record.startedAt ? new Date(record.startedAt).toLocaleString() : '—'}</td>
                    <td>
                      <span className={`badge ${record.status === 'success' ? 'success' : record.status === 'cancelled' ? 'muted' : 'danger'}`}>
                        {record.status}
                      </span>
                    </td>
                    <td>{record.protocol ?? '—'}</td>
                    <td>
                      {record.requestedModel ?? '—'}
                      {record.upstreamModel && record.upstreamModel !== record.requestedModel ? (
                        <small className="table-subline">→ {record.upstreamModel}</small>
                      ) : null}
                    </td>
                    <td>
                      {snapshot.config.providers.find((provider) => provider.id === record.providerId)?.name ?? '—'}
                      <small className="table-subline">
                        {accounts.find((account) => account.id === record.accountId)?.label ?? record.accountId ?? ''}
                      </small>
                    </td>
                    <td>{formatNumber(record.inputTokens)}</td>
                    <td>{formatNumber(record.outputTokens)}</td>
                    <td>{formatNumber(Number(record.cacheReadTokens ?? 0) + Number(record.cacheWriteTokens ?? 0))}</td>
                    <td>{record.latencyMs ?? '—'} ms</td>
                    <td>{formatUsd(record.estimatedCostUsd)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <Empty title="No matching requests" description="Change the filters or send a request through the local gateway." />
        )}
      </Panel>

      {selected ? (
        <Panel
          title="Route attempts"
          description={`Every upstream attempt recorded for request ${selected.id}.`}
          action={(
            <button className="tertiary-button" type="button" onClick={() => { setSelected(null); setAttempts([]); }}>
              Close
            </button>
          )}
        >
          {attempts.length ? (
            <div className="attempt-timeline">
              {attempts.map((attempt, index) => (
                <article key={attempt.id} className="attempt-row">
                  <div className={`attempt-index ${attempt.status}`}>{index + 1}</div>
                  <Route size={17} aria-hidden="true" />
                  <div>
                    <strong>{snapshot.config.providers.find((provider) => provider.id === attempt.providerId)?.name ?? attempt.providerId}</strong>
                    <span>{accounts.find((account) => account.id === attempt.accountId)?.label ?? attempt.accountId} · {attempt.upstreamModel}</span>
                  </div>
                  <span className={`badge ${attempt.status === 'success' ? 'success' : attempt.status === 'cancelled' ? 'muted' : 'danger'}`}>
                    {attempt.status}
                  </span>
                  <code>{attempt.latencyMs ?? '—'} ms{attempt.errorCode ? ` · ${attempt.errorCode}` : ''}</code>
                </article>
              ))}
            </div>
          ) : (
            <Empty title="No attempt records" description="Pre-routing failures and older records may not include an upstream attempt." />
          )}
        </Panel>
      ) : null}
    </>
  );
}

function normalizeFilters(filters) {
  const output = Object.fromEntries(Object.entries(filters).filter(([, value]) => value));
  if (output.from) output.from = new Date(`${output.from}T00:00:00.000Z`).toISOString();
  if (output.to) output.to = new Date(`${output.to}T23:59:59.999Z`).toISOString();
  return output;
}
