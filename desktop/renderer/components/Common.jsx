import React from 'react';
import { LoaderCircle } from 'lucide-react';

export function PageHeader({ eyebrow, title, description, actions }) {
  return <div className="page-header"><div><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p>{description}</p></div>{actions ? <div className="page-actions">{actions}</div> : null}</div>;
}

export function Panel({ title, description, action, children, className = '' }) {
  return <section className={`panel ${className}`}><header className="panel-header"><div><h2>{title}</h2>{description ? <p>{description}</p> : null}</div>{action}</header><div className="panel-body">{children}</div></section>;
}

export function Metric({ label, value, detail, icon: Icon }) {
  return <div className="metric"><div className="metric-icon">{Icon ? <Icon size={17} /> : null}</div><div><span>{label}</span><strong>{value}</strong><small>{detail}</small></div></div>;
}

export function Field({ label, hint, children, wide = false }) {
  return <label className={`field ${wide ? 'wide' : ''}`}><span>{label}</span>{children}{hint ? <small>{hint}</small> : null}</label>;
}

export function Empty({ title, description }) {
  return <div className="empty-state"><div className="empty-orb" /><h3>{title}</h3><p>{description}</p></div>;
}

export function Busy({ label = 'Applying changes' }) {
  return <div className="busy"><LoaderCircle className="spin" size={17} />{label}</div>;
}

export function formatNumber(value) { return new Intl.NumberFormat(undefined, { maximumFractionDigits: 1, notation: Number(value) >= 10_000 ? 'compact' : 'standard' }).format(Number(value ?? 0)); }
export function formatUsd(value) { return new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD', maximumFractionDigits: Number(value) < 1 ? 4 : 2 }).format(Number(value ?? 0)); }
