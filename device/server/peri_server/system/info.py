"""``GET /api/system/status`` and ``GET /api/diag``."""
from __future__ import annotations

import asyncio
import glob
import logging
import shutil
import socket
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from ..config import ServerConfig
from ..openai_client import ReachabilityCache
from . import metrics
from .audio import AudioManager
from .display import Backlight
from .runner import CommandRunner

log = logging.getLogger("peri.system")

TEMP_WARN_C = 70.0
TEMP_FAIL_C = 80.0
DISK_WARN_MB = 500
DISK_FAIL_MB = 100
NET_CACHE_S = 10.0


def check(check_id: str, status: str, detail: str) -> Dict[str, str]:
    return {"id": check_id, "status": status, "detail": detail}


class SystemInfo:
    def __init__(self, cfg: ServerConfig, runner: CommandRunner, audio: AudioManager, backlight: Backlight,
                 reach: ReachabilityCache, head_state: Callable[[], Dict[str, Any]], head_detail: Callable[[], str],
                 ui_clients: Callable[[], int], fs_root: Path = Path("/"), is_pi: bool = False) -> None:
        self.cfg = cfg
        self.is_pi = is_pi
        self.runner = runner
        self.audio = audio
        self.backlight = backlight
        self.reach = reach
        self._head_state = head_state
        self._head_detail = head_detail
        self._ui_clients = ui_clients
        self.root = fs_root
        self._net_cache: Optional[Tuple[float, Dict[str, Any]]] = None

    # ------------------------------------------------------------------------------------------- status
    async def cpu_temp(self) -> Optional[float]:
        temp = metrics.read_cpu_temp_c(self.root)
        if temp is None and self.runner.which("vcgencmd"):
            res = await self.runner.run(["vcgencmd", "measure_temp"], timeout=2.0)
            temp = metrics.parse_vcgencmd_temp(res.stdout) if res.ok else None
        return temp

    async def network(self) -> Dict[str, Any]:
        now = time.monotonic()
        if self._net_cache is not None and now - self._net_cache[0] < NET_CACHE_S:
            return self._net_cache[1]
        ip = metrics.local_ip()
        ssid: Optional[str] = None
        signal: Optional[int] = None
        if self.runner.which("nmcli"):
            # --rescan no: plain `dev wifi` triggers a scan when its cache is >30 s old and blocks for seconds
            res = await self.runner.run(["nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL", "dev", "wifi", "list", "--rescan", "no"],
                                        timeout=2.0)
            parsed = metrics.parse_nmcli_wifi(res.stdout) if res.ok else None
            if parsed:
                ssid, signal = parsed
        if ssid is None and self.runner.which("iw"):
            devs = glob.glob(str(self.root / "sys/class/net/*/wireless"))
            for dev in devs:
                iface = Path(dev).parent.name
                res = await self.runner.run(["iw", "dev", iface, "link"], timeout=2.0)
                parsed = metrics.parse_iw_link(res.stdout) if res.ok else None
                if parsed:
                    ssid, signal = parsed
                    break
        if signal is None and ssid is not None:
            try:
                signal = metrics.parse_proc_net_wireless((self.root / "proc/net/wireless").read_text())
            except OSError:
                signal = None
        info = {"online": ip is not None, "ssid": ssid, "ip": ip, "signal_pct": signal}
        self._net_cache = (now, info)
        return info

    async def openai_block(self) -> Dict[str, Any]:
        if not self.cfg.openai_configured:
            return {"configured": False, "reachable": None, "last_error": "no API key configured"}
        snap = self.reach.snapshot()
        return {"configured": True, "reachable": snap["reachable"], "last_error": snap["last_error"]}

    async def status(self) -> Dict[str, Any]:
        audio, brightness, net, temp = await asyncio.gather(
            self.audio.describe(), self.backlight.get(), self.network(), self.cpu_temp())
        return {
            "version": self.cfg.version,
            "hostname": socket.gethostname(),
            "uptime_s": metrics.read_uptime_s(self.root),
            "cpu_temp_c": temp,
            "load": metrics.read_load(),
            "mem": metrics.read_meminfo(self.root),
            "net": net,
            "audio": audio,
            "display": {"brightness": brightness, "supported": self.backlight.supported},
            "openai": await self.openai_block(),
            "head": self._head_state(),
            "ui": {"clients": self._ui_clients()},
        }

    # --------------------------------------------------------------------------------------------- diag
    async def diag(self) -> Dict[str, Any]:
        results = await asyncio.gather(
            self._openai_key(), self._openai_reachable(), self._audio_endpoint("audio_sink", "sink"),
            self._audio_endpoint("audio_source", "source"), self._mic_level(), self._head_driver(), self._display(),
            self._time_sync(), self._disk(), self._cpu_temp_check(), self._chromium())
        checks: List[Dict[str, str]] = list(results)
        statuses = {c["status"] for c in checks}
        overall = "fail" if "fail" in statuses else "warn" if "warn" in statuses else "ok"
        return {"overall": overall, "checks": checks, "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat()}

    async def _openai_key(self) -> Dict[str, str]:
        if self.cfg.openai_configured:
            return check("openai_key", "ok", "OPENAI_API_KEY is configured")
        return check("openai_key", "fail", "OPENAI_API_KEY is not set (sudo peri-config set OPENAI_API_KEY sk-...)")

    async def _openai_reachable(self) -> Dict[str, str]:
        if not self.cfg.openai_configured:
            return check("openai_reachable", "warn", "skipped: no API key")
        snap = await self.reach.refresh_now()
        if snap["reachable"]:
            return check("openai_reachable", "ok", snap["last_error"] or "api.openai.com reachable, key accepted")
        return check("openai_reachable", "fail", snap["last_error"] or "cannot reach api.openai.com")

    async def _audio_endpoint(self, check_id: str, key: str) -> Dict[str, str]:
        desc = await self.audio.describe()
        severe = "fail" if self.is_pi else "warn"
        if desc["backend"] is None:
            return check(check_id, severe, "no audio backend found (wpctl / pactl / amixer)")
        name = desc.get(key)
        if name:
            return check(check_id, "ok", f"{desc['backend']}: {name}")
        return check(check_id, "warn", f"{desc['backend']} is running but no default {key} was reported")

    async def _mic_level(self) -> Dict[str, str]:
        if not self.runner.which("arecord"):
            return check("mic_level", "warn", "arecord not installed; cannot sample the microphone")
        res = await self.runner.run(["arecord", "-q", "-D", "default", "-f", "S16_LE", "-r", "16000", "-c", "1", "-d", "1",
                                     "-t", "raw"], timeout=5.0)
        if not res.ok or not res.stdout_bytes:
            reason = (res.stderr.strip().splitlines() or ["no data"])[-1][:120]
            return check("mic_level", "warn", f"could not sample the microphone: {reason}")
        levels = metrics.pcm16_levels(res.stdout_bytes, skip_samples=1600)   # ignore the first 100 ms (start-up click)
        if levels is None:
            return check("mic_level", "warn", "microphone returned too little data")
        rms, peak = levels
        if peak == float("-inf"):
            return check("mic_level", "fail", "digital silence: capture is muted or not wired (run scripts/audio-test.sh)")
        if rms < -75.0:
            return check("mic_level", "warn", f"very quiet (rms {rms:.0f} dBFS, peak {peak:.0f} dBFS): raise the mic boost")
        return check("mic_level", "ok", f"rms {rms:.0f} dBFS, peak {peak:.0f} dBFS")

    async def _head_driver(self) -> Dict[str, str]:
        state = self._head_state()
        detail = self._head_detail()
        if state["error"]:
            return check("head_driver", "fail", f"{state['driver']}: {state['error']}")
        if state["connected"]:
            return check("head_driver", "ok", f"{state['driver']} connected" + (f" ({detail})" if detail else ""))
        return check("head_driver", "warn", f"{state['driver']} not connected" + (f": {detail}" if detail else ""))

    async def _display(self) -> Dict[str, str]:
        connected: List[str] = []
        for status_file in sorted(glob.glob(str(self.root / "sys/class/drm/*/status"))):
            try:
                if Path(status_file).read_text().strip() == "connected":
                    connector = Path(status_file).parent.name.split("-", 1)[-1]
                    modes = Path(status_file).parent / "modes"
                    mode = modes.read_text().split()[0] if modes.exists() and modes.read_text().split() else "?"
                    connected.append(f"{connector} {mode}")
            except OSError:
                continue
        if connected:
            return check("display", "ok", "connected: " + ", ".join(connected))
        if not self.is_pi:
            return check("display", "warn", "no DRM connector information (not a Raspberry Pi)")
        return check("display", "fail", "no display connected (DSI ribbon cable / display overlay?)")

    async def _time_sync(self) -> Dict[str, str]:
        if not self.runner.which("timedatectl"):
            return check("time_sync", "warn", "timedatectl not available")
        res = await self.runner.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"], timeout=3.0)
        value = res.stdout.strip().lower()
        if value == "yes":
            return check("time_sync", "ok", "clock synchronised (NTP)")
        if value == "no":
            return check("time_sync", "warn", "clock not synchronised yet (TLS to OpenAI may fail until it is)")
        return check("time_sync", "warn", "could not determine NTP status")

    async def _disk(self) -> Dict[str, str]:
        target = self.cfg.state_dir if self.cfg.state_dir.exists() else Path("/")
        try:
            free_mb = shutil.disk_usage(str(target)).free // (1024 * 1024)
        except OSError as exc:
            return check("disk", "warn", f"cannot read disk usage: {exc}")
        status = "fail" if free_mb < DISK_FAIL_MB else "warn" if free_mb < DISK_WARN_MB else "ok"
        return check("disk", status, f"{free_mb} MB free on {target}")

    async def _cpu_temp_check(self) -> Dict[str, str]:
        temp = await self.cpu_temp()
        if temp is None:
            return check("cpu_temp", "warn", "temperature not available")
        status = "fail" if temp >= TEMP_FAIL_C else "warn" if temp >= TEMP_WARN_C else "ok"
        return check("cpu_temp", status, f"{temp:.1f} C" + (" (throttling likely)" if status == "fail" else ""))

    async def _chromium(self) -> Dict[str, str]:
        clients = self._ui_clients()
        if clients > 0:
            return check("chromium", "ok", f"UI connected ({clients} websocket client{'s' if clients != 1 else ''})")
        return check("chromium", "warn", "no UI connected (kiosk browser not running or the page has not loaded)")
