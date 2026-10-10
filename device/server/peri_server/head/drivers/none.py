"""Driver for 'no head attached': always disconnected, every command is a no-op."""
from __future__ import annotations

from .base import DriverState, HeadDriver


class NoneDriver(HeadDriver):
    name = "none"

    def snapshot(self) -> DriverState:
        return DriverState(driver="none", connected=False, epoch=0, detail="no head hardware configured or detected")

    async def move_to(self, target_deg: float, max_dps: float, accel_dps2: float) -> None:
        return None

    async def halt(self) -> None:
        return None

    async def emergency_stop(self) -> None:
        return None

    async def release(self) -> None:
        return None

    async def set_zero(self) -> None:
        return None
