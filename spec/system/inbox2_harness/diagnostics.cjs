// Never retain authentication URLs, query strings, messages, bodies or traces.
const assetPath = value => {
  try {
    const url = new URL(value);
    if (!['127.0.0.1', 'localhost'].includes(url.hostname)) return null;
    if (
      !['http:', 'https:'].includes(url.protocol) ||
      url.username ||
      url.password
    )
      return null;
    return /^\/(vite-dev|vite-test|assets)\//.test(url.pathname)
      ? url.pathname
      : null;
  } catch {
    return null;
  }
};
const errorSummary = error => {
  const names = [
    'Error',
    'TypeError',
    'ReferenceError',
    'SyntaxError',
    'RangeError',
    'TimeoutError',
    'AssertionError',
  ];
  const name = names.includes(error?.name) ? error.name : 'Error';
  const message = String(error?.message || '');
  const codes = [
    'ERR_CONNECTION_REFUSED',
    'ERR_CONNECTION_RESET',
    'ERR_ABORTED',
    'ERR_FAILED',
    'ERR_BLOCKED_BY_CLIENT',
    'ERR_NAME_NOT_RESOLVED',
  ];
  const code =
    codes.find(item => message.includes(`net::${item}`)) ||
    (/Failed to fetch dynamically imported module/.test(message)
      ? 'module-fetch-failed'
      : /MIME type|MIME-type/.test(message)
        ? 'invalid-module-mime'
        : /Failed to load resource/.test(message)
          ? 'resource-load-failed'
          : /CORS policy|cross-origin/.test(message)
            ? 'cross-origin-blocked'
            : /WebSocket closed without opened/.test(message)
              ? 'websocket-before-open'
              : name === 'TimeoutError'
                ? 'timeout'
                : 'unclassified');
  return { name, code };
};
module.exports = { assetPath, errorSummary };
