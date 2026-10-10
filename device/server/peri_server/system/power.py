"""Reboot / shutdown / restart actions (``POST /api/system/power``). Only ever acts on a Raspberry Pi device."""
from __future__ import annotations

import asyncio
import logging
import os
from typing import Awaitable, Callable, Dict, List, Optional

from .runner import CommandRunner

log = logging.getLogger("peri.power")

ACTIONS: Dict[str, List[str]] = {
    "reboot": ["reboot"],
    "shutdown": ["poweroff"],
    "restart-ui": ["restart", "peri-kiosk"],
    "restart-server": ["restart", "peri-server"],
}


class PowerManager:
    """Runs ``systemctl`` (through ``sudo -n`` when not root; see /etc/sudoers.d/peri-power) shortly after the HTTP reply."""

    DELAY_S = 0.7

    def __init__(self, runner: CommandRunner, enabled: bool, before_shutdown: Optional[Callable[[], Awaitable[None]]] = None) -> None:
        self.runner = runner
        self.enabled = enabled and runner.which("systemctl") is not None
        self._before = before_shutdown
        self._tasks: List["asyncio.Task[None]"] = []

    @property
    def supported(self) -> bool:
        return self.enabled

    def command(self, action: str) -> List[str]:
        systemctl = os.path.realpath(self.runner.which("systemctl") or "/usr/bin/systemctl")
        # sudoers lists the canonical path; `which` may return a /bin symlink on merged-usr systems
        prefix: List[str] = [] if os.geteuid() == 0 else ["sudo", "-n"]
        return prefix + [systemctl] + ACTIONS[action]

    def schedule(self, action: str) -> None:
        """Fire and forget: the caller has already answered 202."""
        task = asyncio.ensure_future(self._run(action))
        self._tasks.append(task)
        task.add_done_callback(lambda t: self._tasks.remove(t) if t in self._tasks else None)

    async def _run(self, action: str) -> None:
        await asyncio.sleep(self.DELAY_S)
        if action in ("reboot", "shutdown") and self._before is not None:
            try:
                await asyncio.wait_for(self._before(), 8.0)      # centre the neck so the next power-up starts centred
            except Exception:
                log.warning("head parking before %s failed or timed out", action, exc_info=True)
        argv = self.command(action)
        log.info("power action: %s", " ".join(argv))
        result = await self.runner.run(argv, timeout=20.0)
        if not result.ok:
            log.error("power action %s failed (%s): %s", action, result.returncode, result.stderr.strip()[:200])
