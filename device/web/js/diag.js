/* PERI · /diag — full-page diagnostics for whoever is setting the device up (human or agent).
   Open http://127.0.0.1:8420/diag (or via SSH tunnel). Shows server checks, live mic meter, speaker test,
   head controls and a Realtime connection test. */
import { api } from './api.js';
import { log } from './log.js';
import { AudioIO } from './audio.js';
import { Realtime } from './realtime.js';
import { Scope } from './scope.js';

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

export async function mountDiag() {
  document.getElementById('viewport').hidden = true;
  const root = document.getElementById('diag'); root.hidden = false; document.body.classList.add('dev');
  root.innerHTML = `
    <h1>peri · diagnostics</h1>
    <div id="dg-over" style="color:var(--text-mid);font:400 15px var(--font-text)">running checks…</div>
    <h2>Server checks</h2><div class="card"><table id="dg-checks"></table></div>
    <div class="grid">
      <div><h2>Microphone</h2><div class="card"><div class="meter"><i id="dg-mic"></i></div><p id="dg-mic-info" style="margin:10px 0;color:var(--text-mid);font:13px var(--font-mono)">not started</p><button class="btn" id="dg-mic-btn">Start mic test</button><button class="btn" id="dg-tone">Play test tone</button><button class="btn" id="dg-chime">Play wake chime</button></div></div>
      <div><h2>Head</h2><div class="card"><p id="dg-head" style="font:13px var(--font-mono);color:var(--text-mid);margin-bottom:10px">…</p>
        ${[-5, -1, 1, 5].map((d) => `<button class="btn" data-n="${d}">${d > 0 ? '+' : ''}${d}°</button>`).join('')}
        <button class="btn" data-g="wake">wake</button><button class="btn" data-g="shake_no">shake</button><button class="btn" data-g="look_around">look around</button><button class="btn" data-g="settle">centre</button><button class="btn" data-z="1">set zero</button><button class="btn" data-r="1">release</button></div></div>
      <div><h2>Realtime</h2><div class="card"><p id="dg-rt" style="font:13px var(--font-mono);color:var(--text-mid);margin-bottom:10px">not tested</p><button class="btn" id="dg-rt-btn">Connect test</button></div></div>
      <div><h2>Scope</h2><div class="card"><div class="scope-mini" id="dg-scope"></div></div></div>
    </div>
    <h2>System</h2><div class="card"><pre id="dg-sys">…</pre></div>
    <h2>Recent UI log</h2><div class="card"><pre id="dg-log">…</pre></div>`;
  const $ = (q) => root.querySelector(q);

  // server checks
  try {
    const d = await api.get('/api/diag');
    $('#dg-over').innerHTML = `overall: <b class="${d.overall}">${d.overall.toUpperCase()}</b> · ${new Date().toLocaleTimeString()}`;
    $('#dg-checks').innerHTML = d.checks.map((c) => `<tr><td class="${c.status}">${c.status.toUpperCase()}</td><td>${esc(c.id)}</td><td>${esc(c.detail || '')}</td></tr>`).join('');
  } catch (e) { $('#dg-over').innerHTML = `<b class="fail">server unreachable</b> — ${esc(e.message)}`; }
  try { $('#dg-sys').textContent = JSON.stringify(await api.get('/api/system/status'), null, 2); } catch (e) { $('#dg-sys').textContent = e.message; }
  const refreshLog = () => { $('#dg-log').textContent = log.recent().map((l) => `${new Date(l.t).toLocaleTimeString()} ${l.level.padEnd(5)} ${l.msg}`).join('\n'); };
  refreshLog(); setInterval(refreshLog, 2000);

  // scope preview
  const scope = new Scope($('#dg-scope'), { size: 720, fps: 30, quality: 'medium', clock: false }); scope.setState('idle'); scope.start();

  // mic + tone
  const audio = new AudioIO(); let micOn = false;
  $('#dg-mic-btn').onclick = async () => {
    if (micOn) return; micOn = true;
    try {
      await audio.openMic();
      const t = audio.mic.getAudioTracks()[0];
      $('#dg-mic-info').textContent = `${t.label} · ${JSON.stringify(t.getSettings())}`;
      const loop = () => { const s = audio.sample(true, false); $('#dg-mic').style.width = Math.round(s.inLevel * 100) + '%'; scope.setAudio(s); requestAnimationFrame(loop); }; loop();
      scope.setState('listening');
    } catch (e) { $('#dg-mic-info').innerHTML = `<span class="fail">${esc(e.name + ': ' + e.message)}</span>`; micOn = false; }
  };
  $('#dg-tone').onclick = () => { audio.ensureContext(); audio.ctx.resume(); const o = audio.ctx.createOscillator(), g = audio.ctx.createGain(); o.frequency.value = 440; g.gain.value = 0.15; o.connect(g); g.connect(audio.ctx.destination); o.start(); o.stop(audio.ctx.currentTime + 1.2); };
  $('#dg-chime').onclick = () => { audio.soundsOn = true; audio.chime('wake'); };

  // head
  const headEl = $('#dg-head');
  const pollHead = async () => { try { const s = await api.get('/api/head'); headEl.textContent = `${s.driver} · angle ${(+s.angle).toFixed(1)}° → ${(+s.target).toFixed(1)}° · ${s.moving ? 'moving' : 'still'} · limits ${s.limits.min}…${s.limits.max}${s.error ? ' · ERROR ' + s.error : ''}`; } catch (e) { headEl.textContent = e.message; } };
  pollHead(); setInterval(pollHead, 1500);
  root.querySelectorAll('[data-n]').forEach((b) => b.onclick = () => api.post('/api/head/nudge', { delta_deg: +b.dataset.n }).catch((e) => alert(e.message)));
  root.querySelectorAll('[data-g]').forEach((b) => b.onclick = () => api.post('/api/head/gesture', { name: b.dataset.g, intensity: 1 }).catch((e) => alert(e.message)));
  root.querySelector('[data-z]').onclick = () => api.post('/api/head/zero').catch((e) => alert(e.message));
  root.querySelector('[data-r]').onclick = () => api.post('/api/head/release').catch((e) => alert(e.message));

  // realtime connect test
  $('#dg-rt-btn').onclick = async () => {
    const out = $('#dg-rt'); out.textContent = 'connecting…';
    const rt = new Realtime({ audio, onEvent: (e) => { if (e.type === 'session.created') out.textContent += `\nsession.created (${e.session && e.session.model})`; } });
    const t0 = performance.now();
    try { await rt.connect(); out.textContent = `OK — ready in ${Math.round(performance.now() - t0)} ms · call ${rt.callId || 'n/a'}` + '\n' + out.textContent.split('\n').slice(1).join('\n'); setTimeout(() => rt.close(), 1500); }
    catch (e) { out.innerHTML = `<span class="fail">${esc(e.message)}</span>`; }
  };
}
