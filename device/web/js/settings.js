/* PERI · on-device settings — a round, touch-first, scrollable sheet (long-press the display to open). */
import { api } from './api.js';
import { log } from './log.js';

const $ = (id) => document.getElementById(id);
const h = (html) => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; };

export class SettingsUI {
  constructor({ config, getSettings, applySettings, agent, head, ui, audio }) {
    Object.assign(this, { config, getSettings, applySettings, agent, head, ui, audio });
    this.el = $('settings'); this.scroll = $('s-scroll'); this.open = false;
    $('s-close').addEventListener('click', () => this.close());
    this.status = null;
  }
  async show() {
    if (this.open) return;
    this.open = true; this.agent.sleep('settings'); this.ui.hideCard();
    try { this.status = await api.get('/api/system/status'); } catch (_) { this.status = null; }
    this.render(); this.el.classList.add('on'); this.scroll.scrollTop = 0;
  }
  close() { this.open = false; this.el.classList.remove('on'); }

  async set(partial) {
    try { const s = await api.put('/api/settings', partial); this.applySettings(s); }
    catch (e) { log.warn('settings put failed: ' + e.message); this.ui.toast('SAVE FAILED', 2000); }
  }

  seg(options, value, onPick, cls = '') {
    const box = h(`<div class="seg ${cls}"></div>`);
    for (const o of options) {
      const b = h(`<button type="button" class="${o.value === value ? 'on' : ''}">${o.html || o.label}</button>`);
      b.addEventListener('click', () => { onPick(o.value); for (const x of box.children) x.classList.remove('on'); b.classList.add('on'); });
      box.appendChild(b);
    }
    return box;
  }
  slider(min, max, value, onInput, onChange, fmt = (v) => v) {
    const wrap = h(`<div><input type="range" min="${min}" max="${max}" value="${value}"></div>`);
    const r = wrap.firstElementChild;
    const paint = () => r.style.setProperty('--p', ((r.value - min) / (max - min)) * 100 + '%');
    paint();
    r.addEventListener('input', () => { paint(); onInput(+r.value); });
    r.addEventListener('change', () => onChange(+r.value));
    return wrap;
  }
  row(label, control, val) {
    const r = h(`<div class="row"><div class="lab"><span>${label}</span><span class="val">${val == null ? '' : val}</span></div></div>`);
    r.appendChild(control); return r;
  }

  render() {
    const S = this.getSettings(), C = this.config, sc = this.scroll;
    sc.innerHTML = '<div class="s-title">SETTINGS</div>';

    // volume
    let volVal;
    const vol = this.slider(0, 100, S.audio.volume, (v) => { volVal.textContent = v; }, async (v) => { try { await api.put('/api/system/volume', { level: v }); S.audio.volume = v; this.audio.chime('ping'); } catch (e) { this.ui.toast('VOLUME FAILED'); } });
    const rv = this.row('Volume', vol, S.audio.volume); volVal = rv.querySelector('.val'); sc.appendChild(rv);

    // personality
    sc.appendChild(this.row('Personality', this.seg(C.personas.map((p) => ({ value: p.id, html: `<b>${p.name}</b><small>${p.blurb}</small>` })), S.persona, (id) => {
      const p = C.personas.find((x) => x.id === id); this.set({ persona: id, voice: p.voice, speed: p.speed }); this.agent.markDirty();
    }, 'persona')));

    // voice
    sc.appendChild(this.row('Voice', this.seg(C.voices.map((v) => ({ value: v, label: v })), S.voice, (v) => { this.set({ voice: v }); this.agent.markDirty(); }, 'voice')));

    // captions
    sc.appendChild(this.row('Captions', this.seg([{ value: 'off', label: 'Off' }, { value: 'assistant', label: 'Peri' }, { value: 'both', label: 'Both' }], S.captions, (v) => { this.set({ captions: v }); this.ui.setMode(v); this.agent.markDirty(); })));

    // wake + interrupt
    sc.appendChild(this.row('Wake', this.seg([{ value: 'tap', label: 'Tap to talk' }, { value: 'always', label: 'Always listening' }], S.wake_mode, (v) => this.set({ wake_mode: v }))));
    sc.appendChild(this.row('Talk over Peri', this.seg([{ value: 'voice', label: 'By voice' }, { value: 'tap', label: 'Tap only' }], S.barge_in, (v) => { this.set({ barge_in: v }); this.agent.markDirty(); })));
    sc.appendChild(this.row('Sleep after', this.seg([{ value: 30, label: '30s' }, { value: 90, label: '90s' }, { value: 300, label: '5m' }, { value: 900, label: '15m' }], S.idle_sleep_s, (v) => this.set({ idle_sleep_s: v }))));

    // head
    if (C.head && C.head.driver !== 'none') {
      sc.appendChild(this.row('Head movement', this.seg([{ value: true, label: 'On' }, { value: false, label: 'Off' }], S.head.enabled, (v) => this.set({ head: { enabled: v } }))));
      let rl;
      const rng = this.slider(5, 25, S.head.limit_deg, (v) => { rl.textContent = v + '°'; }, (v) => this.set({ head: { limit_deg: v } }));
      const rr = this.row('Range', rng, S.head.limit_deg + '°'); rl = rr.querySelector('.val'); sc.appendChild(rr);
      const nud = h('<div class="seg"></div>');
      for (const [lab, d] of [['◀ 5°', -5], ['◀ 1°', -1], ['1° ▶', 1], ['5° ▶', 5]]) { const b = h(`<button class="btn" type="button">${lab}</button>`); b.addEventListener('click', () => api.post('/api/head/nudge', { delta_deg: d }).catch(() => {})); nud.appendChild(b); }
      const z = h('<button class="btn" type="button">Set as centre</button>'); z.addEventListener('click', () => { api.post('/api/head/zero').then(() => this.ui.toast('CENTRE SET')).catch(() => {}); }); nud.appendChild(z);
      sc.appendChild(this.row('Calibrate centre', nud));
    }

    // display
    let bv;
    const br = this.slider(5, 100, S.display.brightness, (v) => { bv.textContent = v; }, async (v) => { try { await api.put('/api/system/brightness', { level: v }); S.display.brightness = v; } catch (_) {} });
    const rb = this.row('Brightness', br, S.display.brightness); bv = rb.querySelector('.val'); sc.appendChild(rb);
    sc.appendChild(this.row('Rotate display', this.seg([0, 90, 180, 270].map((d) => ({ value: d, label: d + '°' })), S.display.rotation, (v) => { this.set({ display: { rotation: v } }); })));
    sc.appendChild(this.row('Sounds', this.seg([{ value: true, label: 'On' }, { value: false, label: 'Off' }], S.sounds, (v) => { this.set({ sounds: v }); this.audio.soundsOn = v; })));

    // system
    const st = this.status || {};
    const kv = h('<div class="kv"></div>');
    const add = (k, v) => { kv.appendChild(h(`<b>${k}</b>`)); kv.appendChild(h(`<span>${v ?? '—'}</span>`)); };
    add('Version', (st.version || C.version)); add('Model', S.model); add('Network', st.net ? (st.net.online ? (st.net.ssid || 'online') : 'offline') : '—'); add('IP', st.net && st.net.ip);
    add('OpenAI', st.openai ? (st.openai.configured ? (st.openai.reachable === false ? 'unreachable' : 'ready') : 'no key') : '—');
    add('Temp', st.cpu_temp_c != null ? st.cpu_temp_c + ' °C' : '—'); add('Head', C.head ? C.head.driver : '—');
    sc.appendChild(this.row('System', kv));
    if (C.capabilities && C.capabilities.power) {
      const p = h('<div class="seg"></div>');
      for (const [lab, act, cls] of [['Restart UI', 'restart-ui', ''], ['Reboot', 'reboot', 'danger'], ['Shut down', 'shutdown', 'danger']]) {
        const b = h(`<button class="btn ${cls}" type="button">${lab}</button>`);
        b.addEventListener('click', () => { if (b.dataset.arm) api.post('/api/system/power', { action: act }).catch(() => {}); else { b.dataset.arm = 1; b.textContent = 'Tap again'; setTimeout(() => { delete b.dataset.arm; b.textContent = lab; }, 3000); } });
        p.appendChild(b);
      }
      sc.appendChild(this.row('Power', p));
    }
  }
}
