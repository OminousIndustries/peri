"""Plain readers for host metrics (CPU temperature, memory, load, uptime, Wi-Fi). ``root`` lets tests point at a fake tree."""
from __future__ import annotations

import math
import os
import re
import socket
import struct
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple


def read_cpu_temp_c(root: Path = Path("/")) -> Optional[float]:
    try:
        raw = (root / "sys/class/thermal/thermal_zone0/temp").read_text().strip()
        return round(int(raw) / 1000.0, 1)
    except (OSError, ValueError):
        return None


def parse_vcgencmd_temp(text: str) -> Optional[float]:
    match = re.search(r"temp=([0-9.]+)", text)
    return float(match.group(1)) if match else None


def read_meminfo(root: Path = Path("/")) -> Dict[str, int]:
    """``{"total_mb": .., "available_mb": ..}`` (zeros when /proc/meminfo is unavailable)."""
    values: Dict[str, int] = {}
    try:
        for line in (root / "proc/meminfo").read_text().splitlines():
            key, _, rest = line.partition(":")
            if key in ("MemTotal", "MemAvailable", "MemFree"):
                values[key] = int(rest.split()[0])
    except (OSError, ValueError, IndexError):
        pass
    available = values.get("MemAvailable", values.get("MemFree", 0))
    return {"total_mb": values.get("MemTotal", 0) // 1024, "available_mb": available // 1024}


def read_uptime_s(root: Path = Path("/")) -> int:
    try:
        return int(float((root / "proc/uptime").read_text().split()[0]))
    except (OSError, ValueError, IndexError):
        return 0


def read_load() -> List[float]:
    try:
        return [round(x, 2) for x in os.getloadavg()]
    except OSError:
        return [0.0, 0.0, 0.0]


def local_ip() -> Optional[str]:
    """The address used to reach the outside world (a UDP connect sends nothing). None when there is no route."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.0.2.1", 9))
        ip = sock.getsockname()[0]
        return None if ip.startswith("127.") or ip == "0.0.0.0" else ip
    except OSError:
        return None
    finally:
        sock.close()


def parse_nmcli_wifi(text: str) -> Optional[Tuple[str, Optional[int]]]:
    """From ``nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi``: ``(ssid, signal%)`` of the active network."""
    for line in text.splitlines():
        fields = re.split(r"(?<!\\):", line)
        if len(fields) >= 3 and fields[0] == "yes":
            ssid = fields[1].replace("\\:", ":").replace("\\\\", "\\")
            try:
                return ssid, int(fields[2])
            except ValueError:
                return ssid, None
    return None


def parse_proc_net_wireless(text: str) -> Optional[int]:
    """Link quality (0-70) of the first wireless interface in /proc/net/wireless as a percentage."""
    for line in text.splitlines()[2:]:
        parts = line.split()
        if len(parts) >= 3 and parts[0].endswith(":"):
            try:
                return max(0, min(100, int(round(float(parts[2].rstrip(".")) * 100 / 70))))
            except ValueError:
                return None
    return None


def parse_iw_link(text: str) -> Optional[Tuple[str, Optional[int]]]:
    """From ``iw dev wlan0 link``: ``(ssid, signal%)`` derived from the dBm figure."""
    ssid = re.search(r"SSID:\s*(.+)", text)
    if not ssid:
        return None
    dbm = re.search(r"signal:\s*(-?\d+)\s*dBm", text)
    pct = max(0, min(100, 2 * (int(dbm.group(1)) + 100))) if dbm else None
    return ssid.group(1).strip(), pct


def pcm16_levels(data: bytes, skip_samples: int = 0) -> Optional[Tuple[float, float]]:
    """``(rms_dbfs, peak_dbfs)`` of little-endian signed 16-bit mono PCM; None if there is no data. Digital silence -> -inf."""
    usable = len(data) // 2
    if usable - skip_samples <= 0:
        return None
    samples: Sequence[int] = struct.unpack("<%dh" % usable, data[: usable * 2])[skip_samples:]
    peak = max(abs(s) for s in samples)
    mean_sq = sum(s * s for s in samples) / len(samples)
    def db(value: float) -> float:
        return -math.inf if value <= 0 else 20.0 * math.log10(value / 32768.0)
    return db(math.sqrt(mean_sq)), db(float(peak))
