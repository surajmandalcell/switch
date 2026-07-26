import React, { useMemo, useState } from 'react';
import { RefreshCw, Search } from 'lucide-react';
import { Empty, PageHeader, Panel } from '../components/Common.jsx';

export function Logs({ snapshot, refresh }) {
  const [query, setQuery] = useState('');
  const [level, setLevel] = useState('');
  const entries = useMemo(
    () => snapshot.logs.filter((entry) => (
      (!level || entry.level === level)
      && (!query || `${entry.message} ${JSON.stringify(entry.fields)}`.toLowerCase().includes(query.toLowerCase()))
    )),
    [snapshot, query, level],
  );

  return (
    <>
      <PageHeader
        eyebrow="Operations"
        title="Logs"
        description="Structured local events with credential-shaped fields and bearer values redacted before display."
        actions={(
          <button className="secondary-button" type="button" onClick={refresh}>
            <RefreshCw size={16} /> Refresh
          </button>
        )}
      />
      <Panel
        title="Event stream"
        description={`${entries.length} matching entr${entries.length === 1 ? 'y' : 'ies'}`}
        action={(
          <div className="filters">
            <label className="search-box">
              <Search size={16} />
              <span className="visually-hidden">Search logs</span>
              <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search logs" />
            </label>
            <label className="action-select">
              <span className="visually-hidden">Log level</span>
              <select value={level} onChange={(event) => setLevel(event.target.value)}>
                <option value="">All levels</option>
                <option value="debug">Debug</option>
                <option value="info">Info</option>
                <option value="warn">Warning</option>
                <option value="error">Error</option>
              </select>
            </label>
          </div>
        )}
      >
        {entries.length ? (
          <div className="log-list">
            {entries.slice().reverse().map((entry) => (
              <article className="log-row" key={entry.id}>
                <time>{new Date(entry.timestamp).toLocaleTimeString()}</time>
                <span className={`log-level ${entry.level}`}>{entry.level}</span>
                <div>
                  <strong>{entry.message}</strong>
                  {Object.keys(entry.fields ?? {}).length ? <code>{JSON.stringify(entry.fields)}</code> : null}
                </div>
              </article>
            ))}
          </div>
        ) : (
          <Empty title="No matching logs" description="Operational events appear here without storing prompts or credentials." />
        )}
      </Panel>
    </>
  );
}
