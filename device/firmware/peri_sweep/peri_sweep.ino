/*
 * Experimental standalone head sweep for Peri.
 * Nano (ATmega328P) -> ULN2003 IN1..IN4 on D8..D11 -> 5 V 28BYJ-48.
 * Uses separate power; no Pi, serial commands or extra libraries required.
 *
 * Center the head with power OFF before every startup/reset. There is no
 * position sensor or homing: zero is wherever the head starts. Movement and
 * clearance have not been verified on the physical Peri. Start at +/-5 degrees.
 * Disconnect the Arduino's own supply to stop; Pi shutdown cannot stop it.
 */
#include <Arduino.h>

// Adjust only after checking the mechanism and wiring on your own build.
static constexpr float SWEEP_DEGREES = 5.0f;      // estimated neck angle on each side
static const bool INVERT_DIRECTION = false;  // swap left/right if needed
static const unsigned long STARTUP_PAUSE_MS = 3000;
static const unsigned long PAUSE_MS = 2000;
static const unsigned int STEP_INTERVAL_US = 4000; // slower = larger interval

// Nominal gearing from the existing Peri motor configuration; calibrate physically.
static constexpr float HALF_STEPS_PER_MOTOR_REV = 4075.7728f;
static constexpr float MOTOR_REVS_PER_NECK_REV = 5.1f;
static const int16_t SWEEP_STEPS = static_cast<int16_t>(
    SWEEP_DEGREES * HALF_STEPS_PER_MOTOR_REV * MOTOR_REVS_PER_NECK_REV / 360.0f + 0.5f);
static_assert(SWEEP_DEGREES > 0.0f && SWEEP_DEGREES <= 20.0f,
              "Use a small sweep, never larger than the measured physical clearance");
static_assert(STEP_INTERVAL_US >= 4000 && STEP_INTERVAL_US <= 16000,
              "Use a slow step interval between 4000 and 16000 microseconds");

static const uint8_t PINS[4] = {8, 9, 10, 11}; // IN1, IN2, IN3, IN4
static const uint8_t HALF[8] = {0x1, 0x3, 0x2, 0x6, 0x4, 0xC, 0x8, 0x9};
static int16_t position = 0;
static uint8_t phase = 0;

static void releaseCoils() {
  for (uint8_t i = 0; i < 4; ++i) digitalWrite(PINS[i], LOW);
}

static void moveTo(int16_t target) {
  while (position != target) {
    const int8_t direction = target > position ? 1 : -1;
    const int8_t motorDirection = INVERT_DIRECTION ? -direction : direction;
    phase = static_cast<uint8_t>((phase + (motorDirection > 0 ? 1 : 7)) & 7);
    for (uint8_t i = 0; i < 4; ++i) {
      digitalWrite(PINS[i], (HALF[phase] & (1U << i)) ? HIGH : LOW);
    }
    delayMicroseconds(STEP_INTERVAL_US);
    position += direction;
  }
  releaseCoils(); // no holding current during pauses; recenter if the head is moved
  delay(PAUSE_MS);
}

void setup() {
  for (uint8_t i = 0; i < 4; ++i) {
    digitalWrite(PINS[i], LOW);
    pinMode(PINS[i], OUTPUT);
  }
  delay(STARTUP_PAUSE_MS); // powers up quietly, then starts moving automatically
}

void loop() {
  moveTo(-SWEEP_STEPS); // left, pause
  moveTo(0);            // middle, pause
  moveTo(SWEEP_STEPS);  // right, pause
  moveTo(0);            // middle, pause; repeat without jumping across the full arc
}
