"""Small helpers: atomic file writes, strict JSON, deep merge, rate limiting, loopback checks."""
from __future__ import annotations

import copy
import ipaddress
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Union


def _reject_constant(name: str) -> Any:
    raise ValueError(f"invalid JSON constant {name}")


def loads_strict(text: Union[str, bytes]) -> Any:
    """``json.loads`` that rejects NaN / Infinity (Python accepts them by default; JS and OpenAI do not)."""
    return json.loads(text, parse_constant=_reject_constant)


def atomic_write_text(path: Union[str, Path], text: str, mode: int = 0o640) -> None:
    """Write ``text`` to ``path`` so readers see either the old or the new file, never a partial one."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    _fsync_dir(path.parent)


def _fsync_dir(directory: Path) -> None:
    try:
        fd = os.open(str(directory), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def atomic_write_json(path: Union[str, Path], data: Any, mode: int = 0o640) -> None:
    atomic_write_text(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n", mode)


def read_json(path: Union[str, Path]) -> Optional[Any]:
    """Parsed JSON file or None when missing/unreadable/invalid (callers decide how loudly to complain)."""
    try:
        return loads_strict(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def deep_merge(base: Dict[str, Any], patch: Dict[str, Any]) -> Dict[str, Any]:
    """Return a new dict: ``base`` with ``patch`` merged in recursively (dicts merge, everything else replaces)."""
    out = copy.deepcopy(base)
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def diff_paths(old: Any, new: Any, prefix: str = "") -> list:
    """Dotted paths whose values differ between two nested dicts (e.g. ``["head.limit_deg", "voice"]``)."""
    if isinstance(old, dict) and isinstance(new, dict):
        paths: list = []
        for key in sorted(set(old) | set(new)):
            paths.extend(diff_paths(old.get(key), new.get(key), f"{prefix}{key}."))
        return paths
    return [] if old == new else [prefix.rstrip(".")]


def clamp(value: float, lo: float, hi: float) -> float:
    return lo if value < lo else hi if value > hi else value


class TokenBucket:
    """Classic token bucket. ``allow()`` consumes one token when available."""

    def __init__(self, rate: float, burst: Optional[float] = None, clock: Callable[[], float] = time.monotonic) -> None:
        self.rate = float(rate)
        self.capacity = float(burst if burst is not None else rate)
        self._tokens = self.capacity
        self._clock = clock
        self._stamp = clock()

    def allow(self, cost: float = 1.0) -> bool:
        now = self._clock()
        self._tokens = min(self.capacity, self._tokens + (now - self._stamp) * self.rate)
        self._stamp = now
        if self._tokens >= cost:
            self._tokens -= cost
            return True
        return False


def is_loopback_addr(addr: Optional[str]) -> bool:
    """True when a peer address (as reported by aiohttp's ``request.remote``) is loopback."""
    if not addr:
        return False
    try:
        ip = ipaddress.ip_address(addr.split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:  # ::ffff:127.0.0.1
        ip = ip.ipv4_mapped
    return ip.is_loopback


def truncate(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[: max(0, limit - 1)] + "…"
