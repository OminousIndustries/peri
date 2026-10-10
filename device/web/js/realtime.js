/* PERI · Realtime transport — OpenAI Realtime over WebRTC via the local server ("unified interface").
   The browser never sees the API key: it posts its SDP offer to /api/realtime/session and the server
   attaches the key + the full session configuration.

   Keep-warm design: the peer connection is created with a send-capable audio transceiver but NO track, so nothing is
   streamed (and nothing is billed) until the device wakes. Waking = replaceTrack(mic) — instant, no handshake. */
import { api } from './api.js';
import { log } from './log.js';

export class Realtime {
  constructor({ audio, onEvent, onStatus }) {
    this.audio = audio; this.onEvent = onEvent || (() => {}); this.onStatus = onStatus || (() => {});
    this.pc = null; this.dc = null; this.sender = null; this.status = 'closed'; this.callId = null;
    this.startedAt = 0; this.lastEventAt = 0; this._connecting = null; this.sessionInfo = null;
    this.audioEl = document.createElement('audio');
    this.audioEl.autoplay = true; this.audioEl.playsInline = true; this.audioEl.id = 'peri-out';
    this.audioEl.style.display = 'none'; document.body.appendChild(this.audioEl);
  }

  get ready() { return this.status === 'ready' && this.dc && this.dc.readyState === 'open' && this.pc && ['connected', 'completed'].includes(this.pc.connectionState === 'connected' ? 'connected' : this.pc.iceConnectionState); }
  get age() { return this.startedAt ? (Date.now() - this.startedAt) / 1000 : 0; }
  _set(s, info) { if (this.status !== s) { this.status = s; log.info('realtime ' + s, info); this.onStatus(s, info); } }

  async connect(overrides = {}) {
    if (this._connecting) return this._connecting;
    this._connecting = this._connect(overrides).finally(() => { this._connecting = null; });
    return this._connecting;
  }

  async _connect(overrides) {
    this.close(true);
    this._set('connecting');
    const t0 = performance.now();
    const pc = this.pc = new RTCPeerConnection();
    pc.ontrack = (e) => {
      this.audioEl.srcObject = e.streams[0];
      this.audio.attachOutput(e.streams[0]);
      const p = this.audioEl.play(); if (p && p.catch) p.catch((err) => log.warn('audio play blocked: ' + err.message));
    };
    // send-capable audio m-line without a track: nothing is transmitted until attachMic()
    const tx = pc.addTransceiver('audio', { direction: 'sendrecv' });
    this.sender = tx.sender;
    const dc = this.dc = pc.createDataChannel('oai-events');
    const opened = new Promise((res, rej) => { dc.onopen = res; setTimeout(() => rej(new Error('data channel timeout')), 15000); });
    const created = new Promise((res) => { this._onCreated = res; });
    dc.onmessage = (m) => {
      let e; try { e = JSON.parse(m.data); } catch (_) { return; }
      this.lastEventAt = Date.now();
      if (e.type === 'session.created' && this._onCreated) { this._onCreated(e); this._onCreated = null; }
      try { this.onEvent(e); } catch (err) { log.error('event handler ' + e.type + ': ' + (err && err.message)); }
    };
    dc.onclose = () => { if (this.pc === pc && this.status === 'ready') this._set('failed', { why: 'datachannel closed' }); };
    pc.onconnectionstatechange = () => {
      const s = pc.connectionState; log.debug('pc ' + s);
      if (this.pc !== pc) return;
      if (s === 'failed' || s === 'closed') this._set('failed', { why: 'pc ' + s });
      if (s === 'disconnected') setTimeout(() => { if (this.pc === pc && pc.connectionState === 'disconnected') this._set('failed', { why: 'pc disconnected' }); }, 6000);
    };
    const superseded = () => { if (this.pc !== pc) { const e = new Error('superseded'); e.superseded = true; throw e; } };
    const offer = await pc.createOffer();
    superseded();
    await pc.setLocalDescription(offer);
    superseded();
    let resp;
    try { resp = await api.post('/api/realtime/session', { sdp: offer.sdp, overrides }); }
    catch (e) { if (!e.superseded) this._set('failed', { why: e.message, code: e.code }); throw e; }
    superseded();
    this.callId = resp.call_id || null; this.sessionInfo = resp.session || null;
    await pc.setRemoteDescription({ type: 'answer', sdp: resp.sdp });
    superseded();
    await opened;
    superseded();
    await Promise.race([created, new Promise((r) => setTimeout(r, 6000))]);
    this.startedAt = Date.now();
    this._set('ready', { ms: Math.round(performance.now() - t0), callId: this.callId });
    return true;
  }

  async attachMic(stream) {
    if (!this.sender) return false;
    const track = stream.getAudioTracks()[0];
    if (!track) return false;
    await this.sender.replaceTrack(track);
    return true;
  }
  async detachMic() { if (this.sender) { try { await this.sender.replaceTrack(null); } catch (_) {} } }

  send(evt) {
    if (!this.dc || this.dc.readyState !== 'open') { log.warn('send dropped (channel not open): ' + evt.type); return false; }
    this.dc.send(JSON.stringify(evt)); return true;
  }

  updateSession(partial) { return this.send({ type: 'session.update', session: Object.assign({ type: 'realtime' }, partial) }); }

  close(quiet) {
    const pc = this.pc; this.pc = null;
    if (this.dc) { try { this.dc.onclose = null; this.dc.close(); } catch (_) {} this.dc = null; }
    if (pc) { try { pc.onconnectionstatechange = null; pc.close(); } catch (_) {} }
    this.sender = null; this.startedAt = 0; this.callId = null;
    if (!quiet) this._set('closed');
  }
}
