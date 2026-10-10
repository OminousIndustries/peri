"""Application factory."""
from __future__ import annotations

import logging
from typing import Any, Optional

from aiohttp import web

from .config import ServerConfig
from .context import Context
from .middleware import access_log_middleware, error_middleware, make_auth_middleware
from .routes import register_routes
from .routes.common import CTX

log = logging.getLogger("peri.app")

MAX_BODY_BYTES = 256 * 1024     # a browser SDP offer is a few KB; anything larger is not ours


def create_app(cfg: ServerConfig, ctx: Optional[Context] = None, **context_kwargs: Any) -> web.Application:
    """Build the aiohttp application. ``ctx`` may be supplied by tests (or built here from ``cfg``)."""
    context = ctx or Context(cfg, **context_kwargs)
    app = web.Application(
        middlewares=[access_log_middleware, error_middleware,
                     make_auth_middleware(cfg.admin_token, enforce=not cfg.loopback_bind)],
        client_max_size=MAX_BODY_BYTES)
    app[CTX] = context
    register_routes(app)

    async def on_startup(_app: web.Application) -> None:
        await context.start()

    async def on_shutdown(_app: web.Application) -> None:
        await context.hub.close_all()      # open websockets would otherwise delay the shutdown

    async def on_cleanup(_app: web.Application) -> None:
        await context.stop()

    app.on_startup.append(on_startup)
    app.on_shutdown.append(on_shutdown)
    app.on_cleanup.append(on_cleanup)
    return app
