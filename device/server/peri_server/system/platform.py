"""Where are we running? (Raspberry Pi vs a development machine)."""
from __future__ import annotations

import functools
from pathlib import Path
from typing import Optional


@functools.lru_cache(maxsize=1)
def pi_model() -> Optional[str]:
    """e.g. 'Raspberry Pi 4 Model B Rev 1.4', or None when not a Pi."""
    for path in ("/proc/device-tree/model", "/sys/firmware/devicetree/base/model"):
        try:
            text = Path(path).read_bytes().decode("utf-8", "replace").strip("\x00\n ")
        except OSError:
            continue
        if text.startswith("Raspberry Pi"):
            return text
    return None


def is_raspberry_pi() -> bool:
    return pi_model() is not None
