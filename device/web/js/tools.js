/* PERI · Tools — executes the model's function calls (schemas live in config/tools.json, declared by the server).
   Every tool returns { result, respond }: `respond` says whether the model should speak again after seeing the result. */
import { api } from './api.js';
import { log } from './log.js';

const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
const pad = (n) => String(n).padStart(2, '0');

export class Timers {
  constructor({ onFire }) { this.list = []; this.onFire = onFire; this._id = 1; }
  add(seconds, label) {
    const now = Date.now(), t = { id: this._id++, label: label || '', total: seconds * 1000, endsAt: now + seconds * 1000 };
    t.timeout = setTimeout(() => this._fire(t), seconds * 1000); this.list.push(t); return t;
  }
  cancel(label) {
    let t = label ? this.list.find((x) => x.label.toLowerCase() === String(label).toLowerCase()) : this.list[this.list.length - 1];
    if (!t) return null; clearTimeout(t.timeout); this.list = this.list.filter((x) => x !== t); return t;
  }
  _fire(t) { this.list = this.list.filter((x) => x !== t); this.onFire(t); }
  get active() { return this.list.length > 0; }
  soonest() { return this.list.slice().sort((a, b) => a.endsAt - b.endsAt)[0] || null; }
  fmt(ms) { const s = Math.max(0, Math.ceil(ms / 1000)); return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}` : `${pad(Math.floor(s / 60))}:${pad(s % 60)}`; }
}

export function makeTools({ agent, scope, ui, head, getSettings, timers }) {
  const S = () => getSettings();
  const tools = {
    async move_head({ action, degrees }) {
      if (!head.enabled) return { result: { ok: false, error: 'neck not available' }, respond: true };
      const cur = (head.state && head.state.angle) || 0, d = clamp(Number(degrees) || 10, 3, head.L);
      head.holdAuto(action === 'center' ? 4000 : 9000);
      switch (action) {
        case 'turn_left': head.move(cur - d, 9); break;
        case 'turn_right': head.move(cur + d, 9); break;
        case 'center': head.move(0, 9); break;
        case 'look_around': head.gesture('look_around', 1); break;
        case 'shake_no': head.gesture('shake_no', 1); break;
        case 'perk_up': head.gesture('perk_up', 1); break;
        default: return { result: { ok: false, error: 'unknown action' }, respond: false };
      }
      return { result: { ok: true, action, range_limit_deg: head.L }, respond: false };
    },
    async set_mood({ mood }) { scope.setMood(mood); agent.mood = mood; return { result: { ok: true }, respond: false }; },
    async show_text({ text, seconds }) { ui.card(text, Number(seconds) || 6); return { result: { ok: true }, respond: false }; },
    async set_volume({ level, change }) {
      const cur = S().audio.volume; let v = level != null ? Number(level) : cur + (change === 'down' ? -12 : 12);
      v = clamp(Math.round(v), 0, 100);
      try { await api.put('/api/system/volume', { level: v }); S().audio.volume = v; ui.toast('VOLUME ' + v); } catch (e) { return { result: { ok: false, error: e.message }, respond: true }; }
      return { result: { ok: true, volume: v }, respond: false };
    },
    async set_brightness({ level }) {
      const v = clamp(Math.round(Number(level)), 5, 100);
      try { await api.put('/api/system/brightness', { level: v }); ui.toast('BRIGHTNESS ' + v); } catch (e) { return { result: { ok: false, error: e.message }, respond: true }; }
      return { result: { ok: true, brightness: v }, respond: false };
    },
    async set_timer({ seconds, label }) {
      const s = clamp(Number(seconds) || 0, 1, 86400);
      const t = timers.add(s, label || '');
      agent.onTimersChanged();
      return { result: { ok: true, label: t.label, seconds: s, ends_at: new Date(t.endsAt).toLocaleTimeString() }, respond: true };
    },
    async cancel_timer({ label }) {
      const t = timers.cancel(label); agent.onTimersChanged();
      return { result: t ? { ok: true, cancelled: t.label || 'timer' } : { ok: false, error: 'no such timer' }, respond: true };
    },
    async get_time() {
      const d = new Date(), tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
      return { result: { iso: d.toISOString(), local_date: d.toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' }), local_time: d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }), timezone: tz }, respond: true };
    },
    async end_conversation() { agent.sleepAfterPlayback = true; return { result: { ok: true }, respond: false }; },
  };
  return {
    async run(name, args) {
      const fn = tools[name];
      if (!fn) { log.warn('unknown tool ' + name); return { result: { ok: false, error: 'unknown tool' }, respond: false }; }
      try { const r = await fn(args || {}); log.info('tool ' + name, { args, result: r.result }); return r; }
      catch (e) { log.error('tool ' + name + ' failed: ' + e.message); return { result: { ok: false, error: e.message }, respond: true }; }
    },
  };
}
