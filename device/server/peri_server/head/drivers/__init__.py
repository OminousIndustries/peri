"""Head drivers and the factory that picks one from the configuration."""
from __future__ import annotations

from typing import Any, Optional

from ...config import ServerConfig
from .auto import AutoDriver
from .base import DriverState, HeadDriver, StepScale
from .gpio import GpioDriver
from .none import NoneDriver
from .serial_driver import SerialDriver
from .sim import SimDriver

__all__ = ["AutoDriver", "DriverState", "GpioDriver", "HeadDriver", "NoneDriver", "SerialDriver", "SimDriver", "StepScale",
           "build_driver"]


def build_driver(cfg: ServerConfig, is_pi: bool, clock: Optional[Any] = None) -> HeadDriver:
    """``auto`` = serial when a Peri Nano answers (hot-plug aware), else the simulator off-Pi / in dev, else none."""
    scale = StepScale(cfg.steps_per_deg, cfg.head_invert)
    choice = cfg.head_driver
    if choice == "none":
        return NoneDriver()
    if choice == "sim":
        return SimDriver(scale, clock)
    if choice == "gpio":
        return GpioDriver(scale, cfg.head_gpio_pins)
    if choice == "serial":
        return SerialDriver(scale, cfg.head_serial_port)
    fallback: HeadDriver = SimDriver(scale, clock) if (cfg.dev or not is_pi) else NoneDriver()
    return AutoDriver(SerialDriver(scale, cfg.head_serial_port), fallback)
