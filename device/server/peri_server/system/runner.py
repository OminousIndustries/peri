"""Async subprocess helper with timeouts. Tests replace it with a fake exposing the same ``run`` method."""
from __future__ import annotations

import asyncio
import logging
import os
import shutil
from dataclasses import dataclass
from typing import Dict, Mapping, Optional, Sequence

log = logging.getLogger("peri.system")

NOT_FOUND = -1
TIMED_OUT = -2


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""
    stdout_bytes: bytes = b""     # raw output (for binary tools such as arecord -t raw)

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def runtime_env(extra: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
    """Environment for audio tools: make sure XDG_RUNTIME_DIR points at the user manager's runtime dir (PipeWire socket)."""
    env = dict(os.environ)
    if not env.get("XDG_RUNTIME_DIR"):
        candidate = f"/run/user/{os.getuid()}"
        if os.path.isdir(candidate):
            env["XDG_RUNTIME_DIR"] = candidate
    env["LC_ALL"] = "C"          # parse-friendly output from wpctl/pactl/amixer/nmcli
    if extra:
        env.update(extra)
    return env


class CommandRunner:
    """Runs argv lists (never a shell). Missing binaries and timeouts are reported through the result, not raised."""

    def which(self, name: str) -> Optional[str]:
        return shutil.which(name, path=os.environ.get("PATH", "") + ":/usr/sbin:/sbin:/usr/local/sbin")

    async def run(self, argv: Sequence[str], timeout: float = 3.0, env: Optional[Mapping[str, str]] = None) -> CommandResult:
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                env=runtime_env(env))
        except (FileNotFoundError, PermissionError):
            return CommandResult(NOT_FOUND, "", f"{argv[0]}: not found")
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            await proc.wait()
            log.debug("timed out: %s", " ".join(argv))
            return CommandResult(TIMED_OUT, "", "timed out")
        return CommandResult(proc.returncode if proc.returncode is not None else 0,
                             out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), out)
