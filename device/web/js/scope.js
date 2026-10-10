/* ─────────────────────────────────────────────────────────────────────────────
   PERI · The Scope
   A voice-reactive lens for a 720×720 round display: polar oscilloscope ring, pupil,
   tick bezel, sonar echoes, thinking comet, iris-blade wake, ambient clock.

   Self-contained ES module (WebGL2 + a 2D overlay canvas). No dependencies.
   Used by the device kiosk, the website's live demo, and the render/ad capture pipeline.

   const scope = new Scope(containerEl, { size: 720, fps: 30, quality: 'auto' });
   scope.setState('listening');            // sleep | idle | listening | thinking | speaking | connecting | error | boot
   scope.setMood('curious');               // calm | happy | curious | excited | sleepy | concerned
   scope.setAudio({ inWave, outWave, inSpec, outSpec, inLevel, outLevel });  // Float32 -1..1 / Uint8 0..255 / 0..1
   scope.setGaze(x, y);  scope.setHead(deg);  scope.setMuted(true);  scope.setTimer(0.4 | null);
   scope.start();  // or drive manually: scope.step(dt) + scope.draw()
   ───────────────────────────────────────────────────────────────────────────── */

const VERT = `#version 300 es
in vec2 aPos;
void main(){ gl_Position = vec4(aPos, 0.0, 1.0); }`;

const FRAG = `#version 300 es
precision highp float;
precision highp sampler2D;

uniform vec2  uRes;
uniform float uTime;
uniform sampler2D uData;   // 256 x 16 (R8): 0 mic wave · 1 out wave · 2 mic spectrum · 3 out spectrum · 4..11 out history · 12..15 mic history
uniform vec4  uS1;         // sleep, idle, listen, think
uniform vec4  uS2;         // speak, error, connect, muted
uniform vec3  uColA;       // main glow
uniform vec3  uColB;       // secondary glow
uniform vec3  uColC;       // hot core
uniform vec4  uL;          // inLevel, outLevel, open, blink
uniform vec4  uG;          // gaze.x, gaze.y, ringRot (rad), thinkAngle (rad)
uniform vec4  uM;          // timerProgress (<0 none), hour 0..1, minute 0..1, sleepDim
uniform vec4  uP;          // pilot, breath, boot(0..1 mark reveal), pulse
uniform float uDbg;        // debug: bitmask of layers to disable
out vec4 fragColor;

const float PI  = 3.14159265;
const float TAU = 6.28318531;

bool on(int b){ return (int(uDbg + 0.5) & (1 << b)) == 0; }
float hash21(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float rowY(float row){ return (row + 0.5) / 16.0; }
float dataAt(float u, float row){ return texture(uData, vec2(u, rowY(row))).r; }

// signed radial distance to a wavy ring. x = slope-corrected (for the thin core line), y = barely corrected (for glow, so steep
// segments don't smear glow along radial lines)
vec2 wavyRing(float r, float u, float R0, float amp, float row){
  float w0 = dataAt(u, row) * 2.0 - 1.0;
  float w1 = dataAt(u + 1.0/256.0, row) * 2.0 - 1.0;
  float R  = R0 + amp * w0;
  float slope = clamp(amp * (w1 - w0) / (TAU * R0 / 256.0), -2.2, 2.2);
  float dr = r - R;
  return vec2(dr / sqrt(1.0 + slope * slope), dr / sqrt(1.0 + 0.10 * slope * slope));
}
float core(float d, float w){ return exp(-(d*d)/(w*w)); }
float glow(float d, float w){ return exp(-abs(d)/w); }
float hexSdf(vec2 p){ p = abs(p); return max(p.x * 0.8660254 + p.y * 0.5, p.y); }
mat2  rot(float a){ float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

void main(){
  vec2  p = (gl_FragCoord.xy - 0.5 * uRes) / (0.5 * uRes.y);
  float r = length(p);
  float a = atan(p.x, p.y);                // 0 at 12 o'clock, clockwise positive
  float u = fract(a / TAU + 0.5);          // waveform seam sits at 6 o'clock (hidden by the label)

  float sleep = uS1.x, idle = uS1.y, listen = uS1.z, think = uS1.w;
  float speak = uS2.x, err = uS2.y, conn = uS2.z, muted = uS2.w;
  float inL = uL.x, outL = uL.y, open = uL.z, blink = uL.w;
  float awake = 1.0 - sleep;

  vec3 scene = vec3(0.0);

  // eye-blink squash for ring + pupil only
  vec2  pb = vec2(p.x, p.y * (1.0 + 7.0 * blink));
  vec2  gz = uG.xy;
  vec2  pc = pb - gz * 0.020;              // ring centre drifts a little with gaze (parallax)
  float rc = length(pc);
  float ac = atan(pc.x, pc.y);
  float uc = fract(ac / TAU + 0.5);

  // ── ambient bloom of the state colour ────────────────────────────────────────────────
  float amb = 0.006 + 0.014 * idle + 0.024 * listen + 0.022 * think + 0.040 * speak + 0.03 * err + 0.014 * conn;
  amb *= (0.85 + 0.15 * sin(uTime * 0.8));
  if (on(0)) { scene += mix(uColA, uColB, 0.5 + 0.5 * p.y) * amb * exp(-r * r * 4.2);
  scene += uColA * 0.07 * uL.y * speak * exp(-r * r * 8.0); }

  // ── tick bezel (counter-rotates with the head so the compass stays fixed to the base) ─
  if (on(1)) {
    float ur = fract(u + uG.z / TAU);
    float N = 120.0;
    float cell = ur * N;
    float ti = floor(cell);
    float ta = fract(cell) - 0.5;
    float cardinal = step(mod(ti, 10.0), 0.5);
    float pxw = 1.0 / (uRes.y * 0.5);
    float halfw = (0.55 * pxw) / (max(r, 0.1) * (TAU / N));   // ~1 device px wide
    float line = 1.0 - smoothstep(halfw * 0.6, halfw * 1.4, abs(ta));
    float f = abs(a) / PI;                                     // 0 at top → 1 at bottom, mirrored
    float spIn  = dataAt(f * 0.92, 2.0);
    float spOut = dataAt(f * 0.92, 3.0);
    float sp = mix(spIn, spOut, clamp(speak * 1.2, 0.0, 1.0));
    sp *= (listen + speak) * (1.0 - muted);
    float base = 0.905;
    float len  = 0.020 + 0.018 * cardinal + 0.075 * sp;
    float inRad = smoothstep(base - 0.004, base, r) * (1.0 - smoothstep(base + len, base + len + 0.004, r));
    float bright = 0.07 + 0.16 * cardinal + 1.7 * sp;
    bright *= (0.35 + 0.65 * awake);
    vec3 tcol = mix(uColB, uColA, clamp(sp * 1.6, 0.0, 1.0));
    scene += tcol * line * inRad * bright * 0.9;
  }

  // ── iris rings (depth cues) ──────────────────────────────────────────────────────────
  if (on(2)) {
    float br = 1.0 + 0.012 * sin(uTime * 0.7) + 0.02 * outL * speak;
    scene += uColB * 0.045 * awake * core(r - 0.64 * br, 0.004);
    scene += uColB * 0.030 * awake * core(r - 0.80,      0.003) * (0.5 + listen);
  }

  // ── scope ring + sonar echoes ────────────────────────────────────────────────────────
  if (on(3)) {
    float R0  = 0.40 + 0.030 * idle + 0.045 * listen - 0.13 * think + 0.055 * speak + 0.02 * err - 0.02 * muted;
    R0 += 0.012 * sin(uTime * 0.9 + 1.0) * idle;
    R0 += 0.05 * inL * listen + 0.05 * outL * speak;
    float ampIn  = 0.095 * listen * (0.25 + 1.0 * inL);
    float ampOut = 0.105 * speak  * (0.22 + 1.0 * outL);
    // gentle organic wobble when idle so it never looks dead
    float wob = 0.008 * sin(a * 3.0 + uTime * 0.7) + 0.005 * sin(a * 5.0 - uTime * 1.1);
    float wobA = (idle + 0.4 * think + 0.4 * conn + err) * wob;

    vec2 dIn  = wavyRing(rc, uc, R0, ampIn, 0.0);
    vec2 dOut = wavyRing(rc, uc, R0, ampOut, 1.0);
    vec2 d = mix(dIn, dOut, clamp(speak, 0.0, 1.0)) - vec2(wobA);

    float w = 0.0042 + 0.002 * (listen + speak) * (0.4 + inL + outL);
    float c1 = core(d.x, w);
    float g1 = glow(d.y, 0.018) * 0.42 + glow(d.y, 0.055) * 0.16;
    vec3 hue = mix(uColA, uColB, 0.5 + 0.5 * cos(ac - uTime * 0.35));
    vec3 ringCol = hue * g1 + mix(hue, uColC, 0.7) * c1 * 1.4;
    float ringGain = (0.55 + 0.45 * awake) * (1.0 - 0.55 * muted) * (1.0 - 0.92 * uP.z);
    scene += ringCol * ringGain * (idle + listen + speak + err + conn * 0.6 + think * 0.9);

    // echoes: past output frames ripple outward like sonar
    if (on(4)) for (int k = 1; k < 6; k++) {
      float fk = float(k);
      float row = 4.0 + fk * 1.0;
      float Rk = R0 + fk * (0.058 + 0.018 * speak);
      vec2 de = wavyRing(rc, uc, Rk, ampOut * (1.0 - 0.13 * fk), row);
      float al = pow(0.50, fk) * speak * (0.35 + outL);
      scene += mix(uColA, uColB, fk / 6.0) * (core(de.x, 0.0032) * 0.85 + glow(de.y, 0.018) * 0.16) * al;
    }
    // listening: soft inward pulses on the same rings
    if (on(5)) for (int k = 1; k < 4; k++) {
      float fk = float(k);
      float row = 11.0 + fk;
      float Rk = R0 - fk * 0.055;
      vec2 de = wavyRing(rc, uc, Rk, ampIn * (1.0 - 0.2 * fk), row);
      scene += mix(uColA, uColB, 0.5) * (core(de.x, 0.0034) * 0.6 + glow(de.y, 0.02) * 0.14) * listen * pow(0.55, fk) * (0.3 + inL);
    }
  }

  // ── thinking / connecting comet ──────────────────────────────────────────────────────
  if (on(6)) {
    float Rr = 0.70;
    float dr = r - Rr;
    float band = core(dr, 0.0050) + 0.20 * glow(dr, 0.025);
    for (int i = 0; i < 3; i++) {
      float off = float(i) * TAU / 3.0;
      float ang = uG.w + off;
      vec2  hp = vec2(sin(ang), cos(ang)) * Rr;
      float dh = length(p - hp);
      float head = exp(-dh * dh / (0.012 * 0.012)) * 1.5 + exp(-dh / 0.03) * 0.25;
      float da = mod(ang - a, TAU);                       // angular distance behind the head
      float tail = smoothstep(0.0, 0.06, da) * exp(-da * (i == 0 ? 1.5 : 3.2)) * (1.0 - smoothstep(3.0, 4.2, da));
      float k = (i == 0 ? 1.0 : 0.42);
      float on = think + conn * (i == 0 ? 1.0 : 0.0);
      vec3 cc = mix(uColA, uColB, clamp(da * 0.6, 0.0, 1.0));
      scene += (cc * band * tail * 0.6 + mix(uColA, uColC, 0.75) * head) * k * on;
    }
  }

  // ── timer arc ────────────────────────────────────────────────────────────────────────
  if (uM.x >= 0.0) {
    float Rt = 0.868;
    float ang = fract(a / TAU);                          // 0 at top, clockwise
    float remain = clamp(uM.x, 0.0, 1.0);
    float inside = step(ang, remain);
    float dr = r - Rt;
    float line = core(dr, 0.0045) * inside + core(dr, 0.0018) * 0.25;
    float dEnd = length(vec2(dr, (ang - remain) * TAU * Rt)) ;
    scene += uColA * (line * 0.9 + glow(dr, 0.02) * inside * 0.16 + core(dEnd, 0.012) * 1.4);
  }

  // ── pupil ────────────────────────────────────────────────────────────────────────────
  if (on(7)) {
    vec2  pp = pb - gz * 0.055;
    float lvl = max(inL * listen, outL * speak);
    float rp = (0.030 + 0.012 * idle + 0.020 * lvl + 0.010 * uP.w) * (1.0 - 0.35 * think) * (1.0 - 0.5 * muted);
    float d  = length(pp) - rp;
    float body = 1.0 - smoothstep(-0.002, 0.004, d);
    float halo = exp(-max(d, 0.0) * 22.0) * 0.55 + exp(-max(d, 0.0) * 7.0) * 0.22;
    vec3  pcol = mix(uColA, uColC, 0.78);
    float pg = (idle * 0.9 + listen + speak * 1.1 + think * 0.8 + err + conn * 0.7) * (0.55 + 0.45 * awake);
    scene += (pcol * body * 1.55 + uColA * halo) * pg * (1.0 - 0.6 * blink);
  }

  // ── error pulse ring ─────────────────────────────────────────────────────────────────
  if (on(8)) scene += uColA * err * (core(r - 0.54 - 0.03 * sin(uTime * 2.4), 0.008) * 0.5) ;

  // ── iris blades (wake / sleep aperture) ─────────────────────────────────────────────
  if (on(9)) {
    float o = clamp(open, 0.0, 1.2);
    float rad = mix(0.0, 1.32, o);
    float hd = hexSdf(rot(uTime * 0.05 + 0.6) * p);
    float edge = 1.0 - smoothstep(rad - 0.012, rad, hd);
    // blade seams (thin dark lines from the hex corners inward) sell the diaphragm look
    float ang6 = mod(atan(p.y, p.x) + uTime * 0.05 + 0.6, PI / 3.0) - PI / 6.0;
    float seam = smoothstep(0.0, 0.012, abs(sin(ang6 * 3.0)) - 0.0) ;
    float rim = exp(-abs(hd - rad) * 60.0) * step(0.01, o) * step(o, 1.02) * 0.5;
    scene = scene * edge + uColC * rim * (0.35 + 0.65 * (1.0 - awake)) ;
  }

  // ── boot mark reveal (drawn by the overlay; here only a soft core glow behind it) ─────
  scene += uColA * 0.16 * uP.z * exp(-r * r * 9.0);

  // ── sleep: ambient clock + pilot (unmasked by the iris) ──────────────────────────────
  {
    float dim = uM.w;
    float sl = sleep * dim;
    // 60 minute ticks, 12 hour ticks
    float N = 60.0;
    float cell = fract(a / TAU) * N;
    float ta = fract(cell) - 0.5;
    float ti = floor(cell);
    float hour = step(mod(ti, 5.0), 0.5);
    float halfw = (0.55 / (uRes.y * 0.5)) / (max(r, 0.1) * (TAU / N));
    float line = 1.0 - smoothstep(halfw * 0.6, halfw * 1.4, abs(ta));
    float len = 0.014 + 0.016 * hour;
    float inR = smoothstep(0.905 - 0.003, 0.905, r) * (1.0 - smoothstep(0.905 + len, 0.905 + len + 0.003, r));
    scene += uColB * line * inR * (0.16 + 0.55 * hour) * sl;
    // hour + minute markers
    float ah = uM.y * TAU; float am = uM.z * TAU;
    vec2 ph = vec2(sin(ah), cos(ah)) * 0.80;
    vec2 pm = vec2(sin(am), cos(am)) * 0.865;
    float dh = length(p - ph), dm = length(p - pm);
    scene += uColA * (core(dh, 0.020) * 1.2 + glow(dh, 0.05) * 0.16) * sl;
    scene += uColB * (core(dm, 0.011) * 1.1 + glow(dm, 0.035) * 0.14) * sl;
    // pilot light
    float pl = uP.x * (0.55 + 0.45 * sin(uP.y)) ;
    float dp = length(p);
    scene += uColA * (core(dp, 0.014) * 1.3 + glow(dp, 0.06) * 0.22) * pl * sleep;
  }

  // ── output: filmic soft-clip, gamma, dither, round mask ─────────────────────────────
  vec3 c = 1.0 - exp(-scene * 1.25);
  c = pow(c, vec3(1.0 / 2.2));
  float ign = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * fract(uTime * 7.13), vec2(0.06711056, 0.00583715))));
  c += (ign - 0.5) * (1.8 / 255.0);
  float m = 1.0 - smoothstep(0.985, 1.0, r);
  fragColor = vec4(max(c, 0.0) * m, 1.0);
}`;

// ── palettes (sRGB hex → linear) ───────────────────────────────────────────────────────
const hex2lin = (h) => {
  const n = parseInt(h.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
};
const PAL = {
  sleep:  { A: '#FF6A2B', B: '#7B86FF', C: '#FFE3C2' },
  idle:   { A: '#FFA25C', B: '#7B86FF', C: '#FFE3C2' },
  listen: { A: '#7B86FF', B: '#DDE0FF', C: '#F1F3FF' },
  think:  { A: '#C77BD8', B: '#7B86FF', C: '#FFE3C2' },
  speak:  { A: '#FF6A2B', B: '#FFA25C', C: '#FFE9CF' },
  error:  { A: '#FF4D6D', B: '#FF6A2B', C: '#FFD6DE' },
  conn:   { A: '#7B86FF', B: '#C77BD8', C: '#DDE0FF' },
};
const MOOD = {   // tints blended (45%) into the palette so the glow reads as feeling
  calm:      { A: '#8FA8FF', B: '#DDE0FF' },
  happy:     { A: '#FFB347', B: '#FFE08A' },
  curious:   { A: '#5EE0D0', B: '#9BB3FF' },
  excited:   { A: '#FF4D8D', B: '#FF9A3C' },
  sleepy:    { A: '#C98A5A', B: '#8A7FB8' },
  concerned: { A: '#B98CFF', B: '#FF7D93' },
};
export const STATE_LABELS = { sleep: '', idle: 'READY', listening: 'LISTENING', thinking: 'THINKING', speaking: 'SPEAKING', connecting: 'CONNECTING', error: 'OFFLINE', boot: '' };

const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
const lerp = (a, b, t) => a + (b - a) * t;
const damp = (cur, target, dt, half) => target + (cur - target) * Math.pow(0.5, dt / half);

export class Scope {
  constructor(container, opts = {}) {
    this.opts = Object.assign({ size: 720, fps: 30, quality: 'auto', preserve: false, autostart: false, clock: true, labels: true }, opts);
    this.container = container;
    this.size = this.opts.size;
    this.scale = this.opts.quality === 'low' ? 0.5 : this.opts.quality === 'medium' ? 0.75 : 1.0;
    this.autoQuality = this.opts.quality === 'auto';
    this.time = 0; this.frame = 0; this._acc = 0;
    // state
    this.stateName = 'sleep'; this.mood = 'calm'; this.muted = false; this.timer = null;
    this.w = { sleep: 1, idle: 0, listen: 0, think: 0, speak: 0, error: 0, conn: 0, muted: 0 };
    this.open = 0; this._openTarget = 0; this._openVel = 0; this.blink = 0; this._nextBlink = 3 + Math.random() * 3;
    this.gaze = [0, 0]; this._gazeT = [0, 0]; this.headDeg = 0; this._ringRot = 0;
    this.inLevel = 0; this.outLevel = 0; this._inL = 0; this._outL = 0; this.pulse = 0;
    this.think = 0; this.dim = 1; this.boot = 0; this.pilot = 0.55; this.breath = 0;
    this.clockOn = this.opts.clock; this.labelAlpha = 0; this.labelText = ''; this.cardAlpha = 0;
    this.hintFn = null; this.hintAlpha = 0; this._sleepAt = 0; this._sleepCount = 0;   // first-run affordance: a quiet "TAP TO WAKE" on the first few sleeps
    this.pal = { A: hex2lin('#FF6A2B'), B: hex2lin('#7B86FF'), C: hex2lin('#FFE3C2') };
    this.data = new Uint8Array(256 * 16).fill(128);
    this._hist = []; this._histT = 0;
    this.demo = null;
    this.fpsAvg = 30; this.slowFrames = 0; this.fastFrames = 0;
    this._buildDom();
    this._initGL();
  }

  // ── DOM ─────────────────────────────────────────────────────────────────────────────
  _buildDom() {
    const c = this.container;
    c.classList.add('scope-root');
    if (getComputedStyle(c).position === 'static') c.style.position = 'relative';
    this.gl_canvas = document.createElement('canvas');
    this.gl_canvas.className = 'scope-gl';
    this.ov_canvas = document.createElement('canvas');
    this.ov_canvas.className = 'scope-ov';
    for (const cv of [this.gl_canvas, this.ov_canvas]) {
      cv.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block;';
      c.appendChild(cv);
    }
    this._resize();
    this.ctx = this.ov_canvas.getContext('2d');
  }
  _resize() {
    const s = Math.round(this.size * this.scale);
    this.gl_canvas.width = this.gl_canvas.height = s;
    this.k = Math.max(1, this.scale);                           // overlay is at least full-res; supersampled for hi-res capture
    this.ov_canvas.width = this.ov_canvas.height = Math.round(this.size * this.k);
  }

  // ── WebGL ───────────────────────────────────────────────────────────────────────────
  _initGL() {
    const gl = this.gl = this.gl_canvas.getContext('webgl2', { antialias: false, alpha: false, depth: false, stencil: false, powerPreference: 'high-performance', preserveDrawingBuffer: !!this.opts.preserve });
    if (!gl) { this.noGL = true; return; }
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; };
    const prog = this.prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'aPos'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    this.U = {};
    for (const n of ['uRes', 'uTime', 'uData', 'uS1', 'uS2', 'uColA', 'uColB', 'uColC', 'uL', 'uG', 'uM', 'uP', 'uDbg']) this.U[n] = gl.getUniformLocation(prog, n);
    this.tex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, 256, 16, 0, gl.RED, gl.UNSIGNED_BYTE, this.data);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.uniform1i(this.U.uData, 0);
    this.gl_canvas.addEventListener('webglcontextlost', (e) => { e.preventDefault(); this.lost = true; });
    this.gl_canvas.addEventListener('webglcontextrestored', () => { this.lost = false; this._initGL(); });
  }

  // ── public API ───────────────────────────────────────────────────────────────────────
  setState(name) {
    if (name === this.stateName) return;
    const prev = this.stateName;
    this.stateName = name;
    this.labelText = STATE_LABELS[name] || '';
    if (name === 'sleep') { this._sleepAt = performance.now(); this._sleepCount++; }
    this._openTarget = (name === 'sleep' || name === 'boot') ? (name === 'boot' ? 1 : 0) : 1;
    if (prev === 'sleep' && name !== 'sleep') this.pulse = 1;
    if (name === 'speaking' || name === 'listening') this.pulse = Math.max(this.pulse, 0.6);
  }
  setMood(m) { if (MOOD[m]) this.mood = m; }
  setMuted(v) { this.muted = !!v; }
  setTimer(frac) { this.timer = frac == null ? null : frac; }
  setGaze(x, y) { this._gazeT = [clamp(x, -1, 1), clamp(y, -1, 1)]; }
  setHead(deg) { this.headDeg = deg; }
  setDim(v) { this.dim = clamp(v, 0, 1); }
  setClock(hour01, min01) { this.clock = [hour01, min01]; }
  setAudio({ inWave, outWave, inSpec, outSpec, inLevel, outLevel } = {}) {
    if (inWave) this._writeWave(0, inWave, true);
    if (outWave) this._writeWave(1, outWave, true);
    if (inSpec) this._writeSpec(2, inSpec);
    if (outSpec) this._writeSpec(3, outSpec);
    if (inLevel != null) this.inLevel = inLevel;
    if (outLevel != null) this.outLevel = outLevel;
  }
  blinkNow() { this._blinkT = 0.0001; }
  setQuality(scale) { this.scale = clamp(scale, 0.35, 3); this._resize(); }

  // Float32 [-1,1] (any length) → row of 256 bytes, circularly cross-faded so the ring closes seamlessly
  _writeWave(row, src, gain) {
    const N = 256, out = this.data, base = row * N;
    const L = src.length, tmp = new Float32Array(N);
    let peak = 0;
    for (let i = 0; i < N; i++) {
      const a = Math.floor((i / N) * L), b = Math.max(a + 1, Math.floor(((i + 1) / N) * L));
      let s = 0; for (let k = a; k < b; k++) s += src[k]; tmp[i] = s / (b - a); peak = Math.max(peak, Math.abs(tmp[i]));
    }
    for (let pass = 0; pass < 3; pass++) {           // circular binomial smoothing — keeps the ring elegant, not spiky
      const t2 = new Float32Array(N);
      for (let i = 0; i < N; i++) t2[i] = (tmp[(i + N - 1) % N] + 2 * tmp[i] + tmp[(i + 1) % N]) / 4;
      tmp.set(t2);
    }
    // make the wave periodic: remove the linear ramp between its last and first sample so the ring closes without a seam
    const jump = tmp[N - 1] - tmp[0];
    for (let i = 0; i < N; i++) tmp[i] -= jump * (i / (N - 1));
    peak = 0; for (let i = 0; i < N; i++) peak = Math.max(peak, Math.abs(tmp[i]));
    const norm = gain ? clamp(0.55 / Math.max(peak, 0.05), 0.8, 9) : 1;   // auto-gain so quiet voices still deform the ring
    for (let i = 0; i < N; i++) {
      const v = clamp(tmp[i] * norm, -1, 1);
      const prev = (out[base + i] / 255) * 2 - 1;
      out[base + i] = Math.round((lerp(prev, v, 0.65) * 0.5 + 0.5) * 255);
    }
  }
  _writeSpec(row, src) {
    const N = 256, base = row * N, L = src.length;
    for (let i = 0; i < N; i++) {
      const a = Math.floor((i / N) * L * 0.5);       // lower half of the analyser bins = speech band
      const v = src[Math.min(L - 1, a)] / 255;
      const prev = this.data[base + i] / 255;
      this.data[base + i] = Math.round(clamp(lerp(prev, Math.pow(v, 1.35), 0.55), 0, 1) * 255);
    }
  }
  _pushHistory() {
    // shift out-wave history rows (4..11) and mic history (12..15)
    const N = 256, d = this.data;
    for (let r = 11; r > 4; r--) d.copyWithin(r * N, (r - 1) * N, r * N);
    d.copyWithin(4 * N, 1 * N, 2 * N);
    for (let r = 15; r > 12; r--) d.copyWithin(r * N, (r - 1) * N, r * N);
    d.copyWithin(12 * N, 0, N);
  }

  // ── simulation step ────────────────────────────────────────────────────────────────────
  step(dt) {
    dt = Math.min(dt, 0.1);
    this.time += dt; this.breath += dt * 1.1;
    const s = this.stateName;
    const T = { sleep: 0, idle: 0, listen: 0, think: 0, speak: 0, error: 0, conn: 0 };
    if (s === 'sleep') T.sleep = 1; else if (s === 'idle') T.idle = 1; else if (s === 'listening') T.listen = 1; else if (s === 'thinking') T.think = 1;
    else if (s === 'speaking') T.speak = 1; else if (s === 'error') T.error = 1; else if (s === 'connecting') T.conn = 1; else if (s === 'boot') { T.idle = 0.5; }
    const w = this.w;
    const half = { sleep: 0.35, idle: 0.28, listen: 0.16, think: 0.22, speak: 0.12, error: 0.25, conn: 0.2 };
    for (const k of Object.keys(T)) w[k] = damp(w[k], T[k], dt, half[k]);
    w.muted = damp(w.muted, this.muted ? 1 : 0, dt, 0.2);

    // iris: springy open with a little overshoot
    const k = 60, c = 12;
    const acc = k * (this._openTarget - this.open) - c * this._openVel;
    this._openVel += acc * dt; this.open += this._openVel * dt;
    if (s === 'boot') this.boot = damp(this.boot, 1, dt, 0.5); else this.boot = damp(this.boot, 0, dt, 0.4);

    // levels
    this._inL = damp(this._inL, this.inLevel, dt, this.inLevel > this._inL ? 0.03 : 0.12);
    this._outL = damp(this._outL, this.outLevel, dt, this.outLevel > this._outL ? 0.03 : 0.14);
    this.pulse = damp(this.pulse, 0, dt, 0.35);

    // gaze spring + idle saccades
    this._sacc = (this._sacc || 0) - dt;
    if (this._sacc <= 0 && (s === 'idle' || s === 'listening' || s === 'thinking')) { this._sacc = 1.8 + Math.random() * 3.5; this._gazeIdle = [(Math.random() - 0.5) * 0.7, (Math.random() - 0.5) * 0.35]; }
    const gi = this._gazeIdle || [0, 0];
    const gt = [this._gazeT[0] + gi[0] * (s === 'speaking' ? 0.2 : 1), this._gazeT[1] + gi[1] * (s === 'speaking' ? 0.2 : 1)];
    this.gaze[0] = damp(this.gaze[0], gt[0], dt, 0.12); this.gaze[1] = damp(this.gaze[1], gt[1], dt, 0.12);

    // blink
    this._nextBlink -= dt;
    if (this._nextBlink <= 0 && !this._blinkT && s !== 'sleep' && s !== 'speaking') { this._blinkT = 0.0001; this._nextBlink = 3 + Math.random() * 5; }
    if (this._blinkT) { this._blinkT += dt; const t = this._blinkT / 0.20; this.blink = t < 1 ? Math.sin(t * Math.PI) : 0; if (t >= 1) this._blinkT = 0; } else this.blink = 0;

    // head compass counter-rotation, comet
    this._ringRot = damp(this._ringRot, -this.headDeg * Math.PI / 180, dt, 0.08);
    this.think += dt * (s === 'connecting' ? 2.6 : 3.4);

    // palette
    this._updatePalette(dt);

    // history rows (sonar echoes) every ~85 ms
    this._histT += dt;
    if (this._histT > 0.085) { this._histT = 0; this._pushHistory(); }

    if (this.demo) this.demo(this, dt);
  }

  _updatePalette(dt) {
    const w = this.w, acc = { A: [0, 0, 0], B: [0, 0, 0], C: [0, 0, 0] };
    let tot = 0;
    const add = (name, wt) => { if (wt <= 0.0005) return; const p = PAL[name]; tot += wt; for (const ch of ['A', 'B', 'C']) { const c = hex2lin(p[ch]); for (let i = 0; i < 3; i++) acc[ch][i] += c[i] * wt; } };
    add('sleep', w.sleep); add('idle', w.idle); add('listen', w.listen); add('think', w.think); add('speak', w.speak); add('error', w.error); add('conn', w.conn);
    if (tot < 1e-4) tot = 1;
    const mood = MOOD[this.mood];
    const mA = hex2lin(mood.A), mB = hex2lin(mood.B);
    const moodAmt = (this.mood === 'calm' ? 0.0 : 0.45) * clamp(w.speak + w.idle * 0.6 + w.listen * 0.3, 0, 1);
    const grey = this.w.muted;
    for (const ch of ['A', 'B', 'C']) {
      const tgt = acc[ch].map((v, i) => {
        let x = v / tot;
        if (ch === 'A') x = lerp(x, mA[i], moodAmt); if (ch === 'B') x = lerp(x, mB[i], moodAmt);
        const l = (x + acc[ch][(i + 1) % 3] / tot + acc[ch][(i + 2) % 3] / tot) / 3;
        return lerp(x, l * 0.9, grey * 0.9);
      });
      for (let i = 0; i < 3; i++) this.pal[ch][i] = damp(this.pal[ch][i], tgt[i], dt, 0.12);
    }
  }

  // ── draw ─────────────────────────────────────────────────────────────────────────────────
  draw() {
    const gl = this.gl;
    if (this.noGL || !gl || this.lost) { this._drawFallback(); this._drawOverlay(); return; }
    const w = this.w, U = this.U, s = this.gl_canvas.width;
    gl.viewport(0, 0, s, s);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 256, 16, gl.RED, gl.UNSIGNED_BYTE, this.data);
    gl.uniform2f(U.uRes, s, s); gl.uniform1f(U.uTime, this.time);
    gl.uniform4f(U.uS1, w.sleep, w.idle, w.listen, w.think);
    gl.uniform4f(U.uS2, w.speak, w.error, w.conn, w.muted);
    gl.uniform3fv(U.uColA, this.pal.A); gl.uniform3fv(U.uColB, this.pal.B); gl.uniform3fv(U.uColC, this.pal.C);
    gl.uniform4f(U.uL, this._inL, this._outL, this.open, this.blink);
    gl.uniform4f(U.uG, this.gaze[0], this.gaze[1], this._ringRot, this.think);
    const now = new Date(); const clk = this.clock || [((now.getHours() % 12) + now.getMinutes() / 60) / 12, now.getMinutes() / 60 + now.getSeconds() / 3600];
    gl.uniform4f(U.uM, this.timer == null ? -1 : this.timer, clk[0], clk[1], this.clockOn ? this.dim * 0.55 : 0);
    gl.uniform4f(U.uP, 0.8 * this.dim, this.breath, this.boot, this.pulse);
    gl.uniform1f(U.uDbg, this.dbg || 0);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    this._drawOverlay();
  }

  _drawFallback() {   // minimal 2D fallback when WebGL is unavailable
    const c = this.ctx, S = this.size; c.save(); c.setTransform(1, 0, 0, 1, 0, 0); c.fillStyle = '#000'; c.fillRect(0, 0, S, S);
    const col = (a) => `rgba(${Math.round(255 * Math.pow(this.pal.A[0], 1 / 2.2))},${Math.round(255 * Math.pow(this.pal.A[1], 1 / 2.2))},${Math.round(255 * Math.pow(this.pal.A[2], 1 / 2.2))},${a})`;
    const awake = 1 - this.w.sleep, lv = Math.max(this._inL, this._outL);
    c.strokeStyle = col(0.9 * awake + 0.2); c.lineWidth = 4; c.shadowColor = col(1); c.shadowBlur = 24;
    c.beginPath(); c.arc(S / 2, S / 2, S * (0.2 + 0.03 * lv), 0, Math.PI * 2); c.stroke();
    c.fillStyle = col(1); c.beginPath(); c.arc(S / 2, S / 2, 12 + 10 * lv, 0, Math.PI * 2); c.fill(); c.restore();
  }

  _drawOverlay() {
    const c = this.ctx, S = this.size, cx = S / 2, cy = S / 2, k = this.k || 1;
    c.setTransform(k, 0, 0, k, 0, 0);
    if (!this.noGL && this.gl && !this.lost) c.clearRect(0, 0, S, S);
    const A = this.pal.A.map((v) => Math.round(255 * clamp(Math.pow(Math.max(v, 0), 1 / 2.2), 0, 1)));
    const rgb = (a) => `rgba(${A[0]},${A[1]},${A[2]},${a})`;
    const s = this.stateName;
    // state label on the bottom arc
    const want = (this.opts.labels && !this.labelHidden && s !== 'sleep' && s !== 'boot') ? 1 : 0;
    this.labelAlpha = damp(this.labelAlpha, want, 1 / 60, 0.25);
    if (this.labelAlpha > 0.01) {
      const txt = this.muted ? 'MUTED' : (this.labelText || '');
      if (txt) this._arcText(c, txt, cx, cy, 292, Math.PI / 2, '500 13px "Martian Mono", monospace', 5.2, rgb(0.62 * this.labelAlpha), false);
    }
    // sleep hint: only for the first three sleeps after boot, a couple of seconds in, for ~9 s
    const hintTxt = (this.hintFn && this.opts.labels) ? this.hintFn() : '';
    const sleepAge = s === 'sleep' ? (performance.now() - this._sleepAt) / 1000 : 0;
    const hintWant = hintTxt && s === 'sleep' && this._sleepCount <= 3 && sleepAge > 2.2 && sleepAge < 11 ? 1 : 0;
    this.hintAlpha = damp(this.hintAlpha, hintWant, 1 / 60, 0.7);
    if (this.hintAlpha > 0.01 && hintTxt) this._arcText(c, hintTxt, cx, cy, 292, Math.PI / 2, '500 13px "Martian Mono", monospace', 5.2, rgb(0.42 * this.hintAlpha), false);
    // muted glyph + listening dots
    if (this.muted && this.w.muted > 0.05) {
      c.save(); c.translate(cx, cy + 226); c.strokeStyle = `rgba(243,240,234,${0.55 * this.w.muted})`; c.lineWidth = 2.4; c.lineCap = 'round';
      c.beginPath(); c.roundRect(-7, -16, 14, 24, 7); c.stroke(); c.beginPath(); c.arc(0, -2, 15, 0.2 * Math.PI, 0.8 * Math.PI); c.stroke();
      c.beginPath(); c.moveTo(-20, -24); c.lineTo(20, 22); c.stroke(); c.restore();
    }
    // boot mark: the "p" strokes itself in
    if (this.boot > 0.02) this._drawBootMark(c, cx, cy, this.boot);
  }

  _arcText(c, text, cx, cy, R, centerAngle, font, spacing, color, top) {
    c.save(); c.font = font; c.fillStyle = color; c.textAlign = 'center'; c.textBaseline = 'middle';
    const widths = [...text].map((ch) => c.measureText(ch).width + spacing);
    const total = widths.reduce((a, b) => a + b, 0) - spacing;
    let phi = top ? centerAngle - total / (2 * R) : centerAngle + total / (2 * R);
    [...text].forEach((ch, i) => {
      const half = widths[i] / 2 - spacing / 2;
      phi += top ? half / R : -half / R;
      c.save(); c.translate(cx + R * Math.cos(phi), cy + R * Math.sin(phi)); c.rotate(top ? phi + Math.PI / 2 : phi - Math.PI / 2); c.fillText(ch, 0, 0); c.restore();
      phi += top ? (widths[i] - half) / R : -(widths[i] - half) / R;
    });
    c.restore();
  }

  _drawBootMark(c, cx, cy, t) {
    // the logo's "p": lens ring centred on the pupil, stem tangent on the left, growing downward
    const R = 62, sw = 15, ease = (x) => x * x * (3 - 2 * x);
    const tt = clamp((t - 0.08) / 0.85, 0, 1);
    c.save(); c.translate(cx, cy); c.lineCap = 'round'; c.lineWidth = sw;
    c.strokeStyle = `rgba(243,240,234,${0.92 * Math.min(1, t * 2.2)})`;
    c.shadowColor = 'rgba(255,106,43,0.40)'; c.shadowBlur = 20;
    const ringP = ease(clamp(tt / 0.7, 0, 1)), stemP = ease(clamp((tt - 0.30) / 0.70, 0, 1));
    c.beginPath(); c.arc(0, 0, R, -Math.PI * 0.5, -Math.PI * 0.5 - Math.PI * 2 * ringP, true); c.stroke();
    c.beginPath(); c.moveTo(-R, -R + 0.01); c.lineTo(-R, -R + (2 * R + 62) * stemP); c.stroke();
    c.restore();
  }

  // ── loop ─────────────────────────────────────────────────────────────────────────────────
  start() {
    if (this._raf) return; this._last = performance.now(); this._running = true;
    const loop = (now) => {
      if (!this._running) return;
      this._raf = requestAnimationFrame(loop);
      const dtms = now - this._last;
      const minMs = 1000 / this.opts.fps - 1;
      if (dtms < minMs) return;
      this._last = now;
      const dt = dtms / 1000;
      this.step(dt); this.draw(); this.frame++;
      this._adapt(dtms);
    };
    this._raf = requestAnimationFrame(loop);
  }
  stop() { this._running = false; if (this._raf) cancelAnimationFrame(this._raf); this._raf = 0; }
  _adapt(dtms) {
    this.fpsAvg = lerp(this.fpsAvg, 1000 / Math.max(dtms, 1), 0.08);
    if (!this.autoQuality) return;
    const target = this.opts.fps;
    if (this.fpsAvg < target * 0.8) { this.slowFrames++; this.fastFrames = 0; } else if (this.fpsAvg > target * 0.97) { this.fastFrames++; this.slowFrames = 0; }
    if (this.slowFrames > 45 && this.scale > 0.5) { this.scale = Math.max(0.5, this.scale - 0.125); this._resize(); this.slowFrames = 0; }
    if (this.fastFrames > 600 && this.scale < 1) { this.scale = Math.min(1, this.scale + 0.125); this._resize(); this.fastFrames = 0; }
  }
  destroy() { this.stop(); this.container.innerHTML = ''; }
}
