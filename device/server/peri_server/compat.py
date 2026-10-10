"""Small shims so the same code runs on aiohttp 3.7 (Debian Bullseye) through 3.13 (Trixie and newer)."""
from __future__ import annotations

from typing import Any

from aiohttp import web


def app_key(name: str, typ: Any = object) -> Any:
    """Return a typed ``web.AppKey`` where available (aiohttp >= 3.9 warns about plain string keys), else the string."""
    factory = getattr(web, "AppKey", None)
    return factory(name, typ) if factory is not None else name
