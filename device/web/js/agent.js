/* PERI · Agent — the conversation controller.
   Turns Realtime events into UI phases, owns wake/sleep policy, mic gating (half/full duplex),
   tool execution, timers and reconnection. Phases map 1:1 to Scope states:
   sleep · connecting · idle · listening · thinking · speaking · error                                    */
import { log } from './log.js';

const safeJSON = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };

export class Agent {
  constructor({ audio, scope, ui, head, getSettings, timers }) {
    Object.assign(this, { audio, scope, ui, head, getSettings, timers });
    this.rt = null; this.tools = null;
    this.phase = 'sleep'; this.awake = false; this.muted = false;
    this.userSpeaking = false; this.assistantSpeaking = false; this.responding = false; this.sleepAfterPlayback = false;
    this.mood = 'calm'; this.idleTimer = 0; this.reconnects = 0; this.lastActivity = Date.now(); this.sessionDirty = false;
    this._quietFor = 0; this.turns = 0; this.error = ''; this.onPhaseChange = null;
  }
  bind(rt, tools) { this.rt = rt; this.tools = tools; }
  get S() { return this.getSettings(); }

  // ── phase ───────────────────────────────────────────────────────────────────────────────────
  setPhase(p) {
    if (p === this.phase) return;
    const prev = this.phase; this.phase = p;
    this.scope.setState(p);
    this.head.onPhase(p, prev);
    log.debug('phase ' + prev + ' → ' + p);
    if (this.onPhaseChange) this.onPhaseChange(p, prev);
  }

  // ── boot / warm session ─────────────────────────────────────────────────────────────────────
  async boot() {
    this.setPhase(this.timers.active ? 'idle' : 'sleep');
    this.warm();
    if (this.S.wake_mode === 'always') setTimeout(() => this.wake('always'), 1200);
    setInterval(() => this._maintenance(), 30000);
  }
  async warm() {
    if (this.rt.status === 'ready' || this.rt.status === 'connecting') return;
    try { await this.rt.connect(); this.reconnects = 0; this.sessionDirty = false; }
    catch (e) { if (e && e.superseded) return; log.warn('warm connect failed: ' + e.message); this._scheduleWarmRetry(); }
  }
  _scheduleWarmRetry() {
    const d = Math.min(300000, 8000 * Math.pow(2, Math.min(this.reconnects++, 5)));
    clearTimeout(this._warmT); this._warmT = setTimeout(() => { if (!this.awake) this.warm(); }, d);
  }
  _maintenance() {
    if (this.awake) return;
    const stale = this.rt.status === 'ready' && (this.rt.age > 50 * 60 || this.sessionDirty);
    if (stale) { log.info('refreshing warm session'); this.rt.close(); this.warm(); }
    else if (this.rt.status === 'failed' || this.rt.status === 'closed') this.warm();
  }
  /** A session-level setting changed (persona, voice, model, captions…): refresh the warm session once, after the changes settle. */
  markDirty() {
    this.sessionDirty = true; clearTimeout(this._dirtyT);
    this._dirtyT = setTimeout(() => { if (!this.awake && this.sessionDirty) { this.rt.close(); this.warm(); } }, 1200);
  }

  // ── wake / sleep ────────────────────────────────────────────────────────────────────────────
  async wake(reason = 'tap') {
    if (this.awake) return;
    this.awake = true; this.sleepAfterPlayback = false; this.lastActivity = Date.now();
    log.info('wake', { reason });
    this.audio.chime('wake');
    this.ui.hideCard();
    try {
      // conversation memory: after ≥10 min asleep start a fresh session (fresh context, fresh clock)
      const stale = this.rt.status === 'ready' && (this._sleptAt && Date.now() - this._sleptAt > 10 * 60 * 1000);
      if (stale) this.rt.close();
      if (!this.rt.ready) { this.setPhase('connecting'); await this.rt.connect(); }
      if (!this.awake) return;                      // put back to sleep while connecting
      const stream = await this.audio.openMic();
      await this.rt.attachMic(stream);
      this.audio.setMicEnabled(!this.muted);
      this.setPhase(this.muted ? 'idle' : 'listening');
      this.bumpIdle();
      this.reconnects = 0;
    } catch (e) {
      this.fail(e);
    }
  }
  fail(e) {
    const msg = (e && e.message) || String(e);
    log.error('wake failed: ' + msg, { code: e && e.code, status: e && e.status });
    this.error = (e && e.code === 'no_api_key') ? 'NO KEY' : (e && e.name === 'NotAllowedError') ? 'MIC BLOCKED' : (e && e.name === 'NotFoundError') ? 'NO MIC' : 'OFFLINE';
    this.setPhase('error'); this.audio.chime('error'); this.ui.toast(this.error, 3000);
    clearTimeout(this._failT); this._failT = setTimeout(() => this.sleep('error'), 4500);
  }
  async sleep(reason = 'idle') {
    if (!this.awake && this.phase === 'sleep') return;
    log.info('sleep', { reason });
    this.awake = false; this._sleptAt = Date.now(); clearTimeout(this.idleTimer); clearTimeout(this._failT);
    if (this.assistantSpeaking) { this.rt.send({ type: 'response.cancel' }); this.rt.send({ type: 'output_audio_buffer.clear' }); }
    this.assistantSpeaking = false; this.userSpeaking = false; this.responding = false;
    try { await this.rt.detachMic(); } catch (_) {}
    this.audio.closeMic();
    if (reason !== 'quiet') this.audio.chime('sleep');
    this.ui.audioStopped(); this.ui.clearCaptions();
    this.setPhase(this.timers.active ? 'idle' : 'sleep');
    if (this.rt.status !== 'ready') this.warm();
  }
  bumpIdle() {
    clearTimeout(this.idleTimer); this.lastActivity = Date.now();
    if (!this.awake || this.S.wake_mode === 'always') return;
    this.idleTimer = setTimeout(() => this.sleep('idle-timeout'), this.S.idle_sleep_s * 1000);
  }

  // ── user interactions ───────────────────────────────────────────────────────────────────────
  tap() {
    if (!this.awake) return this.wake('tap');
    if (this.phase === 'speaking' || this.assistantSpeaking) return this.interrupt();
    if (this.phase === 'error') return this.sleep('tap');
    this.toggleMute();
  }
  doubleTap() { if (this.awake) this.sleep('double-tap'); }
  interrupt() {
    if (!this.assistantSpeaking && !this.responding) return;
    log.info('interrupt');
    this.rt.send({ type: 'response.cancel' }); this.rt.send({ type: 'output_audio_buffer.clear' });
    this.assistantSpeaking = false; this.responding = false; this.ui.audioStopped();
    this._restoreMic(); this.setPhase(this.muted ? 'idle' : 'listening'); this.bumpIdle();
  }
  toggleMute(v) {
    this.muted = v == null ? !this.muted : !!v;
    this.scope.setMuted(this.muted); this.audio.setMicEnabled(!this.muted);
    this.audio.chime(this.muted ? 'mute' : 'unmute');
    if (this.awake && (this.phase === 'listening' || this.phase === 'idle')) this.setPhase(this.muted ? 'idle' : 'listening');
    this.bumpIdle();
  }

  // ── mic gating (half-duplex) ────────────────────────────────────────────────────────────────
  get halfDuplex() { return this.S.barge_in === 'tap'; }
  async _restoreMic() {
    if (!this.awake || !this.audio.mic) return;
    try { await this.rt.attachMic(this.audio.mic); this.audio.setMicEnabled(!this.muted); } catch (e) { log.warn('restore mic: ' + e.message); }
  }

  // ── realtime events ─────────────────────────────────────────────────────────────────────────
  onRtStatus(s, info) {
    if (s === 'failed') {
      log.warn('realtime failed', info);
      if (this.awake) {
        if (this.reconnects++ < 3) { this.setPhase('connecting'); setTimeout(async () => { try { await this.rt.connect(); const st = await this.audio.openMic(); await this.rt.attachMic(st); this.setPhase('listening'); this.reconnects = 0; } catch (e) { this.fail(e); } }, 900 * this.reconnects); }
        else this.fail(new Error('connection lost'));
      } else this._scheduleWarmRetry();
    }
  }

  onEvent(e) {
    switch (e.type) {
      case 'input_audio_buffer.speech_started':
        this.userSpeaking = true; this.bumpIdle(); clearTimeout(this.idleTimer);
        if (this.assistantSpeaking) { this.assistantSpeaking = false; this.ui.audioStopped(); }
        if (this.awake) this.setPhase('listening');
        break;
      case 'input_audio_buffer.speech_stopped':
        this.userSpeaking = false; if (this.awake && !this.muted) this.setPhase('thinking'); break;
      case 'conversation.item.input_audio_transcription.completed':
        if (e.transcript) { this.ui.setUser(e.transcript); log.info('user said', { t: e.transcript.slice(0, 120) }); } break;
      case 'response.created':
        this.responding = true; this.ui.startAssistant(); clearTimeout(this.idleTimer);
        if (!this.assistantSpeaking && this.awake) this.setPhase('thinking'); break;
      case 'response.output_audio_transcript.delta':
        this.ui.appendAssistant(e.delta || ''); break;
      case 'output_audio_buffer.started':
        this.assistantSpeaking = true; this._quietFor = 0; this.ui.audioStarted(); clearTimeout(this.idleTimer);
        if (this.awake) this.setPhase('speaking');
        if (this.halfDuplex) this.rt.detachMic();
        break;
      case 'output_audio_buffer.stopped':
      case 'output_audio_buffer.cleared':
        this.assistantSpeaking = false; this.ui.audioStopped();
        if (this.halfDuplex) setTimeout(() => this._restoreMic(), 250);
        if (this.sleepAfterPlayback) { setTimeout(() => this.sleep('end_conversation'), 700); break; }
        if (this.awake) { this.setPhase(this.muted ? 'idle' : 'listening'); this.bumpIdle(); }
        break;
      case 'response.done': this._onResponseDone(e.response || {}); break;
      case 'error': log.error('realtime error', { code: e.error && e.error.code, message: e.error && e.error.message }); this._onApiError(e.error || {}); break;
      default: break;
    }
  }

  _onApiError(err) {
    const code = err.code || '';
    if (code === 'session_expired' || code === 'max_duration_reached' || /expired/i.test(err.message || '')) {
      log.warn('session expired — reconnecting'); this.rt.close(); if (this.awake) this.wake('reconnect'); else this.warm();
    }
  }

  async _onResponseDone(resp) {
    this.responding = false; this.turns++;
    if (resp.status === 'failed') log.error('response failed', resp.status_details);
    const calls = (resp.output || []).filter((it) => it.type === 'function_call');
    if (calls.length) {
      let need = false; const outs = [];
      for (const c of calls) {
        const r = await this.tools.run(c.name, safeJSON(c.arguments));
        outs.push({ call_id: c.call_id, output: JSON.stringify(r.result) }); need = need || r.respond;
      }
      for (const o of outs) this.rt.send({ type: 'conversation.item.create', item: { type: 'function_call_output', call_id: o.call_id, output: o.output } });
      if (need) { this.responding = true; this.rt.send({ type: 'response.create' }); }
    }
    if (!this.assistantSpeaking && !this.responding && this.awake && this.phase === 'thinking') { this.setPhase(this.muted ? 'idle' : 'listening'); this.bumpIdle(); }
  }

  // ── timers ─────────────────────────────────────────────────────────────────────────────────
  onTimersChanged() { if (!this.awake && this.phase === 'sleep' && this.timers.active) this.setPhase('idle'); if (!this.awake && this.phase === 'idle' && !this.timers.active) this.setPhase('sleep'); }
  async onTimerFired(t) {
    log.info('timer fired', { label: t.label });
    this.audio.chime('timer'); this.ui.card((t.label || 'TIME').toUpperCase(), 12); this.ui.toast('TIMER DONE', 4000);
    this.head.gesture('perk_up', 0.8);
    if (!this.awake) await this.wake('timer'); else this.bumpIdle();
    const say = () => { if (this.rt.ready) { this.rt.send({ type: 'conversation.item.create', item: { type: 'message', role: 'system', content: [{ type: 'input_text', text: `[Event] The ${t.label ? '"' + t.label + '" ' : ''}timer the user set has just finished. Tell them in a few friendly words.` }] } }); this.rt.send({ type: 'response.create' }); } };
    setTimeout(say, 700);
    this.onTimersChanged();
  }

  // ── per-frame ──────────────────────────────────────────────────────────────────────────────
  tick(dt, level) {
    // safety net: if playback ended without an explicit stopped event
    if (this.assistantSpeaking && !this.responding) {
      this._quietFor = level.outLevel < 0.03 ? this._quietFor + dt : 0;
      if (this._quietFor > 1.2) { log.warn('speech end inferred from silence'); this.onEvent({ type: 'output_audio_buffer.stopped' }); }
    }
  }
}
