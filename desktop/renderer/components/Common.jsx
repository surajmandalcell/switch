import React from 'react';
import { LoaderCircle } from 'lucide-react';

export function PageHeader({ eyebrow, title, description, actions }) {
  return (
    <header className="page-header">
      <span className="eyebrow">{eyebrow}</span>
      <div className="page-heading">
        <h1>{title}</h1>
        {description ? <p>{description}</p> : null}
      </div>
      {actions ? <div className="page-actions">{actions}</div> : null}
    </header>
  );
}

export function Panel({ title, description, action, children, className = '' }) {
  return (
    <section className={`panel ${className}`}>
      <header className="panel-header">
        <div className="panel-heading">
          <h2>{title}</h2>
          {description ? <p>{description}</p> : null}
        </div>
        {action ? <div className="panel-action">{action}</div> : null}
      </header>
      <div className="panel-body">{children}</div>
    </section>
  );
}

export function Metric({ label, value, detail, icon: Icon }) {
  return (
    <article className="metric">
      <div className="metric-top">
        <span>{label}</span>
        {Icon ? <Icon size={18} aria-hidden="true" /> : null}
      </div>
      <strong>{value}</strong>
      <small>{detail}</small>
    </article>
  );
}

export function Field({ label, hint, children, wide = false }) {
  return (
    <label className={`field ${wide ? 'wide' : ''}`}>
      <span>{label}</span>
      {children}
      {hint ? <small>{hint}</small> : null}
    </label>
  );
}

export function Empty({ title, description }) {
  return (
    <div className="empty-state">
      <span className="empty-label">No data</span>
      <h3>{title}</h3>
      <p>{description}</p>
    </div>
  );
}

export function Busy({ label = 'Applying changes' }) {
  return (
    <div className="busy" role="status">
      <LoaderCircle className="spin" size={18} aria-hidden="true" />
      {label}
    </div>
  );
}

export function formatNumber(value) {
  return new Intl.NumberFormat(undefined, {
    maximumFractionDigits: 1,
    notation: Number(value) >= 10_000 ? 'compact' : 'standard',
  }).format(Number(value ?? 0));
}

export function formatUsd(value) {
  return new Intl.NumberFormat(undefined, {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: Number(value) < 1 ? 4 : 2,
  }).format(Number(value ?? 0));
}
