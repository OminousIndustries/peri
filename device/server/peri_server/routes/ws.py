"""``GET /api/ws``: state push to the UI and low-latency head control."""
from __future__ import annotations

import json
import logging
import math
from typing import Any, Dict, Optional

from aiohttp import web

from ..hub import Client
from .common import ctx_of

log = logging.getLogger("peri.ws")


def _finite(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


async def handle_message(ctx: Any, client: Client, message: Dict[str, Any]) -> None:
    kind = message["t"]
    if kind == "ping":
        client.offer(json.dumps({"t": "pong"}))
        return
    if kind not in ("head.move", "head.gesture"):
        log.debug("ignoring websocket message type %r", kind)
        return
    if not client.head_bucket.allow():
        log.debug("head websocket message rate-limited")
        return
    if kind == "head.move":
        if not _finite(message.get("angle")):
            return
        raw_speed = message.get("speed_dps")
        speed_dps: Optional[float] = float(raw_speed) if isinstance(raw_speed, (int, float)) and _finite(raw_speed) and raw_speed > 0 else None
        await ctx.head.move(float(message["angle"]), speed_dps, message.get("relative") is True)
    else:
        name = message.get("name")
        intensity = message.get("intensity", 1.0)
        if isinstance(name, str):
            try:
                await ctx.head.gesture(name, float(intensity) if _finite(intensity) else 1.0)
            except KeyError:
                log.debug("unknown gesture %r over websocket", name)


async def handle_ws(request: web.Request) -> web.StreamResponse:
    ctx = ctx_of(request)
    hello = {"t": "hello", "version": ctx.cfg.version, "head": ctx.head.state(), "settings": ctx.settings.current}

    async def on_message(client: Client, message: Dict[str, Any]) -> None:
        await handle_message(ctx, client, message)

    return await ctx.hub.serve(request, hello, on_message)
