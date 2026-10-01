const assert = require('node:assert/strict');
const test = require('node:test');
const { assetPath, errorSummary } = require('./diagnostics.cjs');
test('retains only loopback static asset paths, never query or fragment data', () => {
  assert.equal(
    assetPath(
      'http://127.0.0.1:3036/vite-dev/entrypoints/dashboard.js?token=synthetic-secret#secret'
    ),
    '/vite-dev/entrypoints/dashboard.js'
  );
  assert.equal(
    assetPath('http://localhost:4310/vite-dev/@vite/client'),
    '/vite-dev/@vite/client'
  );
  assert.equal(
    assetPath(
      'http://127.0.0.1:4310/app/login?sso_auth_token=synthetic-secret'
    ),
    null
  );
  assert.equal(
    assetPath('https://external.test/asset.js?secret=synthetic-secret'),
    null
  );
  assert.equal(assetPath('data:text/javascript,synthetic-secret'), null);
});
test('runtime reports classify errors without messages, tokens or stacks', () => {
  assert.deepEqual(
    errorSummary({
      name: 'TypeError',
      message:
        'Failed to fetch dynamically imported module: http://localhost/app/login?sso_auth_token=synthetic-secret',
      stack: 'private trace',
    }),
    { name: 'TypeError', code: 'module-fetch-failed' }
  );
  assert.deepEqual(
    errorSummary({
      name: 'ReferenceError',
      message: 'synthetic-secret is not defined',
    }),
    { name: 'ReferenceError', code: 'unclassified' }
  );
  assert.deepEqual(
    errorSummary({
      name: 'synthetic-secret',
      message: 'net::ERR_CONNECTION_REFUSED',
    }),
    { name: 'Error', code: 'ERR_CONNECTION_REFUSED' }
  );
  assert.deepEqual(
    errorSummary({
      name: 'TimeoutError',
      message:
        'page.waitForURL: Timeout 120000ms exceeded. http://localhost/app/login?email=synthetic-secret',
    }),
    { name: 'TimeoutError', code: 'timeout' }
  );
});

test('classifies WebSocket startup errors without retaining messages or tokens', () => {
  assert.deepEqual(
    errorSummary({
      name: 'Error',
      message: 'WebSocket closed without opened.',
    }),
    { name: 'Error', code: 'websocket-before-open' }
  );
});
test('classifies HTTP and resize failures without response bodies or trace data', () => {
  assert.deepEqual(
    errorSummary({
      name: 'Error',
      message:
        'Request failed with status code 401: {"token":"synthetic-secret"}',
    }),
    { name: 'Error', code: 'http-401' }
  );
  assert.deepEqual(
    errorSummary({
      name: 'Error',
      message: 'ResizeObserver loop completed with undelivered notifications.',
    }),
    { name: 'Error', code: 'resize-observer-loop' }
  );
});
