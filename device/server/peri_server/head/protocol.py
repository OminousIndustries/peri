"""Serial protocol v1 codec, device -> host direction (see ``firmware/README.md``). Used by the serial driver."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Union

PROTOCOL_VERSION = 1
BANNER_PREFIX = "PERI-HEAD"


@dataclass(frozen=True)
class Banner:
    version: int
    half_steps_per_rev: int
    extra: str = ""


@dataclass(frozen=True)
class PState:
    pos: int
    target: int
    moving: bool
    energised: bool


@dataclass(frozen=True)
class Err:
    code: str


@dataclass(frozen=True)
class Unknown:
    line: str


Message = Union[Banner, PState, Err, Unknown]


def format_move(target: int, vmax: int, accel: int) -> str:
    return f"T {int(target)} {int(vmax)} {int(accel)}"


def parse_line(line: str) -> Message:
    """Parse one device -> host line."""
    text = line.strip()
    parts = text.split()
    if not parts:
        return Unknown(text)
    head = parts[0]
    try:
        if head == BANNER_PREFIX and len(parts) >= 4 and parts[3] == "READY":
            return Banner(int(parts[1]), int(parts[2]), " ".join(parts[4:]))
        if head == "P" and len(parts) == 5:
            return PState(int(parts[1]), int(parts[2]), parts[3] == "1", parts[4] == "1")
        if head == "ERR" and len(parts) >= 2:
            return Err(parts[1])
    except ValueError:
        pass
    return Unknown(text)
