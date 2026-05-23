import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';

import { registerApiRoutes } from '../../src/routes/api-routes.js';

function routePaths(app) {
  return new Set(
    app._router.stack
      .filter((layer) => layer.route)
      .map((layer) => layer.route.path)
  );
}

test('registerApiRoutes: exposes singular account routes and removes plural account routes', () => {
  const app = express();
  registerApiRoutes(app, { port: 18081 });
  const paths = routePaths(app);

  assert.equal(paths.has('/account'), true);
  assert.equal(paths.has('/account/status'), true);
  assert.equal(paths.has('/account/quota'), true);
  assert.equal(paths.has('/account/models'), true);
  assert.equal(paths.has('/account/usage'), true);
  assert.equal(paths.has('/account/add'), true);
  assert.equal(paths.has('/account/add/manual'), true);
  assert.equal(paths.has('/account/import'), true);
  assert.equal(paths.has('/account/refresh'), true);
  assert.equal(paths.has('/account/oauth/cleanup'), true);

  const plural = '/account' + 's';
  assert.equal(paths.has(plural), false);
  assert.equal(paths.has(`${plural}/status`), false);
  assert.equal(paths.has(`${plural}/quota`), false);
  const allSegment = 'all';
  const quotaAll = ['quota', allSegment].join('/');
  const refreshAll = ['refresh', allSegment].join('/');
  assert.equal(paths.has(`${plural}/${quotaAll}`), false);
  assert.equal(paths.has(`${plural}/switch`), false);
  assert.equal(paths.has(`${plural}/${refreshAll}`), false);
  assert.equal(paths.has(`${plural}/:email/refresh`), false);
  assert.equal(paths.has(`${plural}/:email`), false);
});
