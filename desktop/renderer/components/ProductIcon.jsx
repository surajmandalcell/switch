import React from 'react';
import iconUrl from '../assets/icon.svg';

export function ProductIcon({ size = 32, className = '' }) {
  return (
    <img
      src={iconUrl}
      width={size}
      height={size}
      className={`product-icon ${className}`.trim()}
      alt=""
      aria-hidden="true"
      draggable="false"
    />
  );
}
