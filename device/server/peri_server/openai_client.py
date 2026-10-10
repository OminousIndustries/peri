"""Thin async client for the parts of the OpenAI API the device uses (Realtime calls, client secrets, key check)."""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass
from typing import Any, Dict, Optional, Set, Tuple

import aiohttp

from .errors import ApiError, unavailable
from .logging_setup import redact
from .util import truncate

log = logging.getLogger("peri.openai")

USER_AGENT = "peri-device"


class UpstreamError(Exception):
    """OpenAI (or the network path to it) refused or failed. ``status`` is the upstream HTTP status, None if unreachable."""

    def __init__(self, message: str, status: Optional[int] = None, param: str = "", code: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.status = status
        self.param = param
        self.code = code

    def rejects_reasoning(self) -> bool:
        """True when a 400 says the ``reasoning`` field is not accepted for this model."""
        if self.status != 400:
            return False
        blob = f"{self.message} {self.param} {self.code}".lower()
        return "reasoning" in blob

    def to_api_error(self) -> ApiError:
        return ApiError(502, "upstream", redact(truncate(self.message, 400)), status=self.status)


@dataclass(frozen=True)
class CallResult:
    sdp: str
    call_id: Optional[str]


_HTML_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)


def _plain_text_error(status: int, text: str) -> str:
    """A short message for a non-JSON error body (typically a Cloudflare HTML page for 502/504)."""
    if "<" in text[:200]:
        title = _HTML_TITLE_RE.search(text)
        detail = re.sub(r"\s+", " ", title.group(1)).strip() if title else ""
        return f"OpenAI returned HTTP {status}" + (f" ({detail})" if detail else " (an HTML error page)")
    return text


def _parse_error(status: int, body: bytes) -> UpstreamError:
    message, param, code = f"HTTP {status}", "", ""
    try:
        data = json.loads(body.decode("utf-8", "replace"))
        err = data.get("error") if isinstance(data, dict) else None
        if isinstance(err, dict):
            message = str(err.get("message") or message)
            param = str(err.get("param") or "")
            code = str(err.get("code") or "")
        elif isinstance(err, str):
            message = err
    except ValueError:
        text = body.decode("utf-8", "replace").strip()
        if text:
            message = _plain_text_error(status, text)
    return UpstreamError(redact(truncate(message, 500)), status, param, code)


def call_id_from_location(location: Optional[str]) -> Optional[str]:
    """Last path segment of the ``Location`` header of POST /v1/realtime/calls (e.g. ``rtc_...``)."""
    if not location:
        return None
    segment = location.split("?", 1)[0].rstrip("/").rsplit("/", 1)[-1]
    return segment or None


class OpenAIClient:
    """One shared aiohttp session; the API key lives only here and in request headers."""

    def __init__(self, api_key: str, base_url: str = "https://api.openai.com", timeout_s: float = 30.0) -> None:
        self._key = api_key
        self._base = base_url.rstrip("/")
        self._timeout = aiohttp.ClientTimeout(total=timeout_s)
        self._session: Optional[aiohttp.ClientSession] = None

    def _http(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(timeout=self._timeout, headers={"User-Agent": USER_AGENT})
        return self._session

    async def close(self) -> None:
        if self._session is not None and not self._session.closed:
            await self._session.close()

    def _auth(self) -> Dict[str, str]:
        return {"Authorization": f"Bearer {self._key}"}

    async def _send(self, method: str, path: str, **kwargs: Any) -> Tuple[int, Dict[str, str], bytes]:
        url = self._base + path
        try:
            async with self._http().request(method, url, headers=self._auth(), **kwargs) as resp:
                body = await resp.read()
                return resp.status, dict(resp.headers), body
        except asyncio.TimeoutError as exc:
            raise UpstreamError("timed out talking to api.openai.com") from exc
        except aiohttp.ClientError as exc:
            raise UpstreamError(f"could not reach api.openai.com ({type(exc).__name__})") from exc

    async def create_call(self, sdp: str, session: Dict[str, Any]) -> CallResult:
        """Unified-interface WebRTC handshake: multipart ``sdp`` + ``session`` -> SDP answer (+ call id from Location)."""
        form = aiohttp.FormData()
        form.add_field("sdp", sdp, content_type="application/sdp")
        form.add_field("session", json.dumps(session), content_type="application/json")
        status, headers, body = await self._send("POST", "/v1/realtime/calls", data=form)
        if status >= 400:
            raise _parse_error(status, body)
        location = next((v for k, v in headers.items() if k.lower() == "location"), None)
        return CallResult(sdp=body.decode("utf-8", "replace"), call_id=call_id_from_location(location))

    async def create_client_secret(self, session: Dict[str, Any], ttl_s: int = 600) -> Dict[str, Any]:
        """Mint an ephemeral client secret (``ek_...``) for a session configuration."""
        payload = {"expires_after": {"anchor": "created_at", "seconds": ttl_s}, "session": session}
        status, _headers, body = await self._send("POST", "/v1/realtime/client_secrets", json=payload)
        if status >= 400:
            raise _parse_error(status, body)
        try:
            data = json.loads(body.decode("utf-8"))
        except ValueError as exc:
            raise UpstreamError("OpenAI returned a non-JSON response for client_secrets", status) from exc
        if not isinstance(data, dict):
            raise UpstreamError("unexpected client_secrets response", status)
        return data

    async def check_key(self) -> Tuple[bool, Optional[str]]:
        """Auth + reachability probe (GET /v1/models). Returns ``(reachable, last_error)``."""
        try:
            status, _h, body = await self._send("GET", "/v1/models", params={"limit": "1"})
        except UpstreamError as exc:
            return False, exc.message
        if status == 200:
            return True, None
        if status == 429:
            return True, "rate limited by OpenAI (HTTP 429)"
        err = _parse_error(status, body)
        if status in (401, 403):
            return False, f"OpenAI rejected the API key (HTTP {status}): {err.message}"
        return False, f"OpenAI error (HTTP {status}): {err.message}"


class ReachabilityCache:
    """``openai.reachable`` for /api/system/status: refreshed at most every ``max_age_s``, never blocks a request."""

    def __init__(self, client: Optional[OpenAIClient], max_age_s: float = 60.0,
                 clock: Any = time.monotonic) -> None:
        self._client = client
        self._max_age = max_age_s
        self._clock = clock
        self.reachable: Optional[bool] = None
        self.last_error: Optional[str] = None
        self._checked_at: Optional[float] = None
        self._task: Optional["asyncio.Task[None]"] = None

    def snapshot(self) -> Dict[str, Any]:
        """Return the cached values and kick off a refresh in the background when they are stale."""
        self.refresh_if_stale()
        return {"reachable": self.reachable, "last_error": self.last_error}

    def refresh_if_stale(self) -> None:
        if self._client is None:
            return
        stale = self._checked_at is None or self._clock() - self._checked_at >= self._max_age
        if stale and (self._task is None or self._task.done()):
            self._task = asyncio.ensure_future(self._refresh())

    async def _refresh(self) -> None:
        assert self._client is not None
        try:
            self.reachable, self.last_error = await self._client.check_key()
        except Exception as exc:  # pragma: no cover - defensive: never let the probe kill the loop
            self.reachable, self.last_error = False, f"{type(exc).__name__}: {exc}"
        self._checked_at = self._clock()

    async def refresh_now(self) -> Dict[str, Any]:
        """Force a check and wait for it (used by /api/diag)."""
        if self._client is not None:
            await self._refresh()
        return {"reachable": self.reachable, "last_error": self.last_error}

    async def stop(self) -> None:
        if self._task is not None and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):
                pass


class RealtimeService:
    """Session creation with the settings/persona logic and the per-model ``reasoning`` fallback."""

    def __init__(self, client: Optional[OpenAIClient]) -> None:
        self._client = client
        #: models that answered 400 to the ``reasoning`` field (remembered until restart)
        self.no_reasoning: Set[str] = set()

    def _require(self) -> OpenAIClient:
        if self._client is None:
            raise unavailable("no_api_key", "no OpenAI API key is configured (set OPENAI_API_KEY, see `peri-config set`)")
        return self._client

    def include_reasoning(self, model: str) -> bool:
        return model not in self.no_reasoning

    async def create_call(self, sdp: str, build: Any, model: str) -> CallResult:
        """``build(include_reasoning)`` -> session dict. Retries once without ``reasoning`` if the model rejects it."""
        client = self._require()
        try:
            return await client.create_call(sdp, build(self.include_reasoning(model)))
        except UpstreamError as exc:
            if not (self.include_reasoning(model) and exc.rejects_reasoning()):
                raise
            log.warning("model %s rejects the reasoning field; retrying without it (remembered)", model)
            self.no_reasoning.add(model)
            return await client.create_call(sdp, build(False))

    async def create_token(self, build: Any, model: str) -> Dict[str, Any]:
        client = self._require()
        try:
            return await client.create_client_secret(build(self.include_reasoning(model)))
        except UpstreamError as exc:
            if not (self.include_reasoning(model) and exc.rejects_reasoning()):
                raise
            log.warning("model %s rejects the reasoning field; retrying without it (remembered)", model)
            self.no_reasoning.add(model)
            return await client.create_client_secret(build(False))
