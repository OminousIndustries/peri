"""Route registration."""
from __future__ import annotations

from aiohttp import web

from . import api
from .static import handle_static
from .ws import handle_ws


def register_routes(app: web.Application) -> None:
    add = app.router.add_route
    get = app.router.add_get          # also serves HEAD (curl -I, monitoring)
    get("/healthz", api.healthz)
    get("/api/config", api.get_config)
    get("/api/settings", api.get_settings)
    add("PUT", "/api/settings", api.put_settings)
    add("POST", "/api/realtime/session", api.realtime_session)
    add("POST", "/api/realtime/token", api.realtime_token)
    get("/api/head", api.head_get)
    add("POST", "/api/head/move", api.head_move)
    add("POST", "/api/head/gesture", api.head_gesture)
    add("POST", "/api/head/nudge", api.head_nudge)
    add("POST", "/api/head/zero", api.head_zero)
    add("POST", "/api/head/stop", api.head_stop)
    add("POST", "/api/head/release", api.head_release)
    get("/api/system/status", api.system_status)
    add("PUT", "/api/system/volume", api.put_volume)
    add("PUT", "/api/system/brightness", api.put_brightness)
    add("POST", "/api/system/power", api.post_power)
    get("/api/diag", api.get_diag)
    add("POST", "/api/client-log", api.client_log)
    add("POST", "/api/ui/command", api.ui_command)
    add("GET", "/api/ws", handle_ws)
    get("/{tail:.*}", handle_static)   # last: static files + SPA fallback (also serves /diag)
