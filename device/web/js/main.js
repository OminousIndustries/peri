/* PERI · kiosk bootstrap — wires the Scope, audio, realtime session, head and settings together. */
import { log } from './log.js';
import { api, Socket } from './api.js';
import { Scope } from './scope.js';
import { AudioIO } from './audio.js';
import { Realtime } from './realtime.js';
import { Head } from './head.js';
import { UI } from './ui.js';
import { Timers, makeTools } from './tools.js';
import { Agent } from './agent.js';
import { SettingsUI } from './settings.js';

const q = new URLSearchParams(location.search);
const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const deepMerge = (a, b) => { for (const k of Object.keys(b)) { if (b[k] && typeof b[k] === 'object' && !Array.isArray(b[k])) { a[k] = a[k] || {}; deepMerge(a[k], b[k]); } else a[k] = b[k]; } return a; };

async function main() {
  if (location.pathname.replace(/\/$/, '') === '/diag') {
    await Promise.race([document.fonts.ready, sleep(1500)]);
    const { mountDiag } = await import('./diag.js'); return mountDiag();
  }
  const kiosk = q.has('kiosk') || (innerWidth === innerHeight && innerWidth <= 800);
  document.body.classList.toggle('dev', !kiosk);
  const fitEl = $('fit'); let rotation = +(q.get('rotate') || 0);
  const fit = () => { const s = Math.min(innerWidth, innerHeight) / 720 * (kiosk ? 1 : 0.88); fitEl.style.transform = `scale(${s}) rotate(${rotation}deg)`; };
  fit(); addEventListener('resize', fit);
  const notice = (title, body = '', hint = '') => { $('notice-title').textContent = title; $('notice-body').textContent = body; $('notice-hint').textContent = hint; $('notice').hidden = false; };
  const hideNotice = () => { $('notice').hidden = true; };

  await Promise.race([Promise.all([document.fonts.load('13px "Martian Mono"'), document.fonts.load('300 40px "Unbounded"'), document.fonts.load('500 20px "Instrument Sans"')]), sleep(2000)]);

  const isArm = /aarch64|armv|arm64/i.test(navigator.userAgent + ' ' + (navigator.platform || ''));
  const scope = new Scope($('scope'), { size: 720, fps: +(q.get('fps') || (isArm ? 30 : 60)), quality: q.get('quality') || 'auto' });
  scope.setState('boot'); scope.start();
  const audio = new AudioIO();
  setTimeout(() => audio.chime('boot'), 250);

  // config (wait for the server, showing a friendly notice)
  let config = null, tries = 0;
  while (!config) {
    try { config = await api.get('/api/config'); }
    catch (e) { if (tries++ === 2) notice('Starting up', 'Waiting for the Peri server…', 'journalctl -u peri-server'); await sleep(1200); }
  }
  hideNotice();
  const settings = config.settings;
  rotation = q.has('rotate') ? rotation : settings.display.rotation; fit();
  log.info('boot', { version: config.version, hardware: config.hardware, head: config.head, model: settings.model });
  audio.soundsOn = settings.sounds;
  scope.hintFn = () => (settings.wake_mode === 'tap' ? 'TAP TO WAKE' : '');

  const socket = new Socket();
  const timers = new Timers({ onFire: (t) => agent.onTimerFired(t) });
  const ui = new UI({ scope }); ui.setMode(settings.captions);
  const head = new Head({ socket, getSettings: () => settings, scope, config });
  const agent = new Agent({ audio, scope, ui, head, getSettings: () => settings, timers });
  const rt = new Realtime({ audio, onEvent: (e) => agent.onEvent(e), onStatus: (s, i) => agent.onRtStatus(s, i) });
  const tools = makeTools({ agent, scope, ui, head, getSettings: () => settings, timers });
  agent.bind(rt, tools);
  const settingsUI = new SettingsUI({ config, getSettings: () => settings, applySettings, agent, head, ui, audio });

  function applySettings(s) {
    const prev = JSON.parse(JSON.stringify(settings));
    deepMerge(settings, s);
    if (settings.display.rotation !== prev.display.rotation && !q.has('rotate')) { rotation = settings.display.rotation; fit(); }
    ui.setMode(settings.captions); audio.soundsOn = settings.sounds;
    if (settings.wake_mode === 'always' && prev.wake_mode !== 'always') agent.wake('always');
  }
  socket.on('settings.changed', (m) => applySettings(m.settings));
  socket.on('ui.command', (m) => {
    log.info('ui.command', m);
    ({ wake: () => agent.wake('command'), sleep: () => agent.sleep('command'), mute: () => agent.toggleMute(true), unmute: () => agent.toggleMute(false), reload: () => location.reload(), show_diag: () => { location.href = '/diag'; } }[m.cmd] || (() => {}))();
  });

  // per-frame glue (runs inside the scope loop, before each draw)
  const clockDim = () => (agent.phase === 'sleep' && Date.now() - (agent._sleptAt || Date.now()) > 180000) ? 0.35 : 1;
  scope.demo = (sc, dt) => {
    const lv = audio.sample(agent.awake && !agent.muted, true);
    sc.setAudio(lv);
    head.tick(dt); ui.tick(dt); agent.tick(dt, lv);
    const t = timers.soonest();
    if (t) { sc.setTimer(Math.max(0, (t.endsAt - Date.now()) / t.total)); ui.timerLabel(timers.fmt(t.endsAt - Date.now())); } else { sc.setTimer(null); ui.timerLabel(''); }
    sc.setDim(clockDim());
    sc.labelHidden = ui.elCaps.classList.contains('raised') || document.getElementById('device').classList.contains('has-card');
  };

  // input: tap / double-tap / long-press → settings
  const dev = $('device'); let lp = 0, sx = 0, sy = 0, lpFired = false, lastTap = 0;
  dev.addEventListener('pointerdown', (e) => {
    if (settingsUI.open) return;
    sx = e.clientX; sy = e.clientY; lpFired = false; clearTimeout(lp);
    lp = setTimeout(() => { lpFired = true; settingsUI.show(); }, 1000);
  });
  dev.addEventListener('pointermove', (e) => { if (lp && Math.hypot(e.clientX - sx, e.clientY - sy) > 14) { clearTimeout(lp); lp = 0; } });
  for (const ev of ['pointercancel', 'pointerleave']) dev.addEventListener(ev, () => { clearTimeout(lp); lp = 0; });
  dev.addEventListener('pointerup', () => {
    clearTimeout(lp); lp = 0;
    if (lpFired || settingsUI.open) return;
    const now = performance.now();
    if (now - lastTap < 320) { agent.doubleTap(); lastTap = 0; } else { agent.tap(); lastTap = now; }
  });
  addEventListener('keydown', (e) => {
    if (e.repeat || e.target.tagName === 'INPUT') return;
    if (e.code === 'Space') { e.preventDefault(); if (settingsUI.open) return; agent.tap(); }
    else if (e.key === 'Escape') { settingsUI.open ? settingsUI.close() : agent.sleep('key'); }
    else if (e.key === 'm') agent.toggleMute();
    else if (e.key === 's') settingsUI.open ? settingsUI.close() : settingsUI.show();
    else if (e.key === 'd') location.href = '/diag';
  });
  document.addEventListener('visibilitychange', () => { document.hidden ? scope.stop() : scope.start(); });

  window.__peri = { scope, agent, rt, settings, head, ui, audio, timers, config, socket, settingsUI };

  if (!config.openai.configured) notice('Needs an API key', 'Add your OpenAI key to finish setup.', 'peri-config set OPENAI_API_KEY');
  await sleep(2600);                       // let the boot animation play
  scope.setState('sleep');
  if (!config.openai.configured) setTimeout(() => notice('Needs an API key', 'Add your OpenAI key to finish setup.', 'peri-config set OPENAI_API_KEY'), 400);
  agent.setPhase('sleep');
  await agent.boot();
}

main().catch((e) => { console.error(e); log.error('fatal: ' + (e && e.message)); });
