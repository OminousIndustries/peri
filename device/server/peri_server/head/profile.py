"""Closed-form trapezoid profile math (degrees). Used for ETA estimates and to plan time-constrained gesture legs."""
from __future__ import annotations

import math
from typing import Tuple


def trapezoid_time(distance: float, vmax: float, accel: float) -> float:
    """Seconds for a rest-to-rest move of ``|distance|`` with cruise speed ``vmax`` and acceleration ``accel``."""
    d = abs(distance)
    if d <= 0.0:
        return 0.0
    vmax = max(vmax, 1e-9)
    accel = max(accel, 1e-9)
    if d <= vmax * vmax / accel:                     # never reaches cruise speed: triangular profile
        return 2.0 * math.sqrt(d / accel)
    return d / vmax + vmax / accel


def cruise_speed_for_duration(distance: float, duration: float, vmax: float, accel: float) -> Tuple[float, float]:
    """Cruise speed that makes a rest-to-rest move take ``duration`` seconds, limited by ``vmax`` and ``accel``.

    Returns ``(speed, actual_duration)``. If the request is faster than physically possible the leg is *stretched*:
    the result is ``(vmax, trapezoid_time(...))``.
    """
    d = abs(distance)
    fastest = trapezoid_time(d, vmax, accel)
    if d <= 0.0:
        return vmax, 0.0
    if duration <= fastest:
        return vmax, fastest
    # d = v*T - v^2/a  ->  v = a*(T - sqrt(T^2 - 4d/a))/2   (smaller root; real because T > fastest >= 2*sqrt(d/a))
    disc = max(0.0, duration * duration - 4.0 * d / accel)
    speed = accel * (duration - math.sqrt(disc)) / 2.0
    return min(speed, vmax), duration
