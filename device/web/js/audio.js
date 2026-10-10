/* PERI · audio — microphone capture, level/spectrum analysers for the Scope, and a WebAudio synth
   for the device's sounds (wake / sleep / error / timer). No audio files: every sound is synthesised. */
import { log } from './log.js';

const clamp = (x, a, b) => Math.min(b, Math.max(a, x));

export class AudioIO {
  constructor() {
    this.ctx = null; this.mic = null; this.micSrc = null; this.outSrc = null;
    this.inAn = null; this.outAn = null;
    this.inTD = new Float32Array(1024); this.outTD = new Float32Array(1024);
    this.inFD = new Uint8Array(256); this.outFD = new Uint8Array(256);
    this.inLevel = 0; this.outLevel = 0; this.soundsOn = true; this.master = null;
    this._resumeOnGesture();
  }

  ensureContext() {
    if (this.ctx) return this.ctx;
    const AC = window.AudioContext || window.webkitAudioContext;
    this.ctx = new AC({ latencyHint: 'interactive' });
    this.master = this.ctx.createGain(); this.master.gain.value = 0.9; this.master.connect(this.ctx.destination);
    this.inAn = this.ctx.createAnalyser(); this.inAn.fftSize = 1024; this.inAn.smoothingTimeConstant = 0.55;
    this.outAn = this.ctx.createAnalyser(); this.outAn.fftSize = 1024; this.outAn.smoothingTimeConstant = 0.55;
    return this.ctx;
  }
  _resumeOnGesture() {
    const go = () => { try { this.ensureContext(); if (this.ctx.state !== 'running') this.ctx.resume(); } catch (_) {} };
    for (const ev of ['pointerdown', 'keydown', 'touchstart']) window.addEventListener(ev, go, { passive: true });
  }

  /** Open the microphone. Echo cancellation + noise suppression run inside Chromium's WebRTC pipeline. */
  async openMic(constraints) {
    if (this.mic && this.mic.getAudioTracks().some((t) => t.readyState === 'live')) return this.mic;
    const c = Object.assign({ echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 }, constraints || {});
    const stream = await navigator.mediaDevices.getUserMedia({ audio: c, video: false });
    this.mic = stream;
    this.ensureContext();
    try {
      if (this.micSrc) this.micSrc.disconnect();
      this.micSrc = this.ctx.createMediaStreamSource(stream);
      this.micSrc.connect(this.inAn);
    } catch (e) { log.warn('mic analyser: ' + e.message); }
    const t = stream.getAudioTracks()[0];
    log.info('mic open', { label: t && t.label, settings: t && t.getSettings && t.getSettings() });
    return stream;
  }
  closeMic() {
    if (this.mic) { for (const t of this.mic.getTracks()) t.stop(); this.mic = null; }
    if (this.micSrc) { try { this.micSrc.disconnect(); } catch (_) {} this.micSrc = null; }
    this.inLevel = 0;
  }
  setMicEnabled(on) { if (this.mic) for (const t of this.mic.getAudioTracks()) t.enabled = !!on; }

  /** Attach the assistant's remote audio stream to the analyser (playback itself is done by an <audio> element). */
  attachOutput(stream) {
    this.ensureContext();
    try {
      if (this.outSrc) this.outSrc.disconnect();
      this.outSrc = this.ctx.createMediaStreamSource(stream);
      this.outSrc.connect(this.outAn);          // analyser only — never to destination (would double-play)
    } catch (e) { log.warn('output analyser: ' + e.message); }
  }

  /** Fill analysis buffers; returns the object the Scope consumes. Call once per frame. */
  sample(wantIn = true, wantOut = true) {
    let inLevel = 0, outLevel = 0;
    if (this.ctx && this.ctx.state === 'running') {
      if (wantIn && this.mic) { this.inAn.getFloatTimeDomainData(this.inTD); this.inAn.getByteFrequencyData(this.inFD); inLevel = rms(this.inTD); }
      else { this.inTD.fill(0); this.inFD.fill(0); }
      if (wantOut && this.outSrc) { this.outAn.getFloatTimeDomainData(this.outTD); this.outAn.getByteFrequencyData(this.outFD); outLevel = rms(this.outTD); }
      else { this.outTD.fill(0); this.outFD.fill(0); }
    }
    // map rms to a perceptual 0..1 (speech rms ≈ 0.02–0.15)
    this.inLevel = clamp(Math.pow(inLevel * 7, 0.7), 0, 1);
    this.outLevel = clamp(Math.pow(outLevel * 6, 0.7), 0, 1);
    return { inWave: this.inTD, outWave: this.outTD, inSpec: this.inFD, outSpec: this.outFD, inLevel: this.inLevel, outLevel: this.outLevel };
  }

  // ── sound design ─────────────────────────────────────────────────────────────────────────
  /** Soft bell: sine + octave partial with fast attack and exponential decay. */
  _bell(freq, t0, dur = 0.9, gain = 0.16, partials = [[1, 1], [2.01, 0.28], [3.98, 0.08]]) {
    const ctx = this.ctx;
    const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, t0); g.gain.exponentialRampToValueAtTime(gain, t0 + 0.012); g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    g.connect(this.master);
    for (const [m, a] of partials) {
      const o = ctx.createOscillator(); o.type = 'sine'; o.frequency.value = freq * m;
      const pg = ctx.createGain(); pg.gain.value = a; o.connect(pg); pg.connect(g); o.start(t0); o.stop(t0 + dur + 0.05);
    }
  }
  chime(name) {
    if (!this.soundsOn) return;
    try {
      this.ensureContext(); if (this.ctx.state !== 'running') return;
      const t = this.ctx.currentTime + 0.02;
      const D5 = 587.33, A5 = 880, E5 = 659.25, B4 = 493.88, F5s = 739.99, D6 = 1174.66, G4 = 392, A4 = 440;
      switch (name) {
        case 'boot':  this._bell(D5, t, 1.6, 0.13); this._bell(A5, t + 0.16, 1.6, 0.11); this._bell(D6, t + 0.34, 2.0, 0.09); break;
        case 'wake':  this._bell(D5, t, 0.7, 0.13); this._bell(A5, t + 0.09, 0.9, 0.12); break;
        case 'sleep': this._bell(A5, t, 0.6, 0.09); this._bell(D5, t + 0.10, 0.9, 0.09); break;
        case 'mute':  this._bell(G4, t, 0.35, 0.10, [[1, 1], [2, 0.1]]); break;
        case 'unmute': this._bell(A4, t, 0.35, 0.10, [[1, 1], [2, 0.1]]); break;
        case 'error': this._bell(B4, t, 0.5, 0.10, [[1, 1], [1.5, 0.2]]); this._bell(G4, t + 0.14, 0.8, 0.10, [[1, 1], [1.5, 0.2]]); break;
        case 'timer': for (let i = 0; i < 4; i++) { this._bell(D6, t + i * 0.55, 0.9, 0.12); this._bell(A5, t + i * 0.55 + 0.16, 0.9, 0.10); } break;
        case 'tick':  this._bell(E5, t, 0.16, 0.06, [[1, 1]]); break;
        case 'ping':  this._bell(F5s, t, 0.4, 0.09); break;
      }
    } catch (e) { log.warn('chime failed: ' + e.message); }
  }
}

function rms(a) { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * a[i]; return Math.sqrt(s / a.length); }
