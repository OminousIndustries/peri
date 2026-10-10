"""Gesture plans (docs/API.md section 4).

Notation: ``a`` = current angle, ``L`` = soft limit in degrees, ``k`` = gesture intensity x settings.head.intensity.
Every target is clamped to +-L. Durations are *nominal*: ``schedule`` stretches any leg the neck cannot perform that fast
(speed and acceleration limits), so the physical minimum always wins.

Interpretation notes: ``look_around`` and ``wake`` use absolute angles around the centre (they are written without ``a`` in
the API table; at rest near 0 the difference does not matter), ``settle`` and ``sleep`` go to 0, everything else is
relative to ``a``.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Sequence, Tuple

from ..constants import GESTURES
from ..util import clamp
from .profile import cruise_speed_for_duration

MIN_LEG_DEG = 0.05  # moves shorter than this are skipped (below one motor step's noise)


@dataclass(frozen=True)
class Waypoint:
    """One leg: move to ``target`` (absolute degrees) in about ``duration`` s, then wait ``hold`` s."""

    target: float
    duration: float
    hold: float = 0.0


@dataclass(frozen=True)
class GesturePlan:
    name: str
    waypoints: Tuple[Waypoint, ...]
    release_at_end: bool = False   # `sleep`: de-energise the coils once centred


@dataclass(frozen=True)
class ScheduledLeg:
    target: float
    speed_dps: float     # cruise speed to command
    duration: float      # planned seconds for the move (>= nominal, stretched when necessary)
    hold: float


def plan_gesture(name: str, angle: float, limit: float, k: float) -> GesturePlan:
    """Waypoints for a gesture. Raises ``KeyError`` for an unknown name."""
    if name not in GESTURES:
        raise KeyError(name)
    L = float(limit)
    k = clamp(float(k), 0.0, 1.0)
    a = float(angle)

    def wp(target: float, duration: float, hold: float = 0.0) -> Waypoint:
        return Waypoint(clamp(target, -L, L), duration, hold)

    if name == "shake_no":
        legs = [wp(a + 0.45 * L * k, 0.5), wp(a - 0.45 * L * k, 0.5), wp(a + 0.35 * L * k, 0.5),
                wp(a - 0.2 * L * k, 0.5), wp(a, 0.5)]
    elif name == "perk_up":
        legs = [wp(a + 0.3 * L * k, 0.6, 0.3), wp(a, 0.9)]
    elif name == "look_around":
        legs = [wp(-0.9 * L * k, 2.0, 0.6), wp(0.9 * L * k, 3.5, 0.6), wp(a, 2.0)]
    elif name == "ponder":
        legs = [wp(a + 0.5 * L * k, 1.8)]
    elif name in ("settle", "sleep"):
        legs = [wp(0.0, clamp(abs(a) / 6.0, 0.6, 3.0))]
    else:  # wake
        legs = [wp(0.25 * L * k, 0.5), wp(-0.15 * L * k, 0.6), wp(0.0, 0.5)]
    return GesturePlan(name, tuple(legs), release_at_end=(name == "sleep"))


def schedule(start_angle: float, waypoints: Sequence[Waypoint], max_speed: float, accel: float) -> List[ScheduledLeg]:
    """Turn nominal legs into commandable ones and return them with their real (possibly stretched) durations."""
    legs: List[ScheduledLeg] = []
    here = start_angle
    for point in waypoints:
        distance = abs(point.target - here)
        if distance < MIN_LEG_DEG:
            legs.append(ScheduledLeg(point.target, max_speed, 0.0, point.hold))
        else:
            speed, duration = cruise_speed_for_duration(distance, point.duration, max_speed, accel)
            legs.append(ScheduledLeg(point.target, speed, max(duration, 0.0), point.hold))
        here = point.target
    return legs


def total_duration(legs: Sequence[ScheduledLeg]) -> float:
    return sum(leg.duration + leg.hold for leg in legs)
