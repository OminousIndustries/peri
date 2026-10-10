"""Websocket hub: connected UI clients, broadcast, and the per-connection reader/writer plumbing for ``/api/ws``."""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Awaitable, Callable, Dict, List

import aiohttp
from aiohttp import web

from .constants import WS_HEAD_MSG_RATE
from .util import TokenBucket, loads_strict

log = logging.getLogger("peri.ws")

QUEUE_LIMIT = 256


class Client:
    """One connected websocket with an outgoing queue (a slow client never blocks the others)."""

    def __init__(self, ws: web.WebSocketResponse, remote: str) -> None:
        self.ws = ws
        self.remote = remote
        self.queue: "asyncio.Queue[str]" = asyncio.Queue(maxsize=QUEUE_LIMIT)
        self.head_bucket = TokenBucket(WS_HEAD_MSG_RATE, WS_HEAD_MSG_RATE)
        self.dropped = 0

    def offer(self, payload: str) -> None:
        try:
            self.queue.put_nowait(payload)
        except asyncio.QueueFull:                      # drop the oldest frame: the newest state is what matters
            try:
                self.queue.get_nowait()
                self.queue.put_nowait(payload)
            except (asyncio.QueueEmpty, asyncio.QueueFull):
                pass
            self.dropped += 1


MessageHandler = Callable[[Client, Dict[str, Any]], Awaitable[None]]


class Hub:
    def __init__(self) -> None:
        self._clients: List[Client] = []

    @property
    def count(self) -> int:
        return len(self._clients)

    def broadcast(self, message: Dict[str, Any]) -> int:
        """Queue ``message`` for every client; returns how many received it. Safe to call from any callback."""
        if not self._clients:
            return 0
        payload = json.dumps(message, separators=(",", ":"))
        for client in list(self._clients):
            client.offer(payload)
        return len(self._clients)

    async def serve(self, request: web.Request, hello: Dict[str, Any], on_message: MessageHandler) -> web.WebSocketResponse:
        ws = web.WebSocketResponse(heartbeat=20.0, max_msg_size=64 * 1024)
        await ws.prepare(request)
        client = Client(ws, request.remote or "?")
        self._clients.append(client)
        log.info("ui connected from %s (%d client%s)", client.remote, self.count, "" if self.count == 1 else "s")
        writer = asyncio.ensure_future(self._writer(client))
        try:
            client.offer(json.dumps(hello, separators=(",", ":")))
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    await self._dispatch(client, msg.data, on_message)
                elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE):
                    break
        finally:
            if client in self._clients:
                self._clients.remove(client)
            writer.cancel()
            try:
                await writer
            except (asyncio.CancelledError, Exception):
                pass
            log.info("ui disconnected (%d client%s left)", self.count, "" if self.count == 1 else "s")
        return ws

    async def _dispatch(self, client: Client, raw: str, on_message: MessageHandler) -> None:
        try:
            message = loads_strict(raw)
        except ValueError:
            log.debug("ignoring non-JSON websocket frame")
            return
        if not isinstance(message, dict) or not isinstance(message.get("t"), str):
            log.debug("ignoring websocket frame without a 't' field")
            return
        try:
            await on_message(client, message)
        except Exception:
            log.exception("error while handling websocket message %r", message.get("t"))

    @staticmethod
    async def _writer(client: Client) -> None:
        try:
            while True:
                payload = await client.queue.get()
                if client.ws.closed:
                    return
                await client.ws.send_str(payload)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.debug("websocket writer stopped", exc_info=True)

    async def close_all(self) -> None:
        for client in list(self._clients):
            try:
                await client.ws.close(code=1001, message=b"server shutting down")
            except Exception:
                pass
        self._clients.clear()
