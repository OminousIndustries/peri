"""Helpers shared by route handlers."""
from __future__ import annotations

import math
from typing import Any, Dict, Optional

from aiohttp import web

from ..compat import app_key
from ..errors import bad_request, forbidden
from ..util import is_loopback_addr, loads_strict

CTX = app_key("peri.context", object)


def ctx_of(request: web.Request) -> Any:
    """The application ``Context`` (see peri_server.context)."""
    return request.app[CTX]


def require_loopback(request: web.Request) -> None:
    """Endpoints that must only be reachable from the device itself (power, ui/command)."""
    if not is_loopback_addr(request.remote):
        raise forbidden()


async def json_body(request: web.Request, allow_empty: bool = False) -> Dict[str, Any]:
    raw = await request.read()
    if not raw.strip():
        if allow_empty:
            return {}
        raise bad_request("a JSON object body is required")
    try:
        data = loads_strict(raw)
    except ValueError:
        raise bad_request("request body is not valid JSON") from None
    if not isinstance(data, dict):
        raise bad_request("request body must be a JSON object")
    return data


def number(data: Dict[str, Any], key: str, *, lo: Optional[float] = None, hi: Optional[float] = None,
           required: bool = True) -> Optional[float]:
    """A finite JSON number (not a bool/string) within ``[lo, hi]``; None when absent and not required."""
    if key not in data or data[key] is None:
        if required:
            raise bad_request(f"'{key}' is required")
        return None
    value = data[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise bad_request(f"'{key}' must be a number")
    if (lo is not None and value < lo) or (hi is not None and value > hi):
        raise bad_request(f"'{key}' must be between {lo:g} and {hi:g}" if lo is not None and hi is not None
                          else f"'{key}' is out of range")
    return float(value)
