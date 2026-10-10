/* PERI · API client — REST + auto-reconnecting websocket (contract: docs/API.md) */
import { log } from './log.js';

async function req(method, path, body) {
  const r = await fetch(path, { method, headers: body ? { 'Content-Type': 'application/json' } : undefined, body: body ? JSON.stringify(body) : undefined });
  let data = null;
  const txt = await r.text();
  try { data = txt ? JSON.parse(txt) : null; } catch (_) { data = { raw: txt }; }
  if (!r.ok) {
    const err = new Error((data && data.error && data.error.message) || `HTTP ${r.status}`);
    err.status = r.status; err.code = data && data.error && data.error.code; err.data = data;
    throw err;
  }
  return data;
}

export const api = {
  get: (p) => req('GET', p),
  post: (p, b) => req('POST', p, b || {}),
  put: (p, b) => req('PUT', p, b || {}),
};

/** Websocket with backoff. handlers: Map<type, Set<fn>> */
export class Socket {
  constructor(path = '/api/ws') {
    this.path = path; this.ws = null; this.handlers = new Map(); this.retry = 0; this.open = false; this.clients = 0;
    this._connect();
  }
  on(type, fn) { if (!this.handlers.has(type)) this.handlers.set(type, new Set()); this.handlers.get(type).add(fn); return () => this.handlers.get(type).delete(fn); }
  _emit(type, msg) { const s = this.handlers.get(type); if (s) for (const fn of s) { try { fn(msg); } catch (e) { log.error('socket handler ' + type + ': ' + e.message); } } }
  _connect() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    let ws;
    try { ws = new WebSocket(`${proto}://${location.host}${this.path}`); } catch (e) { return this._later(); }
    this.ws = ws;
    ws.onopen = () => { this.open = true; this.retry = 0; this._emit('open', {}); };
    ws.onmessage = (e) => { let m; try { m = JSON.parse(e.data); } catch (_) { return; } this._emit(m.t, m); this._emit('*', m); };
    ws.onclose = () => { this.open = false; this._emit('close', {}); this._later(); };
    ws.onerror = () => { try { ws.close(); } catch (_) {} };
  }
  _later() { const d = Math.min(8000, 400 * Math.pow(1.7, this.retry++)); setTimeout(() => this._connect(), d); }
  send(obj) { if (this.open) { try { this.ws.send(JSON.stringify(obj)); return true; } catch (_) {} } return false; }
}
