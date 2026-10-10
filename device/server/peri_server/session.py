"""Builds the OpenAI Realtime session object exactly as documented in docs/API.md section 3.1."""
from __future__ import annotations

import copy
import os
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Mapping, Optional

from . import constants as C
from .catalog import Catalog

_WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
           "November", "December"]


@dataclass(frozen=True)
class RuntimeFacts:
    """Things the model cannot know on its own; appended to the instructions at session start."""

    device_name: str
    device_id: str
    now: datetime          # timezone-aware local time
    tz_name: str
    body_can_move: bool


def local_timezone_name() -> str:
    """IANA name of the device's timezone when it can be found, else the abbreviation (e.g. 'BST')."""
    tz = os.environ.get("TZ", "").lstrip(":").strip()
    if tz:
        return tz
    try:
        name = Path("/etc/timezone").read_text().strip()
        if name:
            return name
    except OSError:
        pass
    try:
        target = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in target:
            return target.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return time.tzname[0] or "UTC"


def collect_runtime_facts(device_id: str, body_can_move: bool, now: Optional[datetime] = None,
                          tz_name: Optional[str] = None, device_name: str = "Peri") -> RuntimeFacts:
    local = now if now is not None else datetime.now().astimezone()
    return RuntimeFacts(device_name, device_id, local, tz_name or local_timezone_name(), body_can_move)


def format_local_time(now: datetime, tz_name: str) -> str:
    """'Wednesday 30 September 2026, 14:05 (Europe/London, UTC+01:00)' - English names regardless of the OS locale."""
    offset = now.strftime("%z") or "+0000"
    utc = f"UTC{offset[:3]}:{offset[3:5]}"
    return f"{_WEEKDAYS[now.weekday()]} {now.day} {_MONTHS[now.month - 1]} {now.year}, {now:%H:%M} ({tz_name}, {utc})"


def runtime_facts_block(facts: RuntimeFacts) -> str:
    body = "yes" if facts.body_can_move else "no"
    lines = [
        "# Runtime Facts",
        f"- Device name: {facts.device_name} ({facts.device_id}).",
        f"- Local date and time: {format_local_time(facts.now, facts.tz_name)}.",
        f"- Your body can currently move: {body}.",
    ]
    if not facts.body_can_move:
        lines.append("  Your neck is not working right now, so you cannot turn your head: never claim to, and do not call move_head.")
    return "\n".join(lines)


def compose_instructions(persona_instructions: str, custom_instructions: str, facts: RuntimeFacts) -> str:
    """persona prompt + the owner's custom instructions (if any) + runtime facts."""
    parts = [persona_instructions.rstrip()]
    custom = (custom_instructions or "").strip()
    if custom:
        parts.append("# Owner's Custom Instructions\n" + custom)
    parts.append(runtime_facts_block(facts))
    return "\n\n".join(parts)


def turn_detection(settings: Mapping[str, Any]) -> Dict[str, Any]:
    """VAD block. ``interrupt_response`` is always true: in ``barge_in == "tap"`` mode the UI mutes the mic itself."""
    vad = settings["vad"]
    if vad["type"] == "server_vad":
        return {
            "type": "server_vad", "threshold": vad["threshold"], "prefix_padding_ms": 300, "silence_duration_ms": 600,
            "create_response": True, "interrupt_response": True,
        }
    return {
        "type": "semantic_vad", "eagerness": vad["eagerness"], "create_response": True, "interrupt_response": True,
    }


def build_session(settings: Mapping[str, Any], catalog: Catalog, facts: RuntimeFacts,
                  include_reasoning: bool = True) -> Dict[str, Any]:
    """The ``session`` object for POST /v1/realtime/calls and /v1/realtime/client_secrets."""
    persona = catalog.persona_or_default(settings["persona"])
    audio_in: Dict[str, Any] = {}
    if settings["noise_reduction"] != "off":
        audio_in["noise_reduction"] = {"type": settings["noise_reduction"]}
    transcription: Dict[str, Any] = {"model": settings["transcription_model"]}
    if settings["language"] != "auto":
        transcription["language"] = settings["language"]
    transcription["prompt"] = C.TRANSCRIPTION_PROMPT
    audio_in["transcription"] = transcription
    audio_in["turn_detection"] = turn_detection(settings)

    session: Dict[str, Any] = {
        "type": "realtime",
        "model": settings["model"],
        "instructions": compose_instructions(persona.instructions, settings["custom_instructions"], facts),
        "output_modalities": ["audio"],
    }
    if include_reasoning:
        session["reasoning"] = {"effort": settings["reasoning_effort"]}
    session["audio"] = {
        "input": audio_in,
        "output": {"voice": settings["voice"], "speed": float(settings["speed"])},
    }
    session["tools"] = copy.deepcopy(catalog.tools)
    session["tool_choice"] = "auto"
    return session


def session_summary(settings: Mapping[str, Any]) -> Dict[str, Any]:
    """The small ``session`` echo returned to the UI next to the SDP answer."""
    return {"model": settings["model"], "voice": settings["voice"], "persona": settings["persona"],
            "barge_in": settings["barge_in"]}
