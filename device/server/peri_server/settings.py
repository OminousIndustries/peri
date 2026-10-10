"""User settings: schema derived from ``config/settings.default.json``, validation, merge and atomic persistence.

The defaults file is the schema (same keys, same JSON types). Explicit ``RULES`` add ranges and enums; a key present in
the defaults but not in RULES is still validated by the type of its default value, so new settings added by the UI
engineer work without server changes. Unknown keys are rejected (HTTP 400).
"""
from __future__ import annotations

import asyncio
import logging
import math
import re
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from . import constants as C
from .errors import ApiError
from .util import atomic_write_json, deep_merge, diff_paths, read_json

log = logging.getLogger("peri.settings")


class SettingsError(ValueError):
    """Validation failed; ``errors`` is a list of ``{"path": ..., "message": ...}``."""

    def __init__(self, errors: List[Dict[str, str]]) -> None:
        super().__init__("; ".join(f"{e['path']}: {e['message']}" for e in errors))
        self.errors = errors


class Rule:
    """Validation rule for one setting. ``kind`` is bool | int | number | str | enum."""

    def __init__(self, kind: str, lo: Optional[float] = None, hi: Optional[float] = None,
                 choices: Optional[Sequence[Any]] = None, pattern: Optional[str] = None, maxlen: int = 200) -> None:
        self.kind = kind
        self.lo = lo
        self.hi = hi
        self.choices = list(choices) if choices is not None else None
        self.pattern = re.compile(pattern) if pattern else None
        self.maxlen = maxlen

    def check(self, value: Any) -> Any:
        """Return the normalised value or raise ValueError(message)."""
        if self.kind == "bool":
            if not isinstance(value, bool):
                raise ValueError("must be true or false")
            return value
        if self.kind in ("int", "number"):
            return self._number(value)
        if self.kind == "str":
            if not isinstance(value, str):
                raise ValueError("must be a string")
            if len(value) > self.maxlen:
                raise ValueError(f"must be at most {self.maxlen} characters")
            if self.pattern is not None and not self.pattern.match(value):
                raise ValueError("has an invalid format")
            return value
        if self.kind == "enum":
            assert self.choices is not None
            candidate = value
            if isinstance(value, float) and value.is_integer() and any(isinstance(c, int) for c in self.choices):
                candidate = int(value)
            if isinstance(candidate, bool) or candidate not in self.choices:
                raise ValueError("must be one of: " + ", ".join(str(c) for c in self.choices))
            return candidate
        raise ValueError(f"unsupported rule kind {self.kind}")  # pragma: no cover

    def _number(self, value: Any) -> Any:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("must be a number")
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("must be a finite number")
        if self.kind == "int":
            if isinstance(value, float):
                if not value.is_integer():
                    raise ValueError("must be a whole number")
                value = int(value)
        elif isinstance(value, float) and value.is_integer():
            value = int(value)  # 20.0 -> 20 keeps the stored JSON tidy
        if (self.lo is not None and value < self.lo) or (self.hi is not None and value > self.hi):
            raise ValueError(f"must be between {self.lo:g} and {self.hi:g}")
        return value


#: Constraints from docs/API.md section 2.2 (+ sensible formats). Dotted paths.
RULES: Dict[str, Rule] = {
    "custom_instructions": Rule("str", maxlen=4000),
    "voice": Rule("enum", choices=C.VOICES),
    "speed": Rule("number", 0.7, 1.3),
    "model": Rule("str", pattern=C.MODEL_ID_RE, maxlen=64),
    "reasoning_effort": Rule("enum", choices=C.REASONING_EFFORTS),
    "transcription_model": Rule("str", pattern=C.MODEL_ID_RE, maxlen=64),
    "language": Rule("str", pattern=C.LANGUAGE_RE, maxlen=16),
    "captions": Rule("enum", choices=["off", "assistant", "both"]),
    "wake_mode": Rule("enum", choices=["tap", "always"]),
    "idle_sleep_s": Rule("int", 15, 3600),
    "barge_in": Rule("enum", choices=["voice", "tap"]),
    "vad.type": Rule("enum", choices=["semantic_vad", "server_vad"]),
    "vad.eagerness": Rule("enum", choices=["auto", "low", "medium", "high"]),
    "vad.threshold": Rule("number", 0.0, 1.0),
    "noise_reduction": Rule("enum", choices=["off", "near_field", "far_field"]),
    "head.intensity": Rule("number", 0.0, 1.0),
    "head.limit_deg": Rule("number", 5, 25),
    "display.rotation": Rule("enum", choices=[0, 90, 180, 270]),
    "display.brightness": Rule("int", 5, 100),
    "audio.volume": Rule("int", 0, 100),
}


class DynamicEnum(Rule):
    """Enum whose allowed values are computed on each check (e.g. the persona ids, which can change on disk)."""

    def __init__(self, choices_fn: Callable[[], Sequence[str]]) -> None:
        super().__init__("enum", choices=[])
        self._choices_fn = choices_fn

    def check(self, value: Any) -> Any:
        choices = list(self._choices_fn())
        if not isinstance(value, str) or value not in choices:
            raise ValueError("must be one of: " + ", ".join(choices))
        return value


def _infer_rule(default: Any) -> Rule:
    """Type-only rule for settings the server does not know about explicitly."""
    if isinstance(default, bool):
        return Rule("bool")
    if isinstance(default, int):
        return Rule("int")
    if isinstance(default, float):
        return Rule("number")
    return Rule("str", maxlen=1000)


class SettingsSchema:
    """Defaults + per-path rules. ``extra_rules`` carries dynamic constraints (e.g. the persona ids)."""

    def __init__(self, defaults: Mapping[str, Any], extra_rules: Optional[Mapping[str, Rule]] = None) -> None:
        self.defaults: Dict[str, Any] = dict(defaults)
        self._rules: Dict[str, Rule] = dict(RULES)
        if extra_rules:
            self._rules.update(extra_rules)

    def rule_for(self, path: str, default: Any) -> Rule:
        return self._rules.get(path) or _infer_rule(default)

    def validate_patch(self, patch: Any) -> Dict[str, Any]:
        """Validate a (possibly partial) settings object; returns the normalised patch or raises SettingsError."""
        errors: List[Dict[str, str]] = []
        result = self._walk(patch, self.defaults, "", errors)
        if errors:
            raise SettingsError(errors)
        return result

    def _walk(self, patch: Any, defaults: Mapping[str, Any], prefix: str, errors: List[Dict[str, str]]) -> Dict[str, Any]:
        out: Dict[str, Any] = {}
        if not isinstance(patch, dict):
            errors.append({"path": prefix.rstrip(".") or "(root)", "message": "must be an object"})
            return out
        for key, value in patch.items():
            path = prefix + str(key)
            if key not in defaults:
                errors.append({"path": path, "message": "unknown setting"})
                continue
            default = defaults[key]
            if isinstance(default, dict):
                if not isinstance(value, dict):
                    errors.append({"path": path, "message": "must be an object"})
                else:
                    sub = self._walk(value, default, path + ".", errors)
                    if sub:
                        out[key] = sub
                continue
            if isinstance(value, dict):
                errors.append({"path": path, "message": "must not be an object"})
                continue
            try:
                out[key] = self.rule_for(path, default).check(value)
            except ValueError as exc:
                errors.append({"path": path, "message": str(exc)})
        return out

    def sanitize_stored(self, stored: Any) -> Dict[str, Any]:
        """Best-effort load of a settings file: keep every valid known value, drop (and warn about) the rest."""
        good: Dict[str, Any] = {}
        if not isinstance(stored, dict):
            return good
        self._collect(stored, self.defaults, "", good)
        return good

    def _collect(self, stored: Mapping[str, Any], defaults: Mapping[str, Any], prefix: str, out: Dict[str, Any]) -> None:
        for key, value in stored.items():
            path = prefix + str(key)
            if key not in defaults:
                log.warning("ignoring unknown stored setting %s", path)
                continue
            default = defaults[key]
            if isinstance(default, dict):
                if isinstance(value, dict):
                    sub: Dict[str, Any] = {}
                    self._collect(value, default, path + ".", sub)
                    if sub:
                        out[key] = sub
                else:
                    log.warning("ignoring stored setting %s: expected an object", path)
                continue
            try:
                out[key] = self.rule_for(path, default).check(value)
            except ValueError as exc:
                log.warning("ignoring stored setting %s: %s", path, exc)


class SettingsStore:
    """Holds the current settings, persists changes atomically to ``<state>/settings.json``."""

    def __init__(self, path: Path, schema: SettingsSchema) -> None:
        self.path = Path(path)
        self.schema = schema
        self._current: Dict[str, Any] = deep_merge(schema.defaults, {})
        # Created lazily inside the running loop: before Python 3.10 an asyncio.Lock binds to the loop that is current at
        # construction time, which is not the server's loop (the store is built before web.run_app creates it).
        self._lock: Optional[asyncio.Lock] = None
        self.load()

    def load(self) -> None:
        stored = read_json(self.path)
        if stored is None:
            if self.path.exists():
                log.warning("%s is unreadable or not valid JSON; using defaults", self.path)
            return
        self._current = deep_merge(self.schema.defaults, self.schema.sanitize_stored(stored))

    @property
    def current(self) -> Dict[str, Any]:
        """A copy of the current settings (mutating it has no effect on the store)."""
        return deep_merge(self._current, {})

    def peek(self) -> Mapping[str, Any]:
        """The live settings object for cheap read-only access on hot paths. Callers must not modify it."""
        return self._current

    def with_overrides(self, overrides: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
        """Current settings with validated ``overrides`` merged in (not persisted). Raises SettingsError."""
        if not overrides:
            return self.current
        return deep_merge(self._current, self.schema.validate_patch(dict(overrides)))

    async def update(self, patch: Mapping[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Any], List[str]]:
        """Validate + merge + persist. Returns ``(new, old, changed_paths)``. Raises SettingsError / ApiError(500)."""
        if self._lock is None:
            self._lock = asyncio.Lock()
        async with self._lock:
            normalized = self.schema.validate_patch(dict(patch))
            old = self.current
            new = deep_merge(old, normalized)
            changed = diff_paths(old, new)
            if changed:
                try:
                    await asyncio.get_event_loop().run_in_executor(None, atomic_write_json, self.path, new)
                except OSError as exc:
                    log.error("cannot write %s: %s", self.path, exc)
                    raise ApiError(500, "persist_failed", f"could not save settings: {exc.strerror or exc}") from exc
                self._current = new
            return deep_merge(new, {}), old, changed


def flatten(settings: Mapping[str, Any], prefix: str = "") -> Iterable[Tuple[str, Any]]:
    """Yield ``(dotted.path, value)`` for every leaf (handy for logging what changed)."""
    for key, value in settings.items():
        if isinstance(value, Mapping):
            yield from flatten(value, f"{prefix}{key}.")
        else:
            yield f"{prefix}{key}", value
