"""``python3 -m peri_server``: run the server with the configuration from the environment."""
from __future__ import annotations

import logging
import sys

from aiohttp import web

from .app import create_app
from .config import ConfigError, ServerConfig, log_level_number, summarize
from .logging_setup import setup_logging


def main() -> int:
    try:
        cfg = ServerConfig.from_env()
    except ConfigError as exc:
        setup_logging()
        logging.getLogger("peri.config").error("configuration error: %s", exc)
        return 2
    setup_logging(log_level_number(cfg.log_level))
    log = logging.getLogger("peri")
    for line in summarize(cfg):
        log.info(line)
    try:
        app = create_app(cfg)
    except ConfigError as exc:
        log.error("cannot start: %s", exc)
        return 2
    web.run_app(app, host=cfg.bind, port=cfg.port, access_log=None, print=None, shutdown_timeout=5.0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
