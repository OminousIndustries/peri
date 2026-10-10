"""Stepper motion core: a step-interval generator plus a small thread-safe wrapper.

The generator implements exactly the algorithm documented in ``firmware/README.md`` ("Motion algorithm"): a
constant-acceleration trapezoid with retargeting (David Austin's step-interval recurrence, the scheme AccelStepper uses).
It is shared by the simulator driver, the GPIO driver and the pty firmware simulator used in tests, so all of them
behave like the Arduino sketch.

Units here are half-steps and seconds; conversion to degrees lives in ``drivers.base.StepScale``.
"""
from __future__ import annotations

import math
import threading
from typing import Callable, Optional, Tuple

C0_FACTOR = 0.676  # Austin's correction for the first step interval


class StepGenerator:
    """Pure state machine: no clock, no I/O. ``step()`` moves one half-step and returns the delay to the next one."""

    def __init__(self, position: int = 0) -> None:
        self.pos = int(position)
        self.target = int(position)
        self.n = 0                 # signed step index within the accel (+) / decel (-) phase
        self.dir = 1               # +1 / -1
        self.cn = 0.0              # current step interval, seconds
        self.vmax = 1.0
        self.accel = 1.0
        self._c0 = C0_FACTOR * math.sqrt(2.0 / self.accel)
        self._cmin = 1.0 / self.vmax

    def configure(self, vmax: float, accel: float) -> None:
        """Set cruise speed (steps/s) and acceleration (steps/s^2); safe to call while moving (retarget).

        When ``accel`` changes mid-ramp, ``n`` is rescaled by ``a_old / a_new`` (v^2 = 2 a n stays constant, so the speed does
        not jump and the new acceleration applies at once); it stays non-zero.
        """
        new_accel = max(1.0, float(accel))
        if self.n != 0 and new_accel != self.accel:
            rescaled = int(self.n * self.accel / new_accel)
            self.n = rescaled if rescaled != 0 else (1 if self.n > 0 else -1)
        self.vmax = max(1.0, float(vmax))
        self.accel = new_accel
        self._c0 = C0_FACTOR * math.sqrt(2.0 / self.accel)
        self._cmin = 1.0 / self.vmax

    @property
    def moving(self) -> bool:
        return self.pos != self.target or self.n != 0

    @property
    def speed(self) -> float:
        """Current speed magnitude in steps/s (0 when stopped)."""
        return 0.0 if self.n == 0 or self.cn <= 0.0 else 1.0 / self.cn

    def steps_to_stop(self) -> int:
        """Half-steps needed to come to rest from the current speed (truncated, as in the firmware)."""
        if self.n == 0 or self.cn <= 0.0:
            return 0
        v = 1.0 / self.cn
        return int(v * v / (2.0 * self.accel))

    def begin(self) -> Optional[float]:
        """(Re)evaluate after a target change while at rest; returns the delay before the first step (None: arrived)."""
        return self._compute()

    def step(self) -> Optional[float]:
        """Perform one half-step in the current direction; returns the delay until the next step, None when done."""
        self.pos += self.dir
        return self._compute()

    def decelerate_stop(self) -> None:
        """``S``: make the stopping point the new target.

        The next step is already scheduled when ``S`` arrives and the braking decision is only taken after it, so the
        stopping point is ``stops + 1`` steps ahead (without the +1 the move overshoots by one step and comes back).
        """
        if self.moving:
            self.target = self.pos + self.dir * (self.steps_to_stop() + 1)
        else:
            self.target = self.pos

    def emergency_stop(self) -> None:
        """``X``: stop at once, keep the position."""
        self.target = self.pos
        self.n = 0
        self.cn = 0.0

    def _compute(self) -> Optional[float]:
        dist = self.target - self.pos
        stops = self.steps_to_stop()
        if dist == 0 and stops <= 1:
            self.n = 0
            self.cn = 0.0
            return None
        if dist > 0:
            if self.n > 0:
                if stops >= dist or self.dir < 0:
                    self.n = -stops
            elif self.n < 0:
                if stops < dist and self.dir > 0:
                    self.n = -self.n
        elif dist < 0:
            if self.n > 0:
                if stops >= -dist or self.dir > 0:
                    self.n = -stops
            elif self.n < 0:
                if stops < -dist and self.dir < 0:
                    self.n = -self.n
        if self.n == 0:
            self.cn = self._c0
            self.dir = 1 if dist > 0 else -1
        else:
            self.cn = self.cn - (2.0 * self.cn) / (4.0 * self.n + 1.0)
            if self.cn < self._cmin and self.n > 0:
                self.n -= 1          # cruising: hold n, so a later higher vmax accelerates at `accel` instead of creeping
        self.cn = max(self.cn, self._cmin)   # never faster than vmax (also for the first step at a very low vmax)
        self.n += 1
        return self.cn


#: ``on_coils(position, energised)``: called whenever the coil output should change.
CoilCallback = Callable[[int, bool], None]

#: Half-step drive table, columns IN1..IN4, indexed by ``position & 7`` (see firmware/README.md).
HALF_STEP_TABLE: Tuple[Tuple[int, int, int, int], ...] = (
    (1, 0, 0, 0), (1, 1, 0, 0), (0, 1, 0, 0), (0, 1, 1, 0), (0, 0, 1, 0), (0, 0, 1, 1), (0, 0, 0, 1), (1, 0, 0, 1),
)


class StepperCore:
    """Thread-safe motion state: generator + step schedule + coil bookkeeping. Time is passed in by the caller.

    ``advance(now)`` executes every step that is due at ``now`` (catching up if the caller was late), which makes the
    same core usable from an asyncio ticker (simulator), a dedicated thread (GPIO) or a pty firmware model (tests).
    """

    MAX_CATCH_UP = 20000  # runaway guard when a clock jumps far ahead

    def __init__(self, position: int = 0, on_coils: Optional[CoilCallback] = None) -> None:
        self._gen = StepGenerator(position)
        self._on_coils = on_coils
        self._due: Optional[float] = None
        self._energised = False
        self._lock = threading.RLock()

    # -- commands -------------------------------------------------------------------------------------------
    def move(self, target: int, vmax: float, accel: float, now: float) -> None:
        """``T``: start a move, or retarget one in progress. Energises the coils."""
        with self._lock:
            gen = self._gen
            gen.configure(vmax, accel)
            gen.target = int(target)
            self._set_energised(True)
            if self._due is None:
                delay = gen.begin()
                if delay is not None:
                    self._due = now + delay

    def halt(self) -> None:
        """``S``: decelerate to a stop."""
        with self._lock:
            self._gen.decelerate_stop()

    def emergency_stop(self) -> None:
        """``X``: stop immediately, coils stay energised."""
        with self._lock:
            self._gen.emergency_stop()
            self._due = None

    def release(self) -> bool:
        """``R``: de-energise. Returns False (and does nothing) while moving."""
        with self._lock:
            if self._gen.moving:
                return False
            self._set_energised(False)
            return True

    def zero(self) -> bool:
        """``Z``: declare the current position 0. Returns False while moving."""
        with self._lock:
            if self._gen.moving:
                return False
            self._gen.pos = 0
            self._gen.target = 0
            return True

    # -- time -----------------------------------------------------------------------------------------------
    def advance(self, now: float) -> int:
        """Execute all steps due at ``now``; returns how many were taken."""
        taken = 0
        with self._lock:
            while self._due is not None and self._due <= now and taken < self.MAX_CATCH_UP:
                scheduled = self._due
                delay = self._gen.step()
                taken += 1
                if self._on_coils is not None:
                    self._on_coils(self._gen.pos, True)
                self._due = None if delay is None else scheduled + delay
        return taken

    def next_due(self) -> Optional[float]:
        with self._lock:
            return self._due

    # -- state ----------------------------------------------------------------------------------------------
    def snapshot(self) -> Tuple[int, int, bool, bool]:
        """``(position, target, moving, energised)``."""
        with self._lock:
            return self._gen.pos, self._gen.target, self._gen.moving, self._energised

    @property
    def generator(self) -> StepGenerator:
        return self._gen

    def _set_energised(self, value: bool) -> None:
        changed = value != self._energised
        self._energised = value
        if self._on_coils is not None and (changed or value):
            self._on_coils(self._gen.pos, value)
