"""Time source abstraction so motion code can be tested deterministically (tests supply a virtual clock)."""
from __future__ import annotations

import asyncio
import time


class RealClock:
    """Monotonic wall-clock time with real sleeping."""

    def now(self) -> float:
        return time.monotonic()

    async def sleep(self, seconds: float) -> None:
        await asyncio.sleep(max(0.0, seconds))
