"""Persona presets and tool declarations, loaded from ``config/personas.json`` and ``config/tools.json``."""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from .config import ConfigError

log = logging.getLogger("peri.catalog")


@dataclass(frozen=True)
class Persona:
    id: str
    name: str
    blurb: str
    voice: str
    speed: float
    instructions: str

    def public(self) -> Dict[str, Any]:
        """The subset the UI needs for its picker (never the full prompt)."""
        return {"id": self.id, "name": self.name, "blurb": self.blurb, "voice": self.voice, "speed": self.speed}


@dataclass(frozen=True)
class Catalog:
    personas: List[Persona]
    default_persona: str
    tools: List[Dict[str, Any]]

    def persona(self, persona_id: str) -> Persona:
        for persona in self.personas:
            if persona.id == persona_id:
                return persona
        raise KeyError(persona_id)

    def persona_or_default(self, persona_id: str) -> Persona:
        """The persona, or the default one when personas.json no longer has it (a stale id in settings.json must not break sessions)."""
        try:
            return self.persona(persona_id)
        except KeyError:
            return self.persona(self.default_persona)

    @property
    def persona_ids(self) -> List[str]:
        return [p.id for p in self.personas]

    def public_personas(self) -> List[Dict[str, Any]]:
        return [p.public() for p in self.personas]


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc
    except ValueError as exc:
        raise ConfigError(f"{path} is not valid JSON: {exc}") from exc


def load_catalog(config_dir: Path) -> Catalog:
    raw = _load_json(config_dir / "personas.json")
    entries = raw.get("personas") if isinstance(raw, dict) else None
    if not isinstance(entries, list) or not entries:
        raise ConfigError(f"{config_dir / 'personas.json'} must contain a non-empty 'personas' list")
    personas: List[Persona] = []
    for entry in entries:
        try:
            personas.append(
                Persona(
                    id=str(entry["id"]), name=str(entry.get("name", entry["id"])), blurb=str(entry.get("blurb", "")),
                    voice=str(entry.get("voice", "marin")), speed=float(entry.get("speed", 1.0)),
                    instructions=str(entry["instructions"]),
                )
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise ConfigError(f"bad persona entry in personas.json: {exc!r}") from exc
    ids = [p.id for p in personas]
    if len(set(ids)) != len(ids):
        raise ConfigError("duplicate persona ids in personas.json")
    default = str(raw.get("default") or ids[0])
    if default not in ids:
        raise ConfigError(f"personas.json default {default!r} is not one of {ids}")

    tools = _load_json(config_dir / "tools.json")
    if not isinstance(tools, list) or not all(isinstance(t, dict) and t.get("name") for t in tools):
        raise ConfigError(f"{config_dir / 'tools.json'} must be a list of tool objects with a 'name'")
    return Catalog(personas=personas, default_persona=default, tools=tools)


class CatalogSource:
    """Serves the catalog and re-reads ``personas.json`` / ``tools.json`` when they change on disk.

    The check is a cheap ``stat`` at most once per ``interval`` seconds, so edits (e.g. a new tool description) take effect on
    the next session without restarting the server. A file that fails to parse keeps the previous good catalog.
    """

    FILES = ("personas.json", "tools.json")

    def __init__(self, config_dir: Path, interval: float = 1.0, clock: Callable[[], float] = time.monotonic) -> None:
        self._dir = Path(config_dir)
        self._interval = interval
        self._clock = clock
        self._catalog = load_catalog(self._dir)
        self._stamp = self._stat()
        self._checked = clock()

    def _stat(self) -> Tuple[Optional[int], ...]:
        stamps: List[Optional[int]] = []
        for name in self.FILES:
            try:
                stamps.append((self._dir / name).stat().st_mtime_ns)
            except OSError:
                stamps.append(None)
        return tuple(stamps)

    def get(self) -> Catalog:
        now = self._clock()
        if now - self._checked >= self._interval:
            self._checked = now
            stamp = self._stat()
            if stamp != self._stamp:
                self._stamp = stamp
                try:
                    self._catalog = load_catalog(self._dir)
                    log.info("reloaded personas/tools from %s", self._dir)
                except ConfigError as exc:
                    log.warning("keeping the previous personas/tools: %s", exc)
        return self._catalog
