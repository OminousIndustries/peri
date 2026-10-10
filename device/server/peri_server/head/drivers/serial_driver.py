"""Head driver for the Arduino Nano running ``firmware/peri_head`` over USB serial (protocol v1, see firmware/README.md).

Design notes
* One I/O thread owns the port: it scans ``/dev/ttyUSB*``/``/dev/ttyACM*`` (or the configured port) for a device that
  answers with ``PERI-HEAD 1 ...``, then runs the session, and starts over when the link dies (unplug/replug works).
* Opening the port resets the Nano (DTR). Its bootloader (Optiboot) reboots *again* if it receives stray bytes, so after
  opening we stay silent and just listen for the boot banner; ``HELLO`` is only sent after a quiet period (in case the
  board did not reset).
* Commands are asynchronous: ``move_to`` updates the local view optimistically and waits for the matching ``P`` reply.
  ``P`` lines received while a command is outstanding and not matching it are ignored (they may predate the command).
* An unsolicited banner means the Nano reset (brown-out, DTR): the position reference is lost, ``epoch`` increases and the
  controller re-derives its calibrated angle.
"""
from __future__ import annotations

import asyncio
import glob
import logging
import os
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

from .. import protocol
from .base import DriverState, HeadDriver, StepScale

log = logging.getLogger("peri.head")


class DriverUnavailable(RuntimeError):
    """The head is not connected (yet)."""


def default_port_lister() -> List[str]:
    """Candidate serial ports, de-duplicated by real path (``/dev/peri-head`` is a udev symlink to one of them)."""
    seen: Dict[str, str] = {}
    for pattern in ("/dev/peri-head", "/dev/ttyUSB*", "/dev/ttyACM*"):
        for path in sorted(glob.glob(pattern)):
            seen.setdefault(os.path.realpath(path), path)
    return list(seen.keys())


@dataclass
class _Cmd:
    line: str
    predicate: Callable[[protocol.PState], bool]
    future: "asyncio.Future[Optional[protocol.PState]]"
    loop: asyncio.AbstractEventLoop
    sent: bool = False
    sent_at: float = 0.0


@dataclass
class _Shared:
    """State shared between the I/O thread and the event loop (guarded by ``lock``)."""

    lock: threading.Lock = field(default_factory=threading.Lock)
    connected: bool = False
    port: str = ""
    pos: int = 0
    target: int = 0
    moving: bool = False
    energised: bool = False
    epoch: int = 0
    error: Optional[str] = None
    detail: str = ""


class SerialDriver(HeadDriver):
    name = "serial"

    HELLO_AFTER_S = 3.0      # silence after open before the first HELLO (bootloader reset window, see module docstring)
    HELLO_EVERY_S = 1.5

    def __init__(self, scale: StepScale, port: str = "", *, baud: int = 115200, scan_interval: float = 3.0,
                 boot_wait: float = 8.0, ack_timeout: float = 1.5, poll_interval: float = 1.0,
                 hello_after: Optional[float] = None, port_lister: Optional[Callable[[], List[str]]] = None,
                 serial_factory: Optional[Callable[..., Any]] = None, skip_bad_port_s: float = 60.0) -> None:
        super().__init__()
        self.scale = scale
        self._port = port
        self._baud = baud
        self._scan_interval = scan_interval
        self._boot_wait = boot_wait
        self._ack_timeout = ack_timeout
        self._poll_interval = poll_interval
        self._hello_after = self.HELLO_AFTER_S if hello_after is None else hello_after
        self._lister = port_lister or default_port_lister
        self._serial_factory = serial_factory
        self._skip_bad_port_s = skip_bad_port_s
        self._sh = _Shared()
        #: commands registered by the event loop and written, in order, by the I/O thread (FIFO = reply order)
        self._pending: List[_Cmd] = []
        self._plock = threading.Lock()
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._bad_ports: Dict[str, float] = {}

    # ------------------------------------------------------------------------------------------- lifecycle
    async def start(self) -> None:
        if self._thread is not None:
            return
        self._loop = asyncio.get_event_loop()
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._main, name="peri-serial", daemon=True)
        self._thread.start()

    async def stop(self) -> None:
        self._stop_event.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            await asyncio.get_event_loop().run_in_executor(None, thread.join, 3.0)

    # ---------------------------------------------------------------------------------------------- state
    def snapshot(self) -> DriverState:
        with self._sh.lock:
            sh = self._sh
            detail = sh.detail
            if not sh.connected and not detail:
                detail = "scanning for the head controller on USB serial"
            return DriverState(
                driver="serial", connected=sh.connected, position_deg=self.scale.to_deg(sh.pos),
                target_deg=self.scale.to_deg(sh.target), moving=sh.moving, energised=sh.energised, epoch=sh.epoch,
                error=sh.error, detail=detail)

    def _emit_threadsafe(self) -> None:
        loop = self._loop
        if loop is not None and not loop.is_closed():
            try:
                loop.call_soon_threadsafe(self._emit)
            except RuntimeError:  # loop closed while shutting down
                pass

    # -------------------------------------------------------------------------------------------- commands
    async def move_to(self, target_deg: float, max_dps: float, accel_dps2: float) -> None:
        steps = self.scale.to_steps(target_deg)
        line = protocol.format_move(steps, self.scale.rate_to_steps(max_dps), self.scale.rate_to_steps(accel_dps2))
        with self._sh.lock:
            if self._sh.connected:
                self._sh.target = steps
                self._sh.moving = steps != self._sh.pos
                self._sh.energised = True
        await self._command(line, lambda p: p.target == steps)

    async def halt(self) -> None:
        await self._command("S", lambda p: True)

    async def emergency_stop(self) -> None:
        await self._command("X", lambda p: not p.moving)

    async def release(self) -> None:
        await self._command("R", lambda p: not p.energised)

    async def set_zero(self) -> None:
        await self._command("Z", lambda p: p.pos == 0 and p.target == 0)

    async def _command(self, line: str, predicate: Callable[[protocol.PState], bool]) -> Optional[protocol.PState]:
        if not self._sh.connected:
            raise DriverUnavailable("head controller not connected")
        loop = asyncio.get_event_loop()
        cmd = _Cmd(line, predicate, loop.create_future(), loop)
        with self._plock:            # registered before it is written, so stale P lines are ignored from now on
            self._pending.append(cmd)
        try:
            return await asyncio.wait_for(cmd.future, self._ack_timeout * 2)
        except asyncio.TimeoutError:
            log.warning("head controller did not acknowledge %r", line.split()[0])
            return None

    # ------------------------------------------------------------------------------------------ I/O thread
    def _main(self) -> None:
        while not self._stop_event.is_set():
            ser = None
            try:
                found = self._find_device()
                if found is not None:
                    ser, banner = found
                    self._run_session(ser, banner)
            except Exception:
                log.exception("serial head driver crashed; will retry")
            finally:
                if ser is not None:
                    try:
                        ser.close()
                    except Exception:
                        pass
                self._mark_disconnected()
            self._stop_event.wait(self._scan_interval)

    def _open(self, path: str) -> Any:
        if self._serial_factory is not None:
            return self._serial_factory(path, self._baud)
        try:
            import serial  # imported lazily: pyserial is optional (python3-serial)
        except ImportError as exc:
            raise RuntimeError("python3-serial (pyserial) is not installed: sudo apt install python3-serial") from exc
        try:
            return serial.Serial(path, self._baud, timeout=0.02, write_timeout=1.0, exclusive=True)
        except TypeError:  # pyserial < 3.3 has no `exclusive`
            return serial.Serial(path, self._baud, timeout=0.02, write_timeout=1.0)

    def _candidates(self) -> List[str]:
        now = time.monotonic()
        ports = [self._port] if self._port else self._lister()
        return [p for p in ports if self._bad_ports.get(p, 0.0) <= now]

    def _find_device(self) -> Optional[Tuple[Any, protocol.Banner]]:
        for path in self._candidates():
            if self._stop_event.is_set():
                return None
            try:
                ser = self._open(path)
            except Exception as exc:  # busy, permission denied, vanished, pyserial missing ...
                self._set_error(str(exc) if isinstance(exc, RuntimeError) else f"cannot open {path}: {exc}")
                log.warning("cannot open %s: %s", path, exc)
                self._bad_ports[path] = time.monotonic() + (5.0 if self._port else self._skip_bad_port_s / 6)
                continue
            banner = self._wait_for_banner(ser)
            if banner is not None:
                with self._sh.lock:
                    self._sh.port = path
                return ser, banner
            log.info("%s did not identify as a Peri head controller; ignoring it for a while", path)
            self._bad_ports[path] = time.monotonic() + self._skip_bad_port_s
            note = f"{path} did not answer HELLO (is the Peri firmware flashed on the Nano?)"
            if self._port:
                self._set_error(note)       # explicitly configured port: an actionable error
            else:
                self._set_detail(note)      # auto-scan: might simply be an unrelated USB serial device
            try:
                ser.close()
            except Exception:
                pass
        return None

    def _wait_for_banner(self, ser: Any) -> Optional[protocol.Banner]:
        reader = _LineReader(ser)
        started = time.monotonic()
        next_hello = started + self._hello_after
        while time.monotonic() - started < self._boot_wait and not self._stop_event.is_set():
            now = time.monotonic()
            if now >= next_hello:
                self._write(ser, "HELLO")
                next_hello = now + self.HELLO_EVERY_S
            for line in reader.read_lines():
                message = protocol.parse_line(line)
                if isinstance(message, protocol.Banner) and message.version == protocol.PROTOCOL_VERSION:
                    return message
        return None

    def _write(self, ser: Any, line: str) -> None:
        ser.write((line + "\n").encode("ascii"))
        try:
            ser.flush()
        except Exception:
            pass

    def _run_session(self, ser: Any, banner: protocol.Banner) -> None:
        reader = _LineReader(ser)
        with self._plock:
            self._pending.clear()
        self._mark_connected(banner)
        log.info("head controller found on %s (protocol %d, %d half-steps/rev)", self._sh.port, banner.version,
                 banner.half_steps_per_rev)
        last_rx = time.monotonic()
        last_poll = last_rx
        self._write(ser, "Q")
        try:
            while not self._stop_event.is_set():
                # outgoing: write every registered-but-unsent command, in registration order
                with self._plock:
                    unsent = [c for c in self._pending if not c.sent]
                for cmd in unsent:
                    self._write(ser, cmd.line)
                    cmd.sent = True
                    cmd.sent_at = time.monotonic()
                # incoming
                lines = reader.read_lines()
                now = time.monotonic()
                if lines:
                    last_rx = now
                for line in lines:
                    if self._handle_line(line):
                        self._write(ser, "Q")           # reset detected: refresh state
                self._expire(now)
                # keep-alive / liveness
                with self._plock:
                    idle = not self._pending
                if idle and not self._sh.moving and now - last_poll >= self._poll_interval:
                    self._write(ser, "Q")
                    last_poll = now
                if now - last_rx > max(3.0, self._poll_interval * 3):
                    raise TimeoutError("no data from the head controller")
        except Exception as exc:
            log.warning("head controller link lost: %s", exc)
            self._set_detail(f"link lost: {exc}")
        finally:
            with self._plock:
                dropped, self._pending = self._pending, []
            for cmd in dropped:
                self._resolve(cmd, None, DriverUnavailable("head controller disconnected"))

    def _handle_line(self, line: str) -> bool:
        """Process one device line; returns True when a reset banner was seen."""
        message = protocol.parse_line(line)
        if isinstance(message, protocol.Banner):
            log.warning("head controller reset (banner received unsolicited): position reference lost")
            with self._sh.lock:
                self._sh.epoch += 1
                self._sh.pos = self._sh.target = 0
                self._sh.moving = self._sh.energised = False
            with self._plock:
                dropped, self._pending = self._pending, []
            for cmd in dropped:
                self._resolve(cmd, None, DriverUnavailable("head controller reset"))
            self._emit_threadsafe()
            return True
        if isinstance(message, protocol.Err):
            log.warning("head controller replied ERR %s", message.code)
            with self._plock:
                failed = self._pending.pop(0) if self._pending and self._pending[0].sent else None
            if failed is not None:
                self._resolve(failed, None, RuntimeError(f"head controller error {message.code}"))
            return False
        if isinstance(message, protocol.PState):
            with self._plock:
                head = self._pending[0] if self._pending else None
                if head is not None:
                    if head.sent and head.predicate(message):
                        self._pending.pop(0)
                    else:
                        return False        # possibly stale relative to the outstanding command
            if head is not None:
                self._resolve(head, message, None)
            with self._sh.lock:
                self._sh.pos, self._sh.target = message.pos, message.target
                self._sh.moving, self._sh.energised = message.moving, message.energised
                self._sh.error = None
            self._emit_threadsafe()
            return False
        log.debug("ignoring unexpected line from head controller: %r", line[:60])
        return False

    def _expire(self, now: float) -> None:
        while True:
            with self._plock:
                if not (self._pending and self._pending[0].sent and now - self._pending[0].sent_at > self._ack_timeout):
                    return
                cmd = self._pending.pop(0)
            log.warning("no reply to %r within %.1fs", cmd.line.split()[0], self._ack_timeout)
            self._resolve(cmd, None, None)

    @staticmethod
    def _resolve(cmd: _Cmd, value: Optional[protocol.PState], exc: Optional[BaseException]) -> None:
        def apply() -> None:
            if cmd.future.done():
                return
            if exc is not None:
                cmd.future.set_exception(exc)
            else:
                cmd.future.set_result(value)  # type: ignore[arg-type]

        try:
            cmd.loop.call_soon_threadsafe(apply)
        except RuntimeError:
            pass

    # ------------------------------------------------------------------------------------- state changes
    def _mark_connected(self, banner: protocol.Banner) -> None:
        with self._sh.lock:
            self._sh.connected = True
            self._sh.epoch += 1
            self._sh.pos = self._sh.target = 0
            self._sh.moving = self._sh.energised = False
            self._sh.error = None
            self._sh.detail = f"{self._sh.port} (firmware {banner.extra or 'unknown'})"
        self._emit_threadsafe()

    def _mark_disconnected(self) -> None:
        with self._sh.lock:
            was = self._sh.connected
            self._sh.connected = False
            self._sh.moving = False
            self._sh.energised = False
        if was:
            self._emit_threadsafe()

    def _set_error(self, message: str) -> None:
        """Actionable failure (e.g. permission denied): surfaced as ``error`` until a connection succeeds."""
        with self._sh.lock:
            self._sh.error = message
            self._sh.detail = message

    def _set_detail(self, message: str) -> None:
        """Informational note (shown by /api/diag); does not block motion commands."""
        with self._sh.lock:
            self._sh.detail = message


class _LineReader:
    """Non-blocking-ish line splitter over a pyserial-like object (``read``/``in_waiting``, short timeout)."""

    MAX_LINE = 256

    def __init__(self, ser: Any) -> None:
        self._ser = ser
        self._buf = bytearray()

    def read_lines(self) -> List[str]:
        waiting = getattr(self._ser, "in_waiting", 0) or 1
        chunk = self._ser.read(min(int(waiting), 512))
        if not chunk:
            return []
        self._buf.extend(chunk)
        lines: List[str] = []
        while True:
            index = self._buf.find(b"\n")
            if index < 0:
                break
            raw = bytes(self._buf[:index]).strip(b"\r")
            del self._buf[: index + 1]
            if raw:
                lines.append(raw.decode("ascii", "replace"))
        if len(self._buf) > self.MAX_LINE:
            self._buf.clear()
        return lines
