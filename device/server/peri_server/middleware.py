"""aiohttp middlewares: JSON errors, one access-log line per request (never bodies), bearer-token auth."""
from __future__ import annotations

import hmac
import logging
import time
from typing import Any, Awaitable, Callable

from aiohttp import web

from .errors import ApiError, unauthorized
from .util import is_loopback_addr

log = logging.getLogger("peri.http")
Handler = Callable[[web.Request], Awaitable[web.StreamResponse]]

_HTTP_CODES = {400: "bad_request", 401: "unauthorized", 403: "forbidden", 404: "not_found", 405: "method_not_allowed",
               413: "payload_too_large", 415: "unsupported_media_type", 429: "rate_limited"}


def _json_error(status: int, code: str, message: str, **extra: Any) -> web.Response:
    return web.json_response({"error": {"code": code, "message": message, **extra}}, status=status)


@web.middleware
async def error_middleware(request: web.Request, handler: Handler) -> web.StreamResponse:
    try:
        return await handler(request)
    except ApiError as exc:
        return web.json_response(exc.body(), status=exc.status)
    except web.HTTPException as exc:
        if exc.status < 400:
            raise
        if request.path.startswith("/api/") or request.path == "/healthz":
            return _json_error(exc.status, _HTTP_CODES.get(exc.status, "error"), exc.reason or "error")
        raise
    except Exception:
        log.exception("unhandled error in %s %s", request.method, request.path)
        return _json_error(500, "internal", "internal server error")


@web.middleware
async def access_log_middleware(request: web.Request, handler: Handler) -> web.StreamResponse:
    started = time.monotonic()
    status = 500
    try:
        response = await handler(request)
        status = response.status
        return response
    except web.HTTPException as exc:
        status = exc.status
        raise
    finally:
        if request.path != "/api/ws":                         # websocket connects/disconnects are logged by the hub
            level = logging.DEBUG if request.path == "/healthz" else logging.INFO
            log.log(level, "%s %s %d %dms", request.method, request.path, status, (time.monotonic() - started) * 1000)


def make_auth_middleware(admin_token: str, enforce: bool) -> Callable[..., Any]:
    """Bearer-token auth for non-loopback binds. Loopback peers never need a token; GET/HEAD are open except /api/ws."""

    @web.middleware
    async def auth_middleware(request: web.Request, handler: Handler) -> web.StreamResponse:
        if enforce and not is_loopback_addr(request.remote):
            is_ws = request.path == "/api/ws"
            if is_ws or request.method not in ("GET", "HEAD", "OPTIONS"):
                supplied = request.headers.get("Authorization", "")
                token = supplied[7:].strip() if supplied.lower().startswith("bearer ") else ""
                if not token and is_ws:
                    token = request.query.get("token", "")
                if not token or not hmac.compare_digest(token.encode(), admin_token.encode()):
                    raise unauthorized()
        return await handler(request)

    return auth_middleware
