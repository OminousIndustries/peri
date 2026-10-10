"""REST endpoints of docs/API.md (config, settings, realtime, head, system, diag, client-log, ui/command)."""
from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any, Dict

from aiohttp import web

from .. import constants as C
from ..errors import ApiError, bad_request, unavailable
from ..logging_setup import redact
from ..openai_client import UpstreamError
from ..session import session_summary
from ..settings import SettingsError
from ..util import truncate
from .common import ctx_of, json_body, number, require_loopback

log = logging.getLogger("peri.api")
ui_log = logging.getLogger("peri.ui")

CONFIG_PROBE_TIMEOUT_S = 1.5
UI_COMMANDS = ("wake", "sleep", "mute", "unmute", "reload", "show_diag")
_LEVELS = {"debug": logging.DEBUG, "info": logging.INFO, "warn": logging.WARNING, "warning": logging.WARNING,
           "error": logging.ERROR}


def settings_error(exc: SettingsError) -> ApiError:
    return ApiError(400, "invalid_settings", f"invalid settings: {exc}", errors=exc.errors)


# ------------------------------------------------------------------------------------------------ basics
async def healthz(request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "version": ctx_of(request).cfg.version})


async def get_config(request: web.Request) -> web.Response:
    ctx = ctx_of(request)
    head = ctx.head.state()
    try:                                # never let a starting sound server delay the UI's first request
        backend = await asyncio.wait_for(ctx.audio.backend(), CONFIG_PROBE_TIMEOUT_S)
    except asyncio.TimeoutError:
        backend = None
    return web.json_response({
        "product": C.PRODUCT,
        "version": ctx.cfg.version,
        "device_id": ctx.device_id,
        "hardware": {"mode": "hardware" if ctx.is_pi else "sim"},
        "openai": {"configured": ctx.cfg.openai_configured},
        "models": C.MODELS,
        "voices": C.VOICES,
        "personas": ctx.catalog.public_personas(),
        "settings": ctx.settings.current,
        "head": {"driver": head["driver"], "connected": head["connected"], "limits": head["limits"]},
        "capabilities": {"volume": backend is not None and ctx.hw_control, "brightness": ctx.backlight.supported, "power": ctx.power.supported},
    })


async def get_settings(request: web.Request) -> web.Response:
    return web.json_response(ctx_of(request).settings.current)


async def put_settings(request: web.Request) -> web.Response:
    ctx = ctx_of(request)
    body = await json_body(request)
    try:
        new = await ctx.update_settings(body)
    except SettingsError as exc:
        raise settings_error(exc) from None
    return web.json_response(new)


# ------------------------------------------------------------------------------------------- realtime
def _overrides(body: Dict[str, Any]) -> Any:
    overrides = body.get("overrides")
    if overrides is not None and not isinstance(overrides, dict):
        raise bad_request("'overrides' must be an object")
    return overrides


async def realtime_session(request: web.Request) -> web.Response:
    ctx = ctx_of(request)
    body = await json_body(request)
    if not ctx.cfg.openai_configured:
        raise unavailable("no_api_key", "no OpenAI API key is configured (sudo peri-config set OPENAI_API_KEY sk-...)")
    sdp = body.get("sdp")
    if not isinstance(sdp, str) or not sdp.strip() or len(sdp) > 65536:
        raise bad_request("'sdp' must be the browser's SDP offer as a string")
    if not ctx.session_bucket.allow():
        log.warning("realtime session requests are arriving too fast; refusing (runaway UI loop?)")
        raise ApiError(429, "rate_limited", "too many realtime session requests; slow down")
    try:
        merged, build = ctx.session_builder(_overrides(body))
    except SettingsError as exc:
        raise settings_error(exc) from None
    started = time.monotonic()
    try:
        result = await ctx.realtime.create_call(sdp, build, merged["model"])
    except UpstreamError as exc:
        log.warning("realtime call rejected: HTTP %s %s", exc.status, redact(exc.message)[:200])
        raise exc.to_api_error() from None
    log.info("realtime call created (model=%s voice=%s persona=%s call_id=%s, %d ms)", merged["model"], merged["voice"],
             merged["persona"], result.call_id, (time.monotonic() - started) * 1000)
    return web.json_response({"sdp": result.sdp, "call_id": result.call_id, "session": session_summary(merged)})


async def realtime_token(request: web.Request) -> web.Response:
    ctx = ctx_of(request)
    body = await json_body(request, allow_empty=True)
    if not ctx.cfg.openai_configured:
        raise unavailable("no_api_key", "no OpenAI API key is configured (sudo peri-config set OPENAI_API_KEY sk-...)")
    try:
        merged, build = ctx.session_builder(_overrides(body))
    except SettingsError as exc:
        raise settings_error(exc) from None
    try:
        data = await ctx.realtime.create_token(build, merged["model"])
    except UpstreamError as exc:
        raise exc.to_api_error() from None
    secret = data.get("client_secret") if isinstance(data.get("client_secret"), dict) else data
    return web.json_response({"value": secret.get("value"), "expires_at": secret.get("expires_at"),
                              "session": data.get("session") or build(ctx.realtime.include_reasoning(merged["model"]))})


# ------------------------------------------------------------------------------------------------- head
async def head_get(request: web.Request) -> web.Response:
    return web.json_response(ctx_of(request).head.state())


async def head_move(request: web.Request) -> web.Response:
    body = await json_body(request)
    angle = number(body, "angle", lo=-360, hi=360)
    speed = number(body, "speed_dps", lo=0.01, hi=1000, required=False)
    relative = body.get("relative", False)
    if not isinstance(relative, bool):
        raise bad_request("'relative' must be true or false")
    return web.json_response(await ctx_of(request).head.move(angle, speed, relative))  # type: ignore[arg-type]


async def head_gesture(request: web.Request) -> web.Response:
    body = await json_body(request)
    name = body.get("name")
    if not isinstance(name, str) or name not in C.GESTURES:
        raise bad_request(f"'name' must be one of: {', '.join(C.GESTURES)}", code="unknown_gesture")
    intensity = number(body, "intensity", lo=0, hi=1, required=False)
    return web.json_response(await ctx_of(request).head.gesture(name, 1.0 if intensity is None else intensity))


async def head_nudge(request: web.Request) -> web.Response:
    body = await json_body(request)
    return web.json_response(await ctx_of(request).head.nudge(number(body, "delta_deg", lo=-90, hi=90)))  # type: ignore[arg-type]


async def head_zero(request: web.Request) -> web.Response:
    return web.json_response(await ctx_of(request).head.zero())


async def head_stop(request: web.Request) -> web.Response:
    return web.json_response(await ctx_of(request).head.stop())


async def head_release(request: web.Request) -> web.Response:
    return web.json_response(await ctx_of(request).head.release())


# ------------------------------------------------------------------------------------------------ system
async def system_status(request: web.Request) -> web.Response:
    return web.json_response(await ctx_of(request).info.status())


async def put_volume(request: web.Request) -> web.Response:
    ctx = ctx_of(request)
    body = await json_body(request)
    level = number(body, "level", lo=0, hi=100, required=False)
    muted = body.get("muted")
    if muted is not None and not isinstance(muted, bool):
        raise bad_request("'muted' must be true or false")
    if level is None and muted is None:
        raise bad_request("give 'level' (0-100) and/or 'muted'")
    state = await ctx.audio.set(level=None if level is None else int(round(level)), muted=muted)
    if level is not None:
        try:
            await ctx.update_settings({"audio": {"volume": int(round(level))}})
        except SettingsError as exc:  # pragma: no cover - level already validated to 0-100
            raise settings_error(exc) from None
    if state is None:
        current = ctx.settings.current["audio"]["volume"]
        return web.json_response({"volume": int(round(level)) if level is not None else current,
                                  "muted": bool(muted), "supported": False})
    payload = {"volume": state[0], "muted": state[1]}
    ctx.hub.broadcast({"t": "system.volume", **payload})
    return web.json_response({**payload, "supported": True})


async def put_brightness(request: web.Request) -> web.Response:
    ctx = ctx_of(request)
    body = await json_body(request)
    level = int(round(number(body, "level", lo=5, hi=100)))  # type: ignore[arg-type]
    await ctx.update_settings({"display": {"brightness": level}})
    supported = ctx.backlight.supported
    if supported:
        applied = await ctx.backlight.set(level)
        return web.json_response({"brightness": level if applied else await ctx.backlight.get(), "supported": bool(applied)})
    return web.json_response({"brightness": None, "supported": False})


async def post_power(request: web.Request) -> web.Response:
    require_loopback(request)
    ctx = ctx_of(request)
    body = await json_body(request)
    action = body.get("action")
    if action not in ("reboot", "shutdown", "restart-ui", "restart-server"):
        raise bad_request("'action' must be one of: reboot, shutdown, restart-ui, restart-server")
    if not ctx.power.supported:
        raise ApiError(501, "not_supported", "power actions only work on the device itself (not in dev/sim mode)")
    log.warning("power action requested: %s", action)
    ctx.power.schedule(action)
    return web.json_response({"ok": True, "action": action}, status=202)


async def get_diag(request: web.Request) -> web.Response:
    return web.json_response(await ctx_of(request).info.diag())


# -------------------------------------------------------------------------------------- client log / ui
async def client_log(request: web.Request) -> web.Response:
    ctx = ctx_of(request)
    body = await json_body(request)
    entries = body.get("entries")
    if not isinstance(entries, list):
        raise bad_request("'entries' must be a list")
    dropped = max(0, len(entries) - C.CLIENT_LOG_MAX_ENTRIES_PER_REQUEST)
    for entry in entries[: C.CLIENT_LOG_MAX_ENTRIES_PER_REQUEST]:
        if not isinstance(entry, dict):
            continue
        if not ctx.client_log_bucket.allow():
            dropped += 1
            continue
        level_name = str(entry.get("level", "info")).lower()
        message = truncate(str(entry.get("msg", "")).replace("\n", " ").replace("\r", " "), 500)
        extra = entry.get("ctx")
        ctx_text = ""
        if extra is not None:
            try:
                ctx_text = truncate(json.dumps(extra, ensure_ascii=False, separators=(",", ":"), default=str), 500)
            except (TypeError, ValueError):
                ctx_text = "<unserialisable ctx>"
        ui_log.log(_LEVELS.get(level_name, logging.INFO), "[ui] %s %s %s", level_name.upper(), message, ctx_text)
    if dropped:
        ui_log.warning("[ui] dropped %d client-log entries (rate limit / batch too large)", dropped)
    return web.Response(status=204)


async def ui_command(request: web.Request) -> web.Response:
    require_loopback(request)
    ctx = ctx_of(request)
    body = await json_body(request)
    cmd = body.get("cmd")
    if cmd not in UI_COMMANDS:
        raise bad_request(f"'cmd' must be one of: {', '.join(UI_COMMANDS)}")
    args = body.get("args") or {}
    if not isinstance(args, dict):
        raise bad_request("'args' must be an object")
    delivered = ctx.hub.broadcast({"t": "ui.command", "cmd": cmd, "args": args})
    return web.json_response({"ok": True, "delivered": delivered})
