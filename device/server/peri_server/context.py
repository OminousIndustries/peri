"""Application context: builds and owns every service, and implements the cross-cutting settings side effects."""
from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple

from .catalog import Catalog, CatalogSource
from .config import ConfigError, ServerConfig, device_id
from .head import CalibrationStore, HeadController, HeadLimits
from .head.drivers import HeadDriver, build_driver
from .hub import Hub
from .openai_client import OpenAIClient, RealtimeService, ReachabilityCache
from .session import RuntimeFacts, build_session, collect_runtime_facts
from .settings import DynamicEnum, SettingsSchema, SettingsStore
from .system.audio import AudioManager
from .system.display import Backlight
from .system.info import SystemInfo
from .system.platform import is_raspberry_pi
from .system.power import PowerManager
from .system.runner import CommandRunner
from .util import TokenBucket
from .constants import CLIENT_LOG_RATE, SESSION_BURST, SESSION_RATE

log = logging.getLogger("peri.app")


class Context:
    """One per process. Tests build it with fakes (runner, driver, clock, fs_root, is_pi)."""

    def __init__(self, cfg: ServerConfig, *, runner: Optional[CommandRunner] = None, driver: Optional[HeadDriver] = None,
                 clock: Optional[Any] = None, fs_root: Path = Path("/"), is_pi: Optional[bool] = None) -> None:
        self.cfg = cfg
        self.is_pi = is_raspberry_pi() if is_pi is None else is_pi
        self.device_id = device_id()
        self.runner = runner or CommandRunner()

        self._catalog_source = CatalogSource(cfg.config_dir)
        try:
            defaults = json.loads((cfg.config_dir / "settings.default.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ConfigError(f"cannot read {cfg.config_dir / 'settings.default.json'}: {exc}") from exc
        try:
            cfg.state_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise ConfigError(f"cannot create the state directory {cfg.state_dir}: {exc}") from exc
        schema = SettingsSchema(defaults, {"persona": DynamicEnum(lambda: self.catalog.persona_ids)})
        self.settings = SettingsStore(cfg.state_dir / "settings.json", schema)

        self.hub = Hub()
        self.openai = OpenAIClient(cfg.openai_api_key, cfg.openai_base_url) if cfg.openai_configured else None
        self.reach = ReachabilityCache(self.openai)
        self.realtime = RealtimeService(self.openai)

        limits = HeadLimits(cfg.head_max_speed_dps, cfg.head_accel_dps2, cfg.head_hard_limit_deg, cfg.head_release_after_s)
        self.head = HeadController(driver or build_driver(cfg, self.is_pi, clock), self.settings.peek, limits,
                                   CalibrationStore(cfg.state_dir / "calibration.json"), clock)
        self.head.add_listener(self._broadcast_head_state)

        #: only the real device may change volume / brightness / default audio device (see PERI_HW_CONTROL)
        self.hw_control = self.is_pi if cfg.hw_control is None else cfg.hw_control
        self.audio = AudioManager(self.runner, control=self.hw_control)
        self.backlight = Backlight(self.runner, str(fs_root / "sys") if str(fs_root) != "/" else "/sys",
                                   control=self.hw_control)
        self.power = PowerManager(self.runner, enabled=self.is_pi, before_shutdown=self.head.park)
        self.info = SystemInfo(cfg, self.runner, self.audio, self.backlight, self.reach, self.head.state,
                               self.head.status_detail, lambda: self.hub.count, fs_root, self.is_pi)
        self.client_log_bucket = TokenBucket(CLIENT_LOG_RATE, CLIENT_LOG_RATE)
        self.session_bucket = TokenBucket(SESSION_RATE, SESSION_BURST)
        self._tasks: List["asyncio.Task[None]"] = []

    def _broadcast_head_state(self, state: Dict[str, Any]) -> None:
        self.hub.broadcast({"t": "head.state", **state})

    @property
    def catalog(self) -> Catalog:
        """Personas + tools (re-read from config/ when the files change)."""
        return self._catalog_source.get()

    # ------------------------------------------------------------------------------------------- lifecycle
    async def start(self) -> None:
        try:
            await self.head.start()
        except Exception:
            log.exception("head controller failed to start; continuing without a working neck")
        if self.openai is not None:
            self.reach.refresh_if_stale()
        self._tasks.append(asyncio.ensure_future(self._bootstrap_hardware()))

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        await self.hub.close_all()
        try:
            await asyncio.wait_for(self.head.shutdown(center=True), 10.0)
        except Exception:
            log.exception("error while shutting down the head controller")
        await self.reach.stop()
        if self.openai is not None:
            await self.openai.close()

    async def _bootstrap_hardware(self) -> None:
        """Apply the saved volume/brightness once the sound server and backlight are ready (retries while they start).

        Order: pin the WM8960 as default device first (so the volume lands on the right sink); if it cannot be pinned
        (card absent, plain ALSA) apply the volume anyway after a few attempts. The volume is applied exactly once.
        """
        if not self.hw_control:
            log.info("hardware control disabled (not a Raspberry Pi): volume/brightness are left alone")
            return
        try:
            settings = self.settings.current
            pinned = False
            for attempt in range(10):
                backend = await self.audio.backend()
                if backend is None:
                    break
                if not pinned and backend.name != "alsa":
                    pinned = await self.audio.pin_default_devices(attempts=1, delay=0)
                if pinned or backend.name == "alsa" or attempt >= 2:
                    if await self.audio.set(level=settings["audio"]["volume"], muted=False) is not None:
                        break
                await asyncio.sleep(3.0)
            if self.backlight.supported:
                await self.backlight.set(settings["display"]["brightness"])
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("could not apply saved hardware settings")

    # --------------------------------------------------------------------------------------- session helpers
    @property
    def body_can_move(self) -> bool:
        return self.head.body_can_move()

    def runtime_facts(self) -> RuntimeFacts:
        return collect_runtime_facts(self.device_id, self.body_can_move)

    def session_builder(self, overrides: Optional[Mapping[str, Any]]) -> Tuple[Dict[str, Any], Callable[[bool], Dict[str, Any]]]:
        """``(merged settings, build(include_reasoning) -> session object)``; raises SettingsError for bad overrides."""
        merged = self.settings.with_overrides(overrides)
        facts = self.runtime_facts()
        return merged, lambda include_reasoning: build_session(merged, self.catalog, facts, include_reasoning)

    # -------------------------------------------------------------------------------------------- settings
    async def update_settings(self, patch: Mapping[str, Any]) -> Dict[str, Any]:
        """Validate, persist, apply side effects (volume, brightness, head) and broadcast ``settings.changed``."""
        new, _old, changed = await self.settings.update(patch)
        if changed:
            self.hub.broadcast({"t": "settings.changed", "settings": new})      # first: the UI updates immediately
            await self._apply_side_effects(new, changed)
        return new

    async def _apply_side_effects(self, new: Mapping[str, Any], changed: List[str]) -> None:
        try:
            if "audio.volume" in changed:
                state = await self.audio.set(level=new["audio"]["volume"])
                if state is not None:
                    self.hub.broadcast({"t": "system.volume", "volume": state[0], "muted": state[1]})
            if "display.brightness" in changed and self.backlight.supported:
                await self.backlight.set(new["display"]["brightness"])
            if any(path.startswith("head.") for path in changed):
                await self.head.on_settings_changed(changed)
        except Exception:
            log.exception("settings were saved but applying them failed")
