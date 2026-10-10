"""Process configuration: environment variables (docs/API.md section 8) and the on-disk layout."""
from __future__ import annotations

import hashlib
import ipaddress
import logging
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Mapping, Optional, Tuple

from .constants import OPENAI_BASE_URL

log = logging.getLogger("peri.config")

#: <install>/server/peri_server/config.py -> <install>
INSTALL_DIR = Path(__file__).resolve().parents[2]

DEFAULT_PORT = 8420
DEFAULT_STATE_DIR = "/var/lib/peri"


class ConfigError(Exception):
    """The environment is unusable (the server refuses to start with this message)."""


def read_version(install_dir: Optional[Path] = None) -> str:
    """Contents of <install>/VERSION, or a dev placeholder."""
    path = (install_dir or INSTALL_DIR) / "VERSION"
    try:
        text = path.read_text(encoding="utf-8").strip()
        return text or "0.0.0-dev"
    except OSError:
        return "0.0.0-dev"


def _truthy(value: Optional[str]) -> bool:
    return (value or "").strip().lower() in ("1", "true", "yes", "on")


def _num(env: Mapping[str, str], name: str, default: float, lo: float, hi: float) -> float:
    """Parse a float env var; a bad or out-of-range value falls back to the (clamped) default with a warning."""
    raw = env.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
        if value != value or value in (float("inf"), float("-inf")):
            raise ValueError("not finite")
    except ValueError:
        log.warning("%s=%r is not a number; using %s", name, raw, default)
        return default
    if not lo <= value <= hi:
        clamped = min(max(value, lo), hi)
        log.warning("%s=%s is outside %s..%s; using %s", name, raw, lo, hi, clamped)
        return clamped
    return value


def _pins(raw: str) -> Tuple[int, ...]:
    try:
        pins = tuple(int(p) for p in re.split(r"[,\s]+", raw.strip()) if p)
    except ValueError as exc:
        raise ConfigError(f"PERI_HEAD_GPIO_PINS must be four comma separated BCM numbers, got {raw!r}") from exc
    if len(pins) != 4 or len(set(pins)) != 4 or any(not 0 <= p <= 27 for p in pins):
        raise ConfigError(f"PERI_HEAD_GPIO_PINS must be four distinct BCM numbers 0-27, got {raw!r}")
    return pins


def is_loopback_host(host: str) -> bool:
    """True for 127.0.0.0/8, ::1 and 'localhost' (the only binds that need no admin token)."""
    if host == "localhost":
        return True
    if not host:
        return False
    try:
        return ipaddress.ip_address(host.strip("[]")).is_loopback
    except ValueError:
        return False


@dataclass(frozen=True)
class ServerConfig:
    """Everything the server needs from its environment. The API key is excluded from repr/logging on purpose."""

    port: int = DEFAULT_PORT
    bind: str = "127.0.0.1"
    admin_token: str = field(default="", repr=False)
    openai_api_key: str = field(default="", repr=False)
    openai_base_url: str = OPENAI_BASE_URL
    install_dir: Path = INSTALL_DIR
    web_dir: Path = INSTALL_DIR / "web"
    config_dir: Path = INSTALL_DIR / "config"
    state_dir: Path = Path(DEFAULT_STATE_DIR)
    head_driver: str = "auto"
    head_serial_port: str = ""
    head_gpio_pins: Tuple[int, ...] = (5, 6, 13, 26)
    head_invert: bool = False
    head_steps_per_rev: float = 4075.7728
    head_gear_ratio: float = 5.1
    head_max_speed_dps: float = 16.0
    head_accel_dps2: float = 40.0
    head_hard_limit_deg: float = 25.0
    head_release_after_s: float = 2.5
    log_level: str = "info"
    dev: bool = False
    #: None = auto (only touch volume/brightness/default audio device on a Raspberry Pi); True/False force it
    hw_control: Optional[bool] = None
    version: str = "0.0.0-dev"

    @property
    def steps_per_deg(self) -> float:
        """Half-steps per degree of neck rotation (about 57.74 with the stock gear train)."""
        return self.head_steps_per_rev * self.head_gear_ratio / 360.0

    @property
    def loopback_bind(self) -> bool:
        return is_loopback_host(self.bind)

    @property
    def openai_configured(self) -> bool:
        return bool(self.openai_api_key)

    @classmethod
    def from_env(cls, env: Optional[Mapping[str, str]] = None) -> "ServerConfig":
        env = os.environ if env is None else env
        dev = _truthy(env.get("PERI_DEV"))
        install_dir = Path(env["PERI_INSTALL_DIR"]) if env.get("PERI_INSTALL_DIR") else INSTALL_DIR
        state_default = str(install_dir / ".state-dev") if dev else DEFAULT_STATE_DIR

        try:
            port = int(env.get("PERI_PORT", str(DEFAULT_PORT)) or DEFAULT_PORT)
        except ValueError as exc:
            raise ConfigError(f"PERI_PORT must be an integer, got {env.get('PERI_PORT')!r}") from exc
        if not 1 <= port <= 65535:
            raise ConfigError(f"PERI_PORT out of range: {port}")

        bind = (env.get("PERI_BIND") or "127.0.0.1").strip()
        token = (env.get("PERI_ADMIN_TOKEN") or "").strip()
        if not is_loopback_host(bind) and not token:
            raise ConfigError(
                f"PERI_BIND={bind} exposes the server to the network: set PERI_ADMIN_TOKEN (any long random string) "
                "or bind to 127.0.0.1"
            )

        driver = (env.get("PERI_HEAD_DRIVER") or "auto").strip().lower()
        if driver not in ("auto", "serial", "gpio", "sim", "none"):
            raise ConfigError(f"PERI_HEAD_DRIVER must be auto|serial|gpio|sim|none, got {driver!r}")

        return cls(
            port=port,
            bind=bind,
            admin_token=token,
            # systemd EnvironmentFile keeps quotes/CR from hand-edited files; strip the usual accidents.
            openai_api_key=(env.get("OPENAI_API_KEY") or "").strip().strip("\"'"),
            openai_base_url=(env.get("PERI_OPENAI_BASE_URL") or OPENAI_BASE_URL).rstrip("/"),
            install_dir=install_dir,
            web_dir=Path(env["PERI_WEB_DIR"]) if env.get("PERI_WEB_DIR") else install_dir / "web",
            config_dir=Path(env["PERI_CONFIG_DIR"]) if env.get("PERI_CONFIG_DIR") else install_dir / "config",
            state_dir=Path(env.get("PERI_STATE_DIR") or state_default),
            head_driver=driver,
            head_serial_port=(env.get("PERI_HEAD_SERIAL_PORT") or "").strip(),
            head_gpio_pins=_pins(env.get("PERI_HEAD_GPIO_PINS") or "5,6,13,26"),
            head_invert=_truthy(env.get("PERI_HEAD_INVERT")),
            head_steps_per_rev=_num(env, "PERI_HEAD_STEPS_PER_REV", 4075.7728, 100.0, 100000.0),
            head_gear_ratio=_num(env, "PERI_HEAD_GEAR_RATIO", 5.1, 0.1, 100.0),
            head_max_speed_dps=_num(env, "PERI_HEAD_MAX_SPEED_DPS", 16.0, 1.0, 60.0),
            head_accel_dps2=_num(env, "PERI_HEAD_ACCEL_DPS2", 40.0, 2.0, 400.0),
            head_hard_limit_deg=_num(env, "PERI_HEAD_HARD_LIMIT_DEG", 25.0, 1.0, 180.0),
            head_release_after_s=_num(env, "PERI_HEAD_RELEASE_AFTER_S", 2.5, 0.0, 600.0),
            log_level=(env.get("PERI_LOG_LEVEL") or ("debug" if dev else "info")).strip().lower(),
            dev=dev,
            hw_control=_truthy(env.get("PERI_HW_CONTROL")) if (env.get("PERI_HW_CONTROL") or "").strip() else None,
            version=read_version(install_dir),
        )


def device_id(env: Optional[Mapping[str, str]] = None) -> str:
    """Stable short id such as ``peri-3f9a`` derived from the machine id (or Pi serial, or hostname)."""
    seed = ""
    for path in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            seed = Path(path).read_text().strip()
        except OSError:
            continue
        if seed:
            break
    if not seed:
        try:
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.lower().startswith("serial"):
                    seed = line.split(":", 1)[1].strip()
        except OSError:
            pass
    if not seed:
        seed = os.uname().nodename
    return "peri-" + hashlib.sha256(seed.encode()).hexdigest()[:4]


def log_level_number(name: str) -> int:
    levels: Dict[str, int] = {
        "debug": logging.DEBUG, "info": logging.INFO, "warning": logging.WARNING, "warn": logging.WARNING,
        "error": logging.ERROR, "critical": logging.CRITICAL,
    }
    return levels.get(name.lower(), logging.INFO)


def summarize(cfg: ServerConfig) -> List[str]:
    """Human-readable startup lines (never contains secrets)."""
    return [
        f"version {cfg.version}, listening on {cfg.bind}:{cfg.port} ({'loopback only' if cfg.loopback_bind else 'network, token required'})",
        f"web dir {cfg.web_dir}, config dir {cfg.config_dir}, state dir {cfg.state_dir}",
        f"openai key {'configured' if cfg.openai_configured else 'NOT configured'}; head driver {cfg.head_driver}; dev={cfg.dev}",
        f"neck: {cfg.steps_per_deg:.2f} half-steps/deg, max {cfg.head_max_speed_dps:g} deg/s, accel {cfg.head_accel_dps2:g} deg/s2, "
        f"hard limit +-{cfg.head_hard_limit_deg:g} deg, invert={cfg.head_invert}",
    ]
