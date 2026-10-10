/*
 * peri_head.ino - serial-controlled stepper controller for the Peri neck.
 *
 * Board : Arduino Nano (ATmega328P), 28BYJ-48 through a ULN2003 board on D8..D11 (IN1..IN4).
 * Needs : nothing but the Arduino core (Serial, micros, millis, port registers, math). No libraries.
 * Spec  : the serial protocol v1 and the motion algorithm in ../README.md are normative; this file implements them.
 *
 * Structure (everything is non-blocking; loop() never waits):
 *   loop() = stepIfDue()      issue at most one step when its time has come
 *          + housekeeping()   asynchronous "P" lines and the coil watchdog
 *          + serviceSerial()  consume at most one input byte; run a complete line when there is time for it
 * Slow work (running a command, printing) is only started when it will be finished before the next step is due,
 * so it can never make a step late.
 */

// ---- configuration ------------------------------------------------------------------------------------------
#define FW_VERSION       "1.0.0"
#define HALF_STEPS_REV   "4076"                  // banner only: nominal half-steps per output-shaft rev (4075.7728)

static const int16_t  MAX_ABS_POS = 3500;        // |target| limit, half-steps (about 60 deg of neck at 5.1:1)
static const int16_t  MAX_SPS     = 1200;        // vmax is clamped to this (half-steps/s); the motor skips above ~1000
static const int16_t  MAX_ACCEL   = 6000;        // accel is clamped to this (half-steps/s^2)
static const uint8_t  LINE_MAX    = 47;          // longest accepted input line (characters); the buffer is one more
static const uint32_t PUSH_MS     = 100;         // period of the asynchronous "P" lines while moving
static const uint32_t WATCHDOG_MS = 30000UL;     // release idle, energised coils after this long
static const uint8_t  TX_NEEDED   = 34;          // free TX bytes needed before printing (longest line is the 32-byte banner)
static const int32_t  SLOW_JOB_US = 500;         // upper bound of one slow job: run a command (sqrt, divisions) + print a line
static const uint8_t  COILS       = 0x0F;        // D8..D11 = PB0..PB3 = ULN2003 IN1..IN4 = low nibble of PORTB

static_assert(1000000L / MAX_SPS > SLOW_JOB_US, "the step interval at MAX_SPS must leave room for a slow job");
#if defined(SERIAL_TX_BUFFER_SIZE) && SERIAL_TX_BUFFER_SIZE < 64
#error "peri_head waits for TX_NEEDED free bytes before it prints: it needs the 64 byte TX buffer of the ATmega328P"
#endif

// Half-step table, indexed by pos & 7 (bit0 = IN1 ... bit3 = IN4). Same as the table in the README.
// "pos & 7" is the correct phase for negative positions too (two's complement: -1 & 7 == 7).
static const uint8_t HALF[8] = {0x1, 0x3, 0x2, 0x6, 0x4, 0xC, 0x8, 0x9};

// ---- state ----------------------------------------------------------------------------------------------------
static int16_t  pos, target;         // half-steps; pos 0 = wherever the head was when the Nano reset
static bool     moving;              // a move (including its braking ramp) is in progress
static bool     energised;           // coils are driven (low nibble of PORTB is a half-step pattern)
static int8_t   dir = 1;             // direction of the current move: +1 / -1
static int32_t  n;                   // Austin ramp counter: >0 accelerating/cruising, <0 braking, 0 = ramp start/end
static float    cn, c0, cmin;        // current interval, first-step interval, cruise interval  [microseconds]
static float    accel, stopK;        // accel [half-steps/s^2]; stopK = 5e11 / accel (see stopSteps)
static uint32_t lastStepUs, stepUs;  // the next step is due at lastStepUs + stepUs (micros(), wraps every 71 min)
static uint32_t lastPushMs;          // last periodic "P"
static uint32_t lastCmdMs;           // last accepted motion command or end of move (watchdog reference)
static bool     pushDue;             // a "P" (move finished / coils released) is still to be sent

static char     line[LINE_MAX + 1];  // input line being assembled
static uint8_t  lineLen;
static bool     lineOverflow;        // the current line is too long: discard it, answer ERR OVERFLOW at its end
static bool     lineReady;           // a complete line is waiting for a moment when it can be run

static const char BANNER[]       = "PERI-HEAD 1 " HALF_STEPS_REV " READY fw=" FW_VERSION "\n";
static const char ERR_UNKNOWN[]  = "ERR UNKNOWN\n";
static const char ERR_ARGS[]     = "ERR ARGS\n";
static const char ERR_RANGE[]    = "ERR RANGE\n";
static const char ERR_BUSY[]     = "ERR BUSY\n";
static const char ERR_OVERFLOW[] = "ERR OVERFLOW\n";

// ---- coils --------------------------------------------------------------------------------------------------
// Direct port writes: only the low nibble of PORTB is touched (D12/D13 and the crystal pins keep their state).
static void drive() {
  PORTB = (PORTB & ~COILS) | HALF[pos & 7];
  energised = true;
}

static void release() {
  PORTB &= ~COILS;
  energised = false;
}

// ---- output -------------------------------------------------------------------------------------------------
static void say(const char *s) { Serial.write(s, strlen(s)); }

static char *putNum(char *p, int16_t v) {         // append a signed decimal number, no printf needed
  uint16_t u = (v < 0) ? -v : v;
  char t[5];
  uint8_t k = 0;
  if (v < 0) *p++ = '-';
  do { t[k++] = '0' + u % 10; u /= 10; } while (u);
  while (k) *p++ = t[--k];
  return p;
}

static void sendState() {                         // P <pos> <target> <moving> <energised>
  char b[24], *p = b;
  *p++ = 'P'; *p++ = ' ';
  p = putNum(p, pos);    *p++ = ' ';
  p = putNum(p, target); *p++ = ' ';
  *p++ = moving ? '1' : '0';    *p++ = ' ';
  *p++ = energised ? '1' : '0'; *p++ = '\n';
  Serial.write(b, p - b);
}

static bool txRoom() { return Serial.availableForWrite() >= TX_NEEDED; }   // printing then never blocks

// True when a slow job started now is done before the next step is due (always true when not moving; at the top
// speed the interval is 833 us, so the job has to start within its first 333 us).
static bool slack() {
  return !moving || (int32_t)stepUs - (int32_t)(micros() - lastStepUs) > SLOW_JOB_US;
}

// ---- motion: step-interval recurrence (README "Motion algorithm") ---------------------------------------------
// Steps needed to stop from the current speed:  stops = trunc(v^2 / 2a)  with v = 1e6 / cn (cn in microseconds),
// i.e. 1e12 / (2 a cn^2) = stopK / cn^2  with stopK = 5e11 / a.  One float division per step instead of two.
static int32_t stopSteps() {
  return (n == 0) ? 0 : (int32_t)(stopK / (cn * cn));
}

// Called right after every step, and once to start a move. Sets n, dir, cn and stepUs for the next step,
// or ends the move.
static void computeNewInterval() {
  int16_t dist  = target - pos;
  int32_t stops = stopSteps();

  if (dist == 0 && stops <= 1) {                  // arrived
    n = 0; cn = 0; moving = false;
    return;
  }
  if (dist > 0) {
    if (n > 0)      { if (stops >= dist  || dir < 0) n = -stops; }    // start braking (or turn round)
    else if (n < 0) { if (stops <  dist  && dir > 0) n = -n; }        // target moved away: accelerate again
  } else {
    if (n > 0)      { if (stops >= -dist || dir > 0) n = -stops; }
    else if (n < 0) { if (stops <  -dist && dir < 0) n = -n; }
  }
  // Braking is the same recurrence with a negative n (4n+1 < 0 makes cn grow); n counts up from -stops to 0.
  if (n == 0) {
    cn = c0;                                      // start from rest, or restart after braking to a halt
    dir = (dist > 0) ? 1 : -1;
  } else {
    cn = cn - 2.0f * cn / (4.0f * n + 1.0f);      // Austin eq. 13: cn = cn-1 - 2 cn-1 / (4n + 1)
    if (cn < cmin && n > 0) n--;                  // cruising: hold n, so a later change of vmax/accel continues smoothly
  }
  if (cn < cmin) cn = cmin;                       // never faster than vmax (also for the first step at very low vmax)
  n++;
  stepUs = (uint32_t)(cn + 0.5f);
}

static void stepIfDue() {
  if (!moving) return;
  uint32_t now = micros();
  if ((uint32_t)(now - lastStepUs) < stepUs) return;   // unsigned difference: correct across the micros() rollover
  pos += dir;                                     // at most one step per loop pass, whatever the lateness
  drive();
  lastStepUs += stepUs;                           // schedule from the ideal time of this step, not from "now"
  computeNewInterval();
  if (!moving) {
    lastCmdMs = millis();                         // holding starts now: the 30 s watchdog counts from here
    pushDue = true;                               // one "P" with moving 0
  } else if ((uint32_t)(now - lastStepUs) > (stepUs >> 3)) {
    lastStepUs = now;                             // more than 1/8 interval late: re-anchor instead of catching up with a
  }                                               // short interval (so no gap is ever shorter than 7/8 of the scheduled one)
}

// ---- commands -----------------------------------------------------------------------------------------------
// Decimal integer with an optional leading '-'. Saturates instead of overflowing, so absurdly long numbers
// still parse (and are then rejected by the range check).
static bool parseInt(const char *s, int32_t *out) {
  bool neg = (*s == '-');
  int32_t v = 0;
  if (neg) s++;
  if (!*s) return false;
  for (; *s; s++) {
    if (*s < '0' || *s > '9') return false;
    if (v < 100000000L) v = v * 10 + (*s - '0');
  }
  *out = neg ? -v : v;
  return true;
}

// T: (re)target. Energises the coils, starts a move from rest or retargets the running one.
static void cmdMove(int16_t tgt, int16_t vmax, int16_t acc) {
  float a = acc;
  if (n != 0 && a != accel) {                     // accel changed mid-ramp: keep the speed (v^2 = 2 a n), rescale n
    int32_t old = n;
    n = (int32_t)((float)n * accel / a);
    if (n == 0) n = (old > 0) ? 1 : -1;
  }
  accel = a;
  stopK = 5e11f / a;
  c0    = 0.676f * sqrt(2.0f / a) * 1e6f;         // first-step interval incl. Austin's correction, microseconds
  cmin  = 1e6f / vmax;
  target = tgt;
  if (!energised) drive();
  if (!moving && target != pos) {
    moving = true;
    n = 0;
    lastStepUs = micros();                        // first step comes c0 after the command
    lastPushMs = millis();
    computeNewInterval();
  }                                               // moving: the running ramp just sees the new target next step
  lastCmdMs = millis();
}

// S: brake to a stop. The recurrence decides about braking after the next step, and that step is already
// scheduled, so the stopping point is stops + 1 steps ahead: then dist == stops holds all along the ramp and
// the move ends exactly on the target (without the +1 it overshoots by one step and comes back).
static void cmdStop() {
  if (moving) target = pos + dir * (stopSteps() + 1);
  lastCmdMs = millis();
}

// X: stop at once, coils stay energised.
static void cmdHalt() {
  moving = false; n = 0; cn = 0;
  target = pos;
  lastCmdMs = millis();
}

// Splits on single spaces (empty tokens are kept, so double spaces are malformed), then dispatches.
static void execLine(char *s) {
  char *arg[4];
  uint8_t argc = 0;
  for (;;) {
    if (argc < 4) arg[argc] = s;
    argc++;
    while (*s && *s != ' ') s++;
    if (!*s) break;
    *s++ = 0;
  }
  const char *cmd = arg[0];

  if (!strcmp(cmd, "T")) {
    int32_t t, v, a;
    if (argc != 4 || !parseInt(arg[1], &t) || !parseInt(arg[2], &v) || !parseInt(arg[3], &a)) { say(ERR_ARGS); return; }
    if (v < 1 || a < 1 || t > MAX_ABS_POS || t < -MAX_ABS_POS)                                { say(ERR_RANGE); return; }
    cmdMove(t, v > MAX_SPS ? MAX_SPS : v, a > MAX_ACCEL ? MAX_ACCEL : a);
    sendState();
  } else if (!strcmp(cmd, "HELLO")) {
    if (argc != 1) say(ERR_ARGS); else say(BANNER);
  } else if (!strcmp(cmd, "Q")) {
    if (argc != 1) say(ERR_ARGS); else sendState();
  } else if (!strcmp(cmd, "S") || !strcmp(cmd, "X")) {
    if (argc != 1) { say(ERR_ARGS); return; }
    if (cmd[0] == 'S') cmdStop(); else cmdHalt();
    sendState();
  } else if (!strcmp(cmd, "Z") || !strcmp(cmd, "R")) {
    if (argc != 1) { say(ERR_ARGS); return; }
    if (moving)    { say(ERR_BUSY); return; }
    if (cmd[0] == 'Z') {
      pos = 0; target = 0;
      if (energised) drive();                     // keep "phase = pos & 7" true for the new numbering
    } else {
      release();
    }
    lastCmdMs = millis();
    sendState();
  } else {
    say(ERR_UNKNOWN);
  }
}

// ---- main loop parts ----------------------------------------------------------------------------------------
static void housekeeping() {
  if (!(moving || energised || pushDue) || !txRoom() || !slack()) return;
  uint32_t ms = millis();
  if (pushDue) {
    pushDue = false;
    sendState();
  } else if (moving) {
    if ((uint32_t)(ms - lastPushMs) >= PUSH_MS) { lastPushMs = ms; sendState(); }
  } else if ((uint32_t)(ms - lastCmdMs) >= WATCHDOG_MS) {   // idle with energised coils: never leave them on
    release();
    sendState();
  }
}

// Collecting a byte is cheap (one per pass: at 115200 baud a byte arrives every 87 us, a pass takes far less).
// Running the finished line is the slow part: it waits until there is time for it, and until a pending "P" is out.
static void serviceSerial() {
  if (lineReady) {
    if (pushDue || !txRoom() || !slack()) return;
    if (lineOverflow) say(ERR_OVERFLOW);          // exactly one reply per line, sent when the line ends
    else { line[lineLen] = 0; execLine(line); }
    lineLen = 0;
    lineOverflow = false;
    lineReady = false;
    return;
  }
  if (!Serial.available()) return;
  char c = Serial.read();
  if (c == '\r') return;                          // ignored anywhere in a line
  if (c == '\n') lineReady = true;
  else if (lineLen < LINE_MAX) line[lineLen++] = c ? c : '?';   // a NUL would silently cut the line short
  else lineOverflow = true;
}

void setup() {
  PORTB &= ~COILS;                                // coils off before the pins become outputs
  DDRB  |= COILS;
  Serial.begin(115200);
  say(BANNER);
}

void loop() {
  stepIfDue();
  housekeeping();
  serviceSerial();
}
