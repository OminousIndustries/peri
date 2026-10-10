"""``auto`` driver: the Arduino over USB serial when one answers, otherwise the fallback (simulator off-Pi, none on a Pi).

Hot-plug works both ways because the serial driver keeps scanning in the background.
"""
from __future__ import annotations

from typing import Optional, Tuple

from .base import DriverState, HeadDriver


class AutoDriver(HeadDriver):
    def __init__(self, serial: HeadDriver, fallback: HeadDriver) -> None:
        super().__init__()
        self._serial = serial
        self._fallback = fallback
        self._epoch = 0
        self._last_key: Optional[Tuple[str, int, bool]] = None
        self._unsubs = [serial.subscribe(self._forward), fallback.subscribe(self._forward)]

    @property
    def name(self) -> str:  # type: ignore[override]
        return self._active().name

    def _active(self) -> HeadDriver:
        return self._serial if self._serial.snapshot().connected else self._fallback

    def _forward(self, _state: DriverState) -> None:
        self._emit()

    async def start(self) -> None:
        await self._fallback.start()
        await self._serial.start()

    async def stop(self) -> None:
        for unsubscribe in self._unsubs:
            unsubscribe()
        await self._serial.stop()
        await self._fallback.stop()

    def snapshot(self) -> DriverState:
        active = self._active()
        state = active.snapshot()
        key = (active.name, state.epoch, state.connected)
        if key != self._last_key:
            self._last_key = key
            self._epoch += 1
        detail = state.detail
        if active is self._fallback:
            serial_state = self._serial.snapshot()
            if serial_state.detail:
                detail = f"{detail}; serial: {serial_state.detail}" if detail else f"serial: {serial_state.detail}"
        return state.with_changes(epoch=self._epoch, detail=detail)

    async def move_to(self, target_deg: float, max_dps: float, accel_dps2: float) -> None:
        await self._active().move_to(target_deg, max_dps, accel_dps2)

    async def halt(self) -> None:
        await self._active().halt()

    async def emergency_stop(self) -> None:
        await self._active().emergency_stop()

    async def release(self) -> None:
        await self._active().release()

    async def set_zero(self) -> None:
        await self._active().set_zero()
