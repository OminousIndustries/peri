"""Backlight brightness: sysfs (``/sys/class/backlight/*``, Waveshare legacy ``/sys/waveshare/rpi_backlight``) or brightnessctl."""
from __future__ import annotations

import glob
import logging
import os
from typing import List, Optional, Tuple

from .runner import CommandRunner

log = logging.getLogger("peri.display")

LEGACY_WAVESHARE = "/sys/waveshare/rpi_backlight/brightness"


class Backlight:
    def __init__(self, runner: Optional[CommandRunner] = None, sys_root: str = "/sys", control: bool = True) -> None:
        self.runner = runner or CommandRunner()
        self.control = control          # False = read-only (development machines never dim the host's screen)
        self.root = sys_root.rstrip("/")
        self._brightnessctl_failed = False

    def _files(self) -> List[Tuple[str, int]]:
        """``(brightness file, max value)`` for every backlight found, class devices first."""
        found: List[Tuple[str, int]] = []
        for path in sorted(glob.glob(f"{self.root}/class/backlight/*/brightness")):
            maximum = self._read_int(os.path.join(os.path.dirname(path), "max_brightness"), 255)
            found.append((path, max(1, maximum)))
        legacy = f"{self.root}{LEGACY_WAVESHARE[len('/sys'):]}"
        if os.path.exists(legacy):
            found.append((legacy, self._read_int(os.path.join(os.path.dirname(legacy), "max_brightness"), 255)))
        return found

    @staticmethod
    def _read_int(path: str, default: int) -> int:
        try:
            with open(path, encoding="utf-8") as fh:
                return int(fh.read().strip())
        except (OSError, ValueError):
            return default

    @property
    def supported(self) -> bool:
        if not self.control:
            return False
        return bool(self._files()) or (not self._brightnessctl_failed and self.runner.which("brightnessctl") is not None)

    async def get(self) -> Optional[int]:
        """Current brightness in percent, or None when unknown."""
        for path, maximum in self._files():
            raw = self._read_int(path, -1)
            if raw >= 0:
                return int(round(raw * 100 / maximum))
        if self.runner.which("brightnessctl"):
            res = await self.runner.run(["brightnessctl", "-m"])
            fields = res.stdout.strip().split(",")
            if res.ok and len(fields) >= 4 and fields[3].endswith("%"):
                try:
                    return int(fields[3].rstrip("%"))
                except ValueError:
                    return None
        return None

    async def set(self, percent: int) -> bool:
        if not self.control:
            return False
        percent = max(0, min(100, int(percent)))
        for path, maximum in self._files():
            raw = max(1, int(round(percent * maximum / 100))) if percent > 0 else 0
            try:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(str(raw))
                return True
            except OSError as exc:
                log.warning("cannot write %s (%s); the peri user needs write access (udev rule / hw-init)", path, exc.strerror)
        if self.runner.which("brightnessctl"):
            res = await self.runner.run(["brightnessctl", "set", f"{percent}%"])
            if res.ok:
                return True
            self._brightnessctl_failed = True
        return False
