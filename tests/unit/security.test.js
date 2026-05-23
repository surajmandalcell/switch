import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildAllowedOrigins,
  evaluateRequestAccess,
  isAllowedApiEndpoint,
  isLoopbackAddress,
  redactSensitiveConfig
} from '../../src/security.js';

function req({ method = 'GET', path = '/', headers = {}, remoteAddress = '127.0.0.1' } = {}) {
  return {
    method,
    path,
    headers,
    socket: { remoteAddress }
  };
}

test('isLoopbackAddress: recognizes IPv4, IPv6, and mapped loopback addresses', () => {
  assert.equal(isLoopbackAddress('127.0.0.1'), true);
  assert.equal(isLoopbackAddress('::1'), true);
  assert.equal(isLoopbackAddress('::ffff:127.0.0.1'), true);
  assert.equal(isLoopbackAddress('192.168.1.50'), false);
});

test('evaluateRequestAccess: blocks browser cross-site control-plane mutations', () => {
	const result = evaluateRequestAccess(req({
	  method: 'POST',
	  path: '/account/refresh',
	  headers: { 'sec-fetch-site': 'cross-site' }
	}));

  assert.equal(result.allowed, false);
  assert.equal(result.status, 403);
});

test('evaluateRequestAccess: permits same-origin control-plane mutations on loopback', () => {
	const result = evaluateRequestAccess(req({
	  method: 'POST',
	  path: '/account/refresh',
	  headers: { 'sec-fetch-site': 'same-origin', origin: 'http://localhost:8081' }
	}), { allowedOrigins: ['http://localhost:8081'] });

  assert.equal(result.allowed, true);
});

test('evaluateRequestAccess: blocks non-loopback control-plane requests without admin token', () => {
  const result = evaluateRequestAccess(req({
    method: 'POST',
    path: '/claude/config/set',
    remoteAddress: '192.168.1.50'
  }), { adminToken: 'local-secret' });

  assert.equal(result.allowed, false);
  assert.equal(result.status, 403);
});

test('evaluateRequestAccess: blocks non-loopback control-plane reads without admin token', () => {
	const result = evaluateRequestAccess(req({
	  method: 'GET',
	  path: '/account',
	  remoteAddress: '192.168.1.50'
	}), { adminToken: 'local-secret' });

  assert.equal(result.allowed, false);
  assert.equal(result.status, 403);
});

test('evaluateRequestAccess: allows non-loopback control-plane requests with admin token', () => {
  const result = evaluateRequestAccess(req({
    method: 'POST',
    path: '/claude/config/set',
    headers: { 'x-codex-proxy-admin-token': 'local-secret' },
    remoteAddress: '192.168.1.50'
  }), { adminToken: 'local-secret' });

  assert.equal(result.allowed, true);
});

test('redactSensitiveConfig: redacts nested token and key values', () => {
  const config = {
    env: {
      ANTHROPIC_API_KEY: 'sk-ant-real',
      ANTHROPIC_AUTH_TOKEN: 'token-real',
      ANTHROPIC_BASE_URL: 'http://localhost:8081'
    }
  };

  assert.deepEqual(redactSensitiveConfig(config), {
    env: {
      ANTHROPIC_API_KEY: '[redacted]',
      ANTHROPIC_AUTH_TOKEN: '[redacted]',
      ANTHROPIC_BASE_URL: 'http://localhost:8081'
    }
  });
});

test('isAllowedApiEndpoint: allows loopback URLs and rejects external URLs by default', () => {
  assert.equal(isAllowedApiEndpoint('http://localhost:8081'), true);
  assert.equal(isAllowedApiEndpoint('http://127.0.0.1:8081'), true);
  assert.equal(isAllowedApiEndpoint('https://example.com/proxy'), false);
});

test('buildAllowedOrigins: only includes portless localhost for default HTTP port', () => {
  assert.equal(buildAllowedOrigins(8081).includes('http://localhost'), false);
  assert.equal(buildAllowedOrigins(80).includes('http://localhost'), true);
});
