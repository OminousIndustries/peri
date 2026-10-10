"""Static UI hosting: files from PERI_WEB_DIR, SPA fallback to index.html, sensible cache headers."""
from __future__ import annotations

import mimetypes
from pathlib import Path
from typing import Dict, Optional

from aiohttp import web

from ..errors import not_found
from .common import ctx_of

for _ext, _type in {".woff2": "font/woff2", ".woff": "font/woff", ".mjs": "text/javascript", ".js": "text/javascript",
                    ".webmanifest": "application/manifest+json", ".wasm": "application/wasm", ".svg": "image/svg+xml",
                    ".map": "application/json", ".avif": "image/avif", ".webp": "image/webp"}.items():
    mimetypes.add_type(_type, _ext)

LONG_CACHE_EXT = {".woff", ".woff2", ".ttf", ".otf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".svg",
                  ".mp3", ".ogg", ".wav"}
LONG_CACHE = "public, max-age=604800"
NO_CACHE = "no-cache"
COMMON_HEADERS: Dict[str, str] = {"X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"}


def resolve_file(web_dir: Path, tail: str) -> Optional[Path]:
    """Map a URL path to a file inside ``web_dir`` (never outside it); a directory maps to its index.html."""
    rel = tail.lstrip("/")
    if rel.startswith("web/"):
        rel = rel[4:]
    root = web_dir.resolve()
    try:
        candidate = (root / rel).resolve()
        candidate.relative_to(root)
    except (ValueError, OSError):
        return None
    if candidate.is_dir():
        candidate = candidate / "index.html"
    return candidate if candidate.is_file() else None


def cache_control(path: Path, dev: bool) -> str:
    if dev:
        return NO_CACHE
    return LONG_CACHE if path.suffix.lower() in LONG_CACHE_EXT else NO_CACHE


def content_type(path: Path) -> str:
    """MIME type from our extended table (aiohttp's FileResponse keeps its own, older table: fonts would be octet-stream)."""
    guessed, _encoding = mimetypes.guess_type(path.name)
    return guessed or "application/octet-stream"


def file_response(path: Path, dev: bool) -> web.FileResponse:
    headers = dict(COMMON_HEADERS)
    headers["Cache-Control"] = cache_control(path, dev)
    headers["Content-Type"] = content_type(path)
    return web.FileResponse(path, headers=headers)


async def handle_static(request: web.Request) -> web.StreamResponse:
    ctx = ctx_of(request)
    tail = request.match_info.get("tail", "")
    if tail.startswith("api/") or tail == "api":
        raise not_found("unknown API endpoint")
    found = resolve_file(ctx.cfg.web_dir, tail)
    if found is not None:
        return file_response(found, ctx.cfg.dev)
    name = tail.rsplit("/", 1)[-1]
    if "." in name:                                # a missing asset must be a 404, not index.html (wrong MIME breaks scripts)
        raise web.HTTPNotFound(text="not found\n")
    index = resolve_file(ctx.cfg.web_dir, "index.html")
    if index is None:
        return web.Response(status=503, content_type="text/plain", text=(
            f"Peri UI not installed: {ctx.cfg.web_dir / 'index.html'} is missing (set PERI_WEB_DIR or re-run the installer).\n"))
    return file_response(index, dev=True)          # the SPA shell itself is never cached
