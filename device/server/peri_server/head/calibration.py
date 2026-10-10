"""Neck calibration state, persisted in ``$PERI_STATE_DIR/calibration.json``.

There is no limit switch or position sensor. The neck is assumed to be centred (by hand) at power-up; the last known angle
is remembered across restarts (the Nano resets whenever the serial port opens, which loses its position but not the
head's), and ``zero`` lets the installer declare the current position to be 0 degrees.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from ..util import atomic_write_json, read_json

log = logging.getLogger("peri.head")


@dataclass
class Calibration:
    angle_deg: float = 0.0           # last known angle (at rest / at shutdown), degrees, calibrated frame
    zeroed: bool = False             # True once someone declared a position to be 0 (or the head was centred by ``settle``)
    zeroed_at: Optional[str] = None  # ISO timestamp of the last ``zero``


class CalibrationStore:
    """Load/save with a small dead-band so the SD card is not rewritten for tiny changes."""

    MIN_DELTA_DEG = 0.05

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.data = Calibration()
        self._saved_angle: Optional[float] = None
        self.load()

    def load(self) -> None:
        raw = read_json(self.path)
        if not isinstance(raw, dict):
            if self.path.exists():
                log.warning("%s is unreadable; assuming the neck is centred", self.path)
            return
        try:
            self.data = Calibration(
                angle_deg=float(raw.get("angle_deg", 0.0)),
                zeroed=bool(raw.get("zeroed", False)),
                zeroed_at=raw.get("zeroed_at"),
            )
            self._saved_angle = self.data.angle_deg
        except (TypeError, ValueError):
            log.warning("%s has invalid content; assuming the neck is centred", self.path)

    def save(self, force: bool = False) -> None:
        if not force and self._saved_angle is not None and abs(self.data.angle_deg - self._saved_angle) < self.MIN_DELTA_DEG:
            return
        payload = {"version": 1, "angle_deg": round(self.data.angle_deg, 3), "zeroed": self.data.zeroed,
                   "zeroed_at": self.data.zeroed_at}
        try:
            atomic_write_json(self.path, payload, mode=0o644)
            self._saved_angle = self.data.angle_deg
        except OSError as exc:
            log.warning("cannot save %s: %s", self.path, exc)

    def remember_angle(self, angle_deg: float) -> None:
        self.data.angle_deg = float(angle_deg)
        self.save()

    def mark_zeroed(self) -> None:
        self.data.angle_deg = 0.0
        self.data.zeroed = True
        self.data.zeroed_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
        self.save(force=True)
