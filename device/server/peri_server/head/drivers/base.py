"""Head driver interface. Drivers speak degrees relative to their own zero (the position when they connected / last ``set_zero``).

Contract every driver honours:
* after ``move_to`` returns, ``snapshot().target_deg`` is the requested target and ``moving`` is True unless already there;
* ``subscribe`` callbacks run in the asyncio event-loop thread, roughly 10 Hz while moving plus once when a move ends and on
  every connect/disconnect;
* ``epoch`` increases whenever the driver's zero reference was lost (first connect, reconnect, firmware reset); the
  controller then re-derives its calibrated angle from the last known one;
* a trapezoidal speed profile, never faster than ``max_dps``, acceleration ``accel_dps2``.
"""
from __future__ import annotations

import abc
import logging
from dataclasses import dataclass, replace
from typing import Callable, List, Optional

log = logging.getLogger("peri.head")


@dataclass(frozen=True)
class DriverState:
    driver: str
    connected: bool
    position_deg: float = 0.0
    target_deg: float = 0.0
    moving: bool = False
    energised: bool = False
    epoch: int = 0
    error: Optional[str] = None
    detail: str = ""      # human hint, e.g. the serial port in use

    def with_changes(self, **kwargs: object) -> "DriverState":
        return replace(self, **kwargs)  # type: ignore[arg-type]


@dataclass(frozen=True)
class StepScale:
    """Degrees <-> half-steps for a given gear train, with optional direction inversion."""

    steps_per_deg: float
    invert: bool = False

    @property
    def sign(self) -> int:
        return -1 if self.invert else 1

    def to_steps(self, degrees: float) -> int:
        return self.sign * int(round(degrees * self.steps_per_deg))

    def to_deg(self, steps: int) -> float:
        return self.sign * steps / self.steps_per_deg

    def rate_to_steps(self, per_deg: float) -> int:
        """deg/s -> steps/s or deg/s^2 -> steps/s^2 (always at least 1)."""
        return max(1, int(round(per_deg * self.steps_per_deg)))


Listener = Callable[[DriverState], None]


class HeadDriver(abc.ABC):
    """Base class: listener bookkeeping + the abstract API."""

    name = "none"

    def __init__(self) -> None:
        self._listeners: List[Listener] = []

    # lifecycle ------------------------------------------------------------------------------------------------
    async def start(self) -> None:  # pragma: no cover - trivial default
        """Acquire hardware / start background work."""

    async def stop(self) -> None:  # pragma: no cover - trivial default
        """Release hardware; must leave the coils de-energised where possible."""

    # state ----------------------------------------------------------------------------------------------------
    @abc.abstractmethod
    def snapshot(self) -> DriverState:
        """Latest known state (cheap, thread-safe)."""

    def subscribe(self, callback: Listener) -> Callable[[], None]:
        self._listeners.append(callback)

        def unsubscribe() -> None:
            if callback in self._listeners:
                self._listeners.remove(callback)

        return unsubscribe

    def _emit(self) -> None:
        state = self.snapshot()
        for callback in list(self._listeners):
            try:
                callback(state)
            except Exception:  # a broken subscriber must never stop the motion code
                log.exception("head state listener failed")

    # commands -------------------------------------------------------------------------------------------------
    @abc.abstractmethod
    async def move_to(self, target_deg: float, max_dps: float, accel_dps2: float) -> None:
        """Absolute move (driver frame); retargets a move in progress smoothly."""

    @abc.abstractmethod
    async def halt(self) -> None:
        """Decelerate to a stop."""

    @abc.abstractmethod
    async def emergency_stop(self) -> None:
        """Stop immediately (coils stay energised)."""

    @abc.abstractmethod
    async def release(self) -> None:
        """De-energise the coils (no-op while moving)."""

    @abc.abstractmethod
    async def set_zero(self) -> None:
        """Declare the current position 0 (no-op while moving)."""
