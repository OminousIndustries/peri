"""Speaker volume through the first available backend (PipeWire ``wpctl`` -> PulseAudio ``pactl`` -> ALSA ``amixer``).

The server runs as a system service (user ``peri``); ``XDG_RUNTIME_DIR=/run/user/<uid>`` in its environment is what lets
wpctl/pactl reach the user's PipeWire. Volume ``level`` is 0-100 (wpctl/pactl percentages; amixer uses ``-M`` so the
scale is perceptual).
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from typing import Any, Dict, List, Optional, Tuple

from .runner import CommandRunner

log = logging.getLogger("peri.audio")

WM8960_PATTERN = re.compile(r"wm8960|seeed|voicecard|soc[_-]sound|simple-card", re.IGNORECASE)
#: PipeWire node properties searched for the WM8960 (the node NAME differs by board; the ALSA card name is the reliable part)
PW_MATCH_KEYS = ("node.name", "node.nick", "node.description", "alsa.card_name", "alsa.long_card_name", "api.alsa.card.name",
                 "api.alsa.card.longname", "device.description", "device.product.name")


class AudioBackend:
    """Interface + shared helpers. Subclasses implement the four operations."""

    name = "none"

    def __init__(self, runner: CommandRunner) -> None:
        self.run = runner

    async def available(self) -> bool:
        raise NotImplementedError

    async def get(self) -> Optional[Tuple[int, bool]]:
        """``(volume 0-100, muted)`` or None on failure."""
        raise NotImplementedError

    async def set_volume(self, level: int) -> bool:
        raise NotImplementedError

    async def set_muted(self, muted: bool) -> bool:
        raise NotImplementedError

    async def devices(self) -> Dict[str, Optional[str]]:
        return {"sink": None, "source": None}


class WpctlBackend(AudioBackend):
    name = "pipewire"

    async def available(self) -> bool:
        return (await self.run.run(["wpctl", "status"], timeout=2.0)).ok

    async def get(self) -> Optional[Tuple[int, bool]]:
        res = await self.run.run(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"])
        match = re.search(r"Volume:\s*([0-9.]+)", res.stdout)
        if not res.ok or not match:
            return None
        return int(round(float(match.group(1)) * 100)), "[MUTED]" in res.stdout

    async def set_volume(self, level: int) -> bool:
        res = await self.run.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{max(0, min(100, level)) / 100:.2f}"])
        return res.ok

    async def set_muted(self, muted: bool) -> bool:
        return (await self.run.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1" if muted else "0"])).ok

    async def devices(self) -> Dict[str, Optional[str]]:
        return {"sink": await self._describe("@DEFAULT_AUDIO_SINK@"), "source": await self._describe("@DEFAULT_AUDIO_SOURCE@")}

    async def _describe(self, target: str) -> Optional[str]:
        res = await self.run.run(["wpctl", "inspect", target])
        if not res.ok:
            return None
        for key in ("node.description", "node.nick", "node.name"):
            match = re.search(rf'{re.escape(key)}\s*=\s*"([^"]*)"', res.stdout)
            if match:
                return match.group(1)
        return None


class PactlBackend(AudioBackend):
    name = "pulseaudio"

    async def available(self) -> bool:
        return (await self.run.run(["pactl", "info"], timeout=2.0)).ok

    async def get(self) -> Optional[Tuple[int, bool]]:
        vol = await self.run.run(["pactl", "get-sink-volume", "@DEFAULT_SINK@"])
        mute = await self.run.run(["pactl", "get-sink-mute", "@DEFAULT_SINK@"])
        match = re.search(r"(\d+)%", vol.stdout)
        if not vol.ok or not match:
            return None
        return int(match.group(1)), "yes" in mute.stdout.lower()

    async def set_volume(self, level: int) -> bool:
        return (await self.run.run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{max(0, min(100, level))}%"])).ok

    async def set_muted(self, muted: bool) -> bool:
        return (await self.run.run(["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" if muted else "0"])).ok

    async def devices(self) -> Dict[str, Optional[str]]:
        sink = await self.run.run(["pactl", "get-default-sink"])
        source = await self.run.run(["pactl", "get-default-source"])
        return {"sink": sink.stdout.strip() or None, "source": source.stdout.strip() or None}


class AmixerBackend(AudioBackend):
    """Plain ALSA. Controls tried in order; on the WM8960 HAT ``Speaker`` (and ``Headphone``) are the output volumes."""

    name = "alsa"

    def __init__(self, runner: CommandRunner, card: Optional[str] = None) -> None:
        super().__init__(runner)
        self._card = card
        self._controls: Optional[List[str]] = None

    def _base(self) -> List[str]:
        return ["amixer", "-c", self._card] if self._card else ["amixer"]

    async def _find_card(self) -> Optional[str]:
        if self._card is not None:
            return self._card
        try:
            with open("/proc/asound/cards", encoding="utf-8") as fh:
                for line in fh:
                    match = re.match(r"\s*(\d+)\s+\[([^\]]*)\]", line)
                    if match and WM8960_PATTERN.search(line):
                        self._card = match.group(1)
                        return self._card
        except OSError:
            pass
        return None

    async def _discover(self) -> List[str]:
        if self._controls is not None:
            return self._controls
        await self._find_card()
        res = await self.run.run(self._base() + ["scontrols"])
        names = re.findall(r"Simple mixer control '([^']+)',\d+", res.stdout) if res.ok else []
        chosen = [c for c in ("Master",) if c in names]
        if not chosen:
            chosen = [c for c in ("Speaker", "Headphone") if c in names]
        if not chosen:
            chosen = [c for c in ("PCM", "Playback") if c in names]
        self._controls = chosen
        return chosen

    async def available(self) -> bool:
        return bool(await self._discover())

    async def get(self) -> Optional[Tuple[int, bool]]:
        controls = await self._discover()
        if not controls:
            return None
        res = await self.run.run(self._base() + ["-M", "sget", controls[0]])
        pct = re.search(r"\[(\d+)%\]", res.stdout)
        if not res.ok or not pct:
            return None
        return int(pct.group(1)), "[off]" in res.stdout

    async def set_volume(self, level: int) -> bool:
        ok = False
        for control in await self._discover():
            res = await self.run.run(self._base() + ["-M", "sset", control, f"{max(0, min(100, level))}%"])
            ok = res.ok or ok
        return ok

    async def set_muted(self, muted: bool) -> bool:
        ok = False
        for control in await self._discover():
            res = await self.run.run(self._base() + ["sset", control, "mute" if muted else "unmute"])
            ok = res.ok or ok
        return ok

    async def devices(self) -> Dict[str, Optional[str]]:
        await self._find_card()
        return {"sink": f"ALSA card {self._card or 'default'}", "source": f"ALSA card {self._card or 'default'}"}


class AudioManager:
    """Detects the backend lazily (and again after failures), exposes volume get/set and default-device pinning."""

    REDETECT_AFTER_S = 30.0

    def __init__(self, runner: Optional[CommandRunner] = None, control: bool = True) -> None:
        self.runner = runner or CommandRunner()
        #: False = read-only (development machines: never change the host's volume or default device)
        self.control = control
        self._backend: Optional[AudioBackend] = None
        self._checked_at = 0.0

    async def backend(self) -> Optional[AudioBackend]:
        now = time.monotonic()
        if self._backend is not None:
            return self._backend
        if now - self._checked_at < self.REDETECT_AFTER_S and self._checked_at:
            return None
        self._checked_at = now
        for cls in (WpctlBackend, PactlBackend, AmixerBackend):
            candidate = cls(self.runner)
            if await candidate.available():
                self._backend = candidate
                log.info("audio backend: %s", candidate.name)
                return candidate
        log.info("no audio backend found (wpctl/pactl/amixer)")
        return None

    def _forget(self) -> None:
        self._backend = None
        self._checked_at = 0.0

    @property
    def supported(self) -> bool:
        return self._backend is not None

    async def describe(self) -> Dict[str, Any]:
        """The ``audio`` block of /api/system/status."""
        backend = await self.backend()
        if backend is None:
            return {"backend": None, "sink": None, "source": None, "volume": None, "muted": None}
        state = await backend.get()
        if state is None:
            self._forget()
            return {"backend": backend.name, "sink": None, "source": None, "volume": None, "muted": None}
        devices = await backend.devices()
        return {"backend": backend.name, "sink": devices["sink"], "source": devices["source"], "volume": state[0],
                "muted": state[1]}

    async def get(self) -> Optional[Tuple[int, bool]]:
        backend = await self.backend()
        return await backend.get() if backend else None

    async def set(self, level: Optional[int] = None, muted: Optional[bool] = None) -> Optional[Tuple[int, bool]]:
        """Apply volume and/or mute; returns the resulting ``(volume, muted)`` or None if unsupported/failed."""
        backend = await self.backend()
        if backend is None or not self.control:
            return None
        ok = True
        if level is not None:
            ok = await backend.set_volume(int(level)) and ok
        if muted is not None:
            ok = await backend.set_muted(bool(muted)) and ok
        if not ok:
            log.warning("audio backend %s failed to apply volume/mute", backend.name)
            self._forget()
            return None
        return await backend.get()

    # ------------------------------------------------------------------------------- default device pinning
    async def pin_default_devices(self, attempts: int = 20, delay: float = 3.0) -> bool:
        """Make the WM8960 the default sink and source (PipeWire/PulseAudio). Retries while the sound server starts."""
        if not self.control:
            return False
        for attempt in range(attempts):
            backend = await self.backend()
            if backend is None or backend.name == "alsa":
                return False            # plain ALSA: /etc/asound.conf decides, nothing to pin
            done = await (self._pin_pipewire() if backend.name == "pipewire" else self._pin_pulse())
            if done:
                return True
            await asyncio.sleep(delay)
        log.warning("could not pin the WM8960 as default audio device (is the card present?)")
        return False

    async def _pin_pipewire(self) -> bool:
        dump = await self.runner.run(["pw-dump"], timeout=6.0)
        if not dump.ok:
            return False
        try:
            objects = json.loads(dump.stdout)
        except ValueError:
            return False
        found: Dict[str, Optional[int]] = {"Audio/Sink": None, "Audio/Source": None}
        for obj in objects:
            props = ((obj.get("info") or {}).get("props")) or {}
            media_class = props.get("media.class")
            name = str(props.get("node.name", ""))
            if media_class not in found or found[media_class] is not None or not name.startswith(("alsa_output", "alsa_input")):
                continue                      # only real ALSA nodes (not virtual sinks, streams, monitors ...)
            blob = " ".join(str(props.get(k, "")) for k in PW_MATCH_KEYS)
            if WM8960_PATTERN.search(blob):
                found[media_class] = obj.get("id")
        ok = True
        for media_class, node_id in found.items():
            if node_id is None:
                ok = False
                continue
            res = await self.runner.run(["wpctl", "set-default", str(node_id)])
            ok = res.ok and ok
        return ok

    async def _pin_pulse(self) -> bool:
        ok = True
        for kind, getter in (("sinks", "set-default-sink"), ("sources", "set-default-source")):
            listing = await self.runner.run(["pactl", "list", "short", kind])
            if not listing.ok:
                return False
            names = [line.split("\t")[1] for line in listing.stdout.splitlines() if "\t" in line]
            names = [n for n in names if not n.endswith(".monitor") and WM8960_PATTERN.search(n)]
            if not names:
                ok = False
                continue
            ok = (await self.runner.run(["pactl", getter, names[0]])).ok and ok
        return ok
