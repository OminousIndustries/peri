/* PERI · Head — client side of the neck. Decides *when* to move (choreography); the server decides *how*
   (limits, speed, acceleration, coil release). The neck is slow (≈15°/s) and only ±20° — so motion is
   subtle, deliberate body language, never a snap. Motion is suppressed while listening (stepper noise reaches the mics). */
import { api } from './api.js';
import { log } from './log.js';

const rand = (a, b) => a + Math.random() * (b - a);

export class Head {
  constructor({ socket, getSettings, scope, config }) {
    this.socket = socket; this.getSettings = getSettings; this.scope = scope;
    this.driver = (config && config.head && config.head.driver) || 'none';
    this.limits = (config && config.head && config.head.limits) || { min: -20, max: 20 };
    this.state = { angle: 0, target: 0, moving: false };
    this.phase = 'sleep'; this._swayT = 0; this._swaySide = 1; this._ponderTimer = 0; this.gazeLead = 0; this._holdUntil = 0;
    socket.on('head.state', (m) => { this.state = m; if (m.limits) this.limits = m.limits; scope && scope.setHead(m.angle || 0); });
    socket.on('hello', (m) => { if (m.head) { this.state = m.head; this.driver = m.head.driver || this.driver; if (m.head.limits) this.limits = m.head.limits; } });
  }

  get enabled() { const s = this.getSettings(); return this.driver !== 'none' && s.head && s.head.enabled; }
  get L() { const s = this.getSettings(); return Math.min(s.head.limit_deg, this.limits.max); }
  get k() { return this.getSettings().head.intensity; }

  /** Suppress automatic choreography for a while (used when the model or user explicitly moved the head). */
  holdAuto(ms = 9000) { this._holdUntil = Date.now() + ms; clearTimeout(this._ponderTimer); }
  get autoOk() { return Date.now() >= this._holdUntil; }

  move(angle, speed) {
    if (!this.enabled) return;
    const msg = { t: 'head.move', angle: Math.max(-this.L, Math.min(this.L, angle)) };
    if (speed) msg.speed_dps = speed;
    if (!this.socket.send(msg)) api.post('/api/head/move', { angle: msg.angle, speed_dps: speed }).catch((e) => log.warn('head.move: ' + e.message));
  }
  gesture(name, intensity = 1) {
    if (!this.enabled) return;
    if (!this.socket.send({ t: 'head.gesture', name, intensity })) api.post('/api/head/gesture', { name, intensity }).catch((e) => log.warn('head.gesture: ' + e.message));
  }

  /** Called on every conversation phase change. */
  onPhase(phase, prev) {
    this.phase = phase;
    clearTimeout(this._ponderTimer);
    if (phase === 'sleep') { if (prev !== 'sleep') this.gesture('sleep'); return; }
    if ((prev === 'sleep' || prev === 'connecting') && (phase === 'listening' || phase === 'idle')) this.gesture('wake');
    if (phase === 'thinking' && this.getSettings().head.idle_motion && this.autoOk) this._ponderTimer = setTimeout(() => this.gesture('ponder', 0.8), 450);
    if (phase === 'speaking' && this.getSettings().head.idle_motion) { this._swayT = rand(3.0, 4.5); }
    if (phase === 'listening' && prev === 'speaking') { /* hold position — being still while the user talks reads as attention */ }
  }

  /** Per-frame: slow sway while speaking + lead the pupil in the direction of travel. */
  tick(dt) {
    const s = this.state || {};
    const target = s.target ?? s.angle ?? 0, angle = s.angle ?? 0;
    const lead = s.moving ? Math.max(-1, Math.min(1, (target - angle) / 6)) * 0.55 : 0;
    this.gazeLead += (lead - this.gazeLead) * Math.min(1, dt * 5);
    if (this.scope) this.scope.setGaze(this.gazeLead, 0);

    if (this.phase === 'speaking' && this.enabled && this.getSettings().head.idle_motion && this.autoOk) {
      this._swayT -= dt;
      if (this._swayT <= 0) {
        this._swayT = rand(4.5, 8.0);
        const cur = s.angle || 0, L = this.L;
        this._swaySide = cur > 0.25 * L ? -1 : cur < -0.25 * L ? 1 : (Math.random() < 0.5 ? 1 : -1);
        this.move(this._swaySide * rand(0.25, 0.6) * L * this.k / 0.7, rand(5, 8));
      }
    }
  }
}
