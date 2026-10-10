"""Time-accurate stepper simulator. Default driver off-Pi; behaves like the Arduino firmware (same StepperCore)."""
from __future__ import annotations

from typing import Any, Optional

from .base import DriverState, StepScale
from .stepped import SteppedDriver


class SimDriver(SteppedDriver):
    name = "sim"

    def __init__(self, scale: StepScale, clock: Optional[Any] = None) -> None:
        from ..clock import RealClock

        super().__init__(scale, clock if clock is not None else RealClock())

    def _now(self) -> float:
        return self._clock.now()

    def _step_from_ticker(self) -> bool:
        return True

    def snapshot(self) -> DriverState:
        state = self._state("sim", detail="simulated neck (no hardware)")
        # keep the position current even between ticks so reads after `advance` are exact
        if self._started:
            self._core.advance(self._clock.now())
            state = self._state("sim", detail="simulated neck (no hardware)")
        return state
