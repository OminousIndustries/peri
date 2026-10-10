"""ULN2003 + 28BYJ-48 driven straight from Raspberry Pi GPIO (secondary option; the Nano over USB is preferred).

Only enabled with ``PERI_HEAD_DRIVER=gpio``: nothing here touches a pin unless this driver is explicitly started. The stepping
runs in its own thread with ``time.perf_counter`` scheduling (busy-wait for the last ~0.3 ms); Python cannot match the
Arduino's jitter, which is why the serial driver is the default recommendation.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, List, Optional, Sequence

from ..stepgen import HALF_STEP_TABLE
from .base import DriverState, StepScale
from .stepped import SteppedDriver

log = logging.getLogger("peri.head")

SPIN_MARGIN_S = 0.0003


class GpioDriver(SteppedDriver):
    name = "gpio"

    def __init__(self, scale: StepScale, pins: Sequence[int], pin_factory: Optional[Any] = None,
                 clock: Optional[Any] = None, perf_counter: Any = time.perf_counter, sleep: Any = time.sleep) -> None:
        from ..clock import RealClock

        super().__init__(scale, clock if clock is not None else RealClock(), on_coils=self._write_coils)
        if len(pins) != 4:
            raise ValueError("GPIO driver needs exactly four pins (IN1..IN4)")
        self._pins_spec = tuple(int(p) for p in pins)
        self._pin_factory = pin_factory
        self._perf = perf_counter
        self._sleep = sleep
        self._outputs: List[Any] = []
        self._levels = [0, 0, 0, 0]
        self._thread: Optional[threading.Thread] = None
        self._wake = threading.Event()
        self._stop_thread = threading.Event()
        self._error: Optional[str] = None

    # -- hardware ----------------------------------------------------------------------------------------------
    def _open_pins(self) -> None:
        try:
            from gpiozero import OutputDevice  # imported lazily: only needed when this driver is selected
        except ImportError as exc:
            raise RuntimeError("PERI_HEAD_DRIVER=gpio needs python3-gpiozero (sudo apt install python3-gpiozero python3-lgpio)") from exc
        kwargs = {"pin_factory": self._pin_factory} if self._pin_factory is not None else {}
        self._outputs = [OutputDevice(pin, initial_value=False, **kwargs) for pin in self._pins_spec]
        self._levels = [0, 0, 0, 0]

    def _write_coils(self, position: int, energised: bool) -> None:
        pattern = HALF_STEP_TABLE[position & 7] if energised else (0, 0, 0, 0)
        for index, (device, level) in enumerate(zip(self._outputs, pattern)):
            if self._levels[index] != level:
                device.value = level
                self._levels[index] = level

    def _now(self) -> float:
        return self._perf()

    def _kick(self) -> None:
        self._wake.set()

    # -- lifecycle ---------------------------------------------------------------------------------------------
    async def start(self) -> None:
        if self._started:
            return
        try:
            self._open_pins()
        except Exception as exc:
            self._error = f"cannot open GPIO pins {list(self._pins_spec)}: {exc}"
            log.error(self._error)
            self._started = True   # stay 'started' so the ticker reports the error state
            self._epoch += 1
            self._emit()
            return
        self._stop_thread.clear()
        self._thread = threading.Thread(target=self._step_loop, name="peri-gpio-stepper", daemon=True)
        self._thread.start()
        await super().start()
        log.info("GPIO head driver on BCM pins %s", list(self._pins_spec))

    async def stop(self) -> None:
        self._stop_thread.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        self._core.emergency_stop()
        self._core.release()
        for device in self._outputs:
            try:
                device.close()
            except Exception:
                log.debug("closing GPIO pin failed", exc_info=True)
        self._outputs = []
        await super().stop()

    def _step_loop(self) -> None:
        core = self._core
        while not self._stop_thread.is_set():
            due = core.next_due()
            if due is None:
                self._wake.wait(0.05)
                self._wake.clear()
                continue
            wait = due - self._perf()
            if wait > SPIN_MARGIN_S * 2:
                self._sleep(min(wait - SPIN_MARGIN_S, 0.02))
                continue
            while self._perf() < due and not self._stop_thread.is_set():
                pass
            core.advance(self._perf())

    # -- state -------------------------------------------------------------------------------------------------
    def snapshot(self) -> DriverState:
        if self._error:
            return DriverState(driver="gpio", connected=False, epoch=self._epoch, error=self._error,
                               detail=f"BCM pins {list(self._pins_spec)}")
        return self._state("gpio", detail=f"BCM pins {list(self._pins_spec)}")
