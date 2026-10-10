"""HeadController: the neck as the rest of the server sees it (docs/API.md section 4).

Frames: drivers report degrees relative to *their* zero (the position at connect / last ``set_zero``). The controller keeps
``base`` so that ``angle = base + driver_position`` is the calibrated neck angle (0 = facing straight ahead, positive = the
head's right). When a driver (re)connects its zero is wherever the neck happens to be, so ``base`` is set to the last known
angle (persisted in calibration.json) - the neck is assumed not to move while the server is down.
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Mapping, Optional

from ..errors import ApiError
from ..util import clamp
from .calibration import CalibrationStore
from .clock import RealClock
from .drivers.base import DriverState, HeadDriver
from .gestures import MIN_LEG_DEG, ScheduledLeg, plan_gesture, schedule, total_duration
from .profile import trapezoid_time

log = logging.getLogger("peri.head")

NUDGE_SPEED_DPS = 6.0        # calibration nudges are deliberately slow
MIN_SPEED_DPS = 0.5
POLL_S = 0.02                # how often a gesture leg checks whether the driver has finished


@dataclass(frozen=True)
class HeadLimits:
    """Static motion limits from the environment (docs/API.md section 8)."""

    max_speed_dps: float = 16.0
    accel_dps2: float = 40.0
    hard_limit_deg: float = 25.0
    release_after_s: float = 2.5


StateListener = Callable[[Dict[str, Any]], None]


class HeadController:
    def __init__(self, driver: HeadDriver, settings: Callable[[], Mapping[str, Any]], limits: HeadLimits,
                 calibration: CalibrationStore, clock: Optional[Any] = None) -> None:
        self.driver = driver
        self._settings = settings
        self.limits = limits
        self.calibration = calibration
        self._clock = clock if clock is not None else RealClock()
        self._base = 0.0
        self._last_angle = calibration.data.angle_deg
        self._cmd_target: Optional[float] = None    # last commanded target (calibrated frame), echoed while moving
        self._epoch = -1
        self._was_moving = False
        self._seq: Optional["asyncio.Task[None]"] = None
        self._release_task: Optional["asyncio.Task[None]"] = None
        self._listeners: List[StateListener] = []
        self._unsubscribe: Optional[Callable[[], None]] = None
        self._closing = False

    # ------------------------------------------------------------------------------------------- lifecycle
    async def start(self) -> None:
        self._unsubscribe = self.driver.subscribe(self._on_driver_state)
        await self.driver.start()
        self._track(self.driver.snapshot())

    async def park(self, center: bool = True) -> None:
        """Stop motion, optionally re-centre the neck (so the next power-up really starts centred) and release the coils."""
        await self._cancel_sequence()
        self._cancel_release()
        try:
            state = self.driver.snapshot()
            if center and state.connected and not state.error and self._enabled() and abs(self.angle) > 0.5:
                log.info("centring the neck (%.1f deg)", self.angle)
                travel = abs(self.angle)
                await self._move_abs(0.0, self.limits.max_speed_dps)
                await self._wait_idle(timeout=trapezoid_time(travel, self.limits.max_speed_dps, self.limits.accel_dps2) + 3.0)
            if state.connected:
                await self.driver.release()
        except Exception:
            log.exception("error while parking the neck")
        self.calibration.remember_angle(self.angle)

    async def shutdown(self, center: bool = True) -> None:
        """Park the neck and close the driver."""
        self._closing = True
        await self.park(center)
        if self._unsubscribe is not None:
            self._unsubscribe()
        await self.driver.stop()

    def add_listener(self, callback: StateListener) -> Callable[[], None]:
        """Callback with the public state dict (~10 Hz while moving, once when a move ends, on connect changes)."""
        self._listeners.append(callback)
        return lambda: self._listeners.remove(callback) if callback in self._listeners else None

    # ---------------------------------------------------------------------------------------------- state
    def _enabled(self) -> bool:
        return bool(self._settings().get("head", {}).get("enabled", True))

    @property
    def soft_limit(self) -> float:
        configured = float(self._settings().get("head", {}).get("limit_deg", 20))
        return min(configured, self.limits.hard_limit_deg)

    @property
    def angle(self) -> float:
        return self._base + self.driver.snapshot().position_deg

    def _target(self, state: Optional[DriverState] = None) -> float:
        """Where the neck is heading: the commanded target while moving (not the step-quantised one), else its angle."""
        st = state or self.driver.snapshot()
        if st.moving and self._cmd_target is not None:
            return self._cmd_target
        return self._base + st.target_deg

    def state(self) -> Dict[str, Any]:
        st = self.driver.snapshot()
        limit = self.soft_limit
        return {
            "driver": self.driver.name, "connected": st.connected, "angle": round(self._base + st.position_deg, 2),
            "target": round(self._target(st), 2), "moving": st.moving, "energized": st.energised,
            "limits": {"min": -limit, "max": limit}, "max_speed_dps": self.limits.max_speed_dps,
            "accel_dps2": self.limits.accel_dps2, "zeroed": self.calibration.data.zeroed, "error": st.error,
        }

    def status_detail(self) -> str:
        """Human hint about the driver (serial port, scanning, ...) for /api/diag."""
        return self.driver.snapshot().detail

    def body_can_move(self) -> bool:
        st = self.driver.snapshot()
        return self._enabled() and st.connected and not st.error

    def _ignored(self, reason: str) -> Dict[str, Any]:
        out = self.state()
        out["ignored"] = reason
        return out

    def _guard(self) -> Optional[str]:
        if not self._enabled():
            return "disabled"
        st = self.driver.snapshot()
        if st.error:
            return "error"
        if not st.connected:
            return "unavailable"
        return None

    # ------------------------------------------------------------------------- driver events / bookkeeping
    def _track(self, st: DriverState) -> None:
        """Keep the calibrated frame consistent across driver (re)connects and firmware resets."""
        if st.connected and st.epoch != self._epoch:
            self._epoch = st.epoch
            self._base = self._last_angle - st.position_deg
            log.info("head reference (re)established: neck assumed at %.1f deg", self._last_angle)
        elif st.connected:
            self._last_angle = self._base + st.position_deg

    def _on_driver_state(self, st: DriverState) -> None:
        self._track(st)
        if self._was_moving and not st.moving and not self._closing:
            self._on_motion_end()
        self._was_moving = st.moving
        if self._listeners:
            snapshot = self.state()
            for callback in list(self._listeners):
                try:
                    callback(snapshot)
                except Exception:
                    log.exception("head state listener failed")

    def _on_motion_end(self) -> None:
        self.calibration.remember_angle(self._last_angle)
        self._schedule_release()

    # ------------------------------------------------------------------------------- coil auto-release
    def _cancel_release(self) -> None:
        task, self._release_task = self._release_task, None
        if task is not None and not task.done():
            task.cancel()

    def _schedule_release(self) -> None:
        self._cancel_release()
        self._release_task = asyncio.ensure_future(self._release_after())

    async def _release_after(self) -> None:
        try:
            await self._clock.sleep(self.limits.release_after_s)
            if not self.driver.snapshot().moving:
                await self.driver.release()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("coil auto-release failed")

    # ------------------------------------------------------------------------------- sequences / helpers
    async def _cancel_sequence(self) -> None:
        task, self._seq = self._seq, None
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

    async def _move_abs(self, target: float, speed: float) -> None:
        """Command an absolute (calibrated) target; the driver retargets smoothly if it is already moving."""
        self._cancel_release()
        speed = clamp(speed, MIN_SPEED_DPS, self.limits.max_speed_dps)
        self._cmd_target = target
        await self.driver.move_to(target - self._base, speed, self.limits.accel_dps2)

    async def _wait_idle(self, timeout: float) -> bool:
        waited = 0.0
        while self.driver.snapshot().moving:
            if waited >= timeout:
                return False
            await self._clock.sleep(POLL_S)
            waited += POLL_S
        return True

    async def _run_legs(self, legs: List[ScheduledLeg], release_at_end: bool) -> None:
        try:
            for leg in legs:
                if leg.duration > 0.0:
                    await self._move_abs(leg.target, leg.speed_dps)
                    await self._wait_idle(leg.duration + 3.0)
                if leg.hold > 0.0:
                    await self._clock.sleep(leg.hold)
            if release_at_end:
                await self.driver.release()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("head gesture aborted")

    def _reference(self) -> float:
        """Where relative commands start from: the current target while a move is in progress, else the angle."""
        st = self.driver.snapshot()
        return self._target(st) if st.moving else self._base + st.position_deg

    # ----------------------------------------------------------------------------------------- commands
    async def move(self, angle: float, speed_dps: Optional[float] = None, relative: bool = False) -> Dict[str, Any]:
        """``POST /api/head/move``: target clamped to the soft limits, returns immediately with an ETA."""
        blocked = self._guard()
        if blocked:
            return self._ignored(blocked)
        await self._cancel_sequence()
        limit = self.soft_limit
        current = self.angle
        target = clamp((self._reference() + angle) if relative else angle, -limit, limit)
        speed = self.limits.max_speed_dps if speed_dps is None else speed_dps
        speed = clamp(speed, MIN_SPEED_DPS, self.limits.max_speed_dps)
        if abs(target - current) >= MIN_LEG_DEG or self.driver.snapshot().moving:
            await self._safe(self._move_abs(target, speed))
        eta = trapezoid_time(abs(target - current), speed, self.limits.accel_dps2)
        out = self.state()
        out["eta_ms"] = int(round(eta * 1000))
        return out

    async def gesture(self, name: str, intensity: float = 1.0) -> Dict[str, Any]:
        """``POST /api/head/gesture``: queue a gesture (see gestures.py); a new command preempts a running one."""
        blocked = self._guard()
        if blocked:
            return self._ignored(blocked)
        await self._cancel_sequence()
        k = clamp(float(intensity), 0.0, 1.0) * float(self._settings().get("head", {}).get("intensity", 0.7))
        plan = plan_gesture(name, self.angle, self.soft_limit, k)      # KeyError for unknown names (route maps it to 400)
        legs = schedule(self.angle, plan.waypoints, self.limits.max_speed_dps, self.limits.accel_dps2)
        self._seq = asyncio.ensure_future(self._run_legs(legs, plan.release_at_end))
        out = self.state()
        out["duration_ms"] = int(round(total_duration(legs) * 1000))
        return out

    async def nudge(self, delta_deg: float) -> Dict[str, Any]:
        """``POST /api/head/nudge``: small slow relative move that ignores the soft limit (up to the hard limit)."""
        blocked = self._guard()
        if blocked:
            return self._ignored(blocked)
        await self._cancel_sequence()
        hard = self.limits.hard_limit_deg
        target = clamp(self._reference() + delta_deg, -hard, hard)
        await self._safe(self._move_abs(target, min(NUDGE_SPEED_DPS, self.limits.max_speed_dps)))
        return self.state()

    async def stop(self) -> Dict[str, Any]:
        """``POST /api/head/stop``: decelerate to a stop now (allowed even when the head is disabled)."""
        await self._cancel_sequence()
        self._cmd_target = None
        if self.driver.snapshot().connected:
            await self._safe(self.driver.halt())
        return self.state()

    async def release(self) -> Dict[str, Any]:
        """``POST /api/head/release``: stop (if moving) and de-energise the coils."""
        await self._cancel_sequence()
        self._cmd_target = None
        if self.driver.snapshot().connected:
            await self._safe(self.driver.halt())
            await self._wait_idle(3.0)
            self._cancel_release()
            await self._safe(self.driver.release())
        return self.state()

    async def zero(self) -> Dict[str, Any]:
        """``POST /api/head/zero``: the current physical position becomes 0 degrees (persisted)."""
        st = self.driver.snapshot()
        if not st.connected:
            return self._ignored("unavailable")
        await self._cancel_sequence()
        if st.moving:
            await self._safe(self.driver.halt())
            if not await self._wait_idle(3.0):
                raise ApiError(409, "head_busy", "the neck is still moving; try again in a moment")
        await self._safe(self.driver.set_zero())
        self._base = 0.0
        self._last_angle = 0.0
        self._epoch = self.driver.snapshot().epoch
        self.calibration.mark_zeroed()
        log.info("neck position declared to be 0 degrees")
        self._on_driver_state(self.driver.snapshot())
        return self.state()

    async def on_settings_changed(self, changed: List[str]) -> None:
        """Called after a settings update: switching the head off stops and releases it."""
        if "head.enabled" in changed and not self._enabled():
            await self._cancel_sequence()
            if self.driver.snapshot().connected:
                await self._safe(self.driver.halt())
                await self._wait_idle(3.0)
                await self._safe(self.driver.release())

    async def _safe(self, coro: Any) -> None:
        """Run a driver call; a link problem must never turn into an HTTP 500 (the state reports it)."""
        try:
            await coro
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.warning("head driver command failed: %s", exc)
