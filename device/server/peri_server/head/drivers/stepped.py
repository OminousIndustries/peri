"""Shared base for drivers that generate steps themselves (simulator, GPIO): StepperCore + 10 Hz state events."""
from __future__ import annotations

import asyncio
import logging
from typing import Any, Optional

from ..stepgen import CoilCallback, StepperCore
from .base import DriverState, HeadDriver, StepScale

log = logging.getLogger("peri.head")

EMIT_PERIOD_S = 0.1


class SteppedDriver(HeadDriver):
    """Subclasses supply ``_now()`` (the clock ``StepperCore`` is driven with) and ``_start_stepping``/``_stop_stepping``."""

    def __init__(self, scale: StepScale, clock: Any, on_coils: Optional[CoilCallback] = None) -> None:
        super().__init__()
        self.scale = scale
        self._clock = clock
        self._core = StepperCore(0, on_coils=on_coils)
        self._epoch = 0
        self._ticker: Optional["asyncio.Task[None]"] = None
        self._started = False

    # -- hooks -------------------------------------------------------------------------------------------------
    def _now(self) -> float:
        raise NotImplementedError

    def _step_from_ticker(self) -> bool:
        """True when the event-loop ticker should also advance the core (simulator); False for a stepping thread."""
        return False

    def _kick(self) -> None:
        """Called after a command so a stepping thread can wake up."""

    # -- lifecycle ---------------------------------------------------------------------------------------------
    async def start(self) -> None:
        if self._started:
            return
        self._started = True
        self._epoch += 1
        self._ticker = asyncio.ensure_future(self._run_ticker())
        self._emit()

    async def stop(self) -> None:
        self._started = False
        if self._ticker is not None:
            self._ticker.cancel()
            try:
                await self._ticker
            except (asyncio.CancelledError, Exception):
                pass
            self._ticker = None

    async def _run_ticker(self) -> None:
        """Emit state at 10 Hz while moving and once when a move ends (and advance the core in simulator mode)."""
        last_emit = float("-inf")
        was_moving = False
        try:
            while True:
                await self._clock.sleep(self.TICK_S)
                if self._step_from_ticker():
                    self._core.advance(self._clock.now())
                moving = self._core.snapshot()[2]
                now = self._clock.now()
                if (moving and now - last_emit >= EMIT_PERIOD_S) or (was_moving and not moving):
                    last_emit = now
                    self._emit()
                was_moving = moving
        except asyncio.CancelledError:
            raise

    TICK_S = 0.01

    # -- state -------------------------------------------------------------------------------------------------
    def _state(self, name: str, connected: bool = True, detail: str = "") -> DriverState:
        pos, target, moving, energised = self._core.snapshot()
        return DriverState(driver=name, connected=connected and self._started, position_deg=self.scale.to_deg(pos),
                           target_deg=self.scale.to_deg(target), moving=moving, energised=energised, epoch=self._epoch,
                           detail=detail)

    # -- commands ----------------------------------------------------------------------------------------------
    async def move_to(self, target_deg: float, max_dps: float, accel_dps2: float) -> None:
        self._core.move(self.scale.to_steps(target_deg), self.scale.rate_to_steps(max_dps),
                        self.scale.rate_to_steps(accel_dps2), self._now())
        self._kick()
        self._emit()

    async def halt(self) -> None:
        self._core.halt()
        self._kick()
        self._emit()

    async def emergency_stop(self) -> None:
        self._core.emergency_stop()
        self._emit()

    async def release(self) -> None:
        if self._core.release():
            self._emit()

    async def set_zero(self) -> None:
        if self._core.zero():
            self._emit()
