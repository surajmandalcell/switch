import React, { useMemo, useState } from 'react';
import { RefreshCw, Search } from 'lucide-react';
import { Empty, PageHeader, Panel } from '../components/Common.jsx';

export function Logs({ snapshot, refresh }) {
  const [query, setQuery] = useState('');
  const [level, setLevel] = useState('');
  const entries = useMemo(() => snapshot.logs.filter((entry) => (!level || entry.level === level) && (!query || `${entry.message} ${JSON.stringify(entry.fields)}`.toLowerCase().includes(query.toLowerCase()))), [snapshot, query, level]);
  return <>
    <PageHeader eyebrow="Diagnostics" title="Local logs" description="Structured, bounded logs with credential-shaped fields and bearer tokens redacted before storage or display." actions={<button className="secondary-button" onClick={refresh}><RefreshCw size={15} /> Refresh</button>} />
    <Panel title="Event stream" description={`${entries.length} visible entries`} action={<div className="filters"><label className="search-box"><Search size={14} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search logs" /></label><select value={level} onChange={(event) => setLevel(event.target.value)}><option value="">All levels</option><option>debug</option><option>info</option><option>warn</option><option>error</option></select></div>}>
      {entries.length ? <div className="log-list">{entries.slice().reverse().map((entry) => <article className="log-row" key={entry.id}><time>{new Date(entry.timestamp).toLocaleTimeString()}</time><span className={`log-level ${entry.level}`}>{entry.level}</span><div><strong>{entry.message}</strong>{Object.keys(entry.fields ?? {}).length ? <code>{JSON.stringify(entry.fields)}</code> : null}</div></article>)}</div> : <Empty title="No matching logs" description="Operational events appear here without storing prompts or credentials." />}
    </Panel>
  </>;
}
