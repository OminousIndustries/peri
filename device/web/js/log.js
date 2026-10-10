/* PERI · client logging — mirrors to console and ships to the server journal (POST /api/client-log)
   so a headless installer agent can read UI errors with `journalctl -u peri-server`. */
const buf = [];
let timer = 0, sending = false, disabled = false;
const MAX = 200;

async function flush() {
  timer = 0;
  if (sending || !buf.length || disabled) return;
  sending = true;
  const entries = buf.splice(0, 50);
  try {
    const r = await fetch('/api/client-log', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ entries }) });
    if (r.status === 404) disabled = true;   // running from a static host (website demo) — stop trying
  } catch (_) { /* server not reachable — drop */ }
  sending = false;
  if (buf.length) timer = setTimeout(flush, 500);
}

function push(level, msg, ctx) {
  const e = { level, msg: String(msg), ctx: ctx && typeof ctx === 'object' ? ctx : (ctx != null ? { v: String(ctx) } : undefined), t: Date.now() };
  (console[level] || console.log)('[peri]', msg, ctx ?? '');
  buf.push(e); if (buf.length > MAX) buf.shift();
  if (!timer) timer = setTimeout(flush, level === 'error' ? 50 : 1500);
}

export const log = {
  debug: (m, c) => push('debug', m, c), info: (m, c) => push('info', m, c),
  warn: (m, c) => push('warn', m, c), error: (m, c) => push('error', m, c),
  recent: () => buf.slice(-40),
};

window.addEventListener('error', (e) => log.error('window.error: ' + e.message, { src: e.filename, line: e.lineno }));
window.addEventListener('unhandledrejection', (e) => log.error('unhandledrejection: ' + (e.reason && e.reason.message || e.reason)));
