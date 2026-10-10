/* PERI · UI overlay helpers — captions (paced to speech), text cards, toasts. DOM-based for typographic quality. */
const $ = (id) => document.getElementById(id);

export class UI {
  constructor({ scope }) {
    this.scope = scope;
    this.root = $('device');
    this.elCapA = $('cap-assistant'); this.elCapU = $('cap-user'); this.elCaps = $('captions');
    this.elCard = $('card'); this.elCardText = $('card-text'); this.elToast = $('toast'); this.elTimer = $('timer-label');
    this.mode = 'assistant';
    this._buf = ''; this._shown = 0; this._speaking = false; this._fadeA = 0; this._fadeU = 0; this._card = 0; this._toast = 0;
    this.wordsPerSec = 3.1;
  }
  setMode(m) { this.mode = m; if (m === 'off') this.clearCaptions(); }

  // ── captions ──────────────────────────────────────────────────────────────────────────────
  setUser(text) {
    if (this.mode !== 'both' || !text) return;
    this.elCapU.textContent = text.trim(); this.elCapU.classList.add('on'); this._raise();
    clearTimeout(this._fadeU); this._fadeU = setTimeout(() => this.elCapU.classList.remove('on'), 4200);
  }
  startAssistant() { this._buf = ''; this._shown = 0; this.elCapA.textContent = ''; clearTimeout(this._fadeA); }
  appendAssistant(delta) { if (this.mode === 'off') return; this._buf += delta; this._speaking = true; this.elCapA.classList.add('on'); this._raise(); clearTimeout(this._fadeA); }
  audioStarted() { this._speaking = true; }
  audioStopped() {
    this._speaking = false; this._shown = this._words().length; this._render();   // reveal everything that was said
    clearTimeout(this._fadeA); this._fadeA = setTimeout(() => { this.elCapA.classList.remove('on'); this._lower(); }, 3400);
  }
  clearCaptions() { this._buf = ''; this._shown = 0; this.elCapA.textContent = ''; this.elCapU.textContent = ''; this.elCapA.classList.remove('on'); this.elCapU.classList.remove('on'); this._lower(); }
  _raise() { this.elCaps.classList.add('raised'); this.root.classList.add('has-captions'); }
  _lower() { if (!this.elCapA.classList.contains('on') && !this.elCapU.classList.contains('on')) { this.elCaps.classList.remove('raised'); this.root.classList.remove('has-captions'); } }
  _words() { return this._buf.split(/\s+/).filter(Boolean); }
  _render() {
    const w = this._words(), n = Math.min(this._shown, w.length);
    const last = w.slice(Math.max(0, n - 22), n);
    this.elCapA.textContent = last.join(' ');
  }
  tick(dt) {
    if (this.mode === 'off') return;
    const w = this._words();
    if (this._shown < w.length) {
      this._acc = (this._acc || 0) + dt * (this._speaking ? this.wordsPerSec : 12);
      const add = Math.floor(this._acc); if (add > 0) { this._acc -= add; this._shown = Math.min(w.length, this._shown + add); this._render(); }
    }
  }

  // ── card / toast / timer label ─────────────────────────────────────────────────────────────
  card(text, seconds = 6, mono = false) {
    const t = String(text || '').slice(0, 40);
    this.elCardText.textContent = t;
    this.elCardText.classList.toggle('mono', mono);
    // auto-fit: shrink until it fits in ~470 px wide, max 3 lines
    let size = t.length <= 4 ? 190 : t.length <= 8 ? 128 : t.length <= 14 ? 84 : 58;
    this.elCardText.style.fontSize = size + 'px';
    this.elCard.classList.add('on'); this.root.classList.add('has-card');
    clearTimeout(this._card); this._card = setTimeout(() => this.hideCard(), Math.max(2, Math.min(60, seconds)) * 1000);
  }
  hideCard() { this.elCard.classList.remove('on'); this.root.classList.remove('has-card'); }
  toast(text, ms = 1600) {
    this.elToast.textContent = text; this.elToast.classList.add('on');
    clearTimeout(this._toast); this._toast = setTimeout(() => this.elToast.classList.remove('on'), ms);
  }
  timerLabel(text) { this.elTimer.textContent = text || ''; this.elTimer.classList.toggle('on', !!text); }
}
