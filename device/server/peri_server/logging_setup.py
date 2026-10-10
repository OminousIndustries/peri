"""Logging to stdout/journald with secret redaction. Nothing here ever logs request bodies."""
from __future__ import annotations

import logging
import os
import re
import sys
from typing import List, Tuple

_REDACTIONS: List[Tuple["re.Pattern[str]", str]] = [
    (re.compile(r"sk-[A-Za-z0-9_\-*]{6,}"), "sk-***"),           # OpenAI keys, incl. the masked form OpenAI echoes back
    (re.compile(r"\bek_[A-Za-z0-9_\-]{8,}"), "ek_***"),           # ephemeral client secrets
    (re.compile(r"(?i)\b(bearer|token)([ =:]+)[A-Za-z0-9._~+/\-]{12,}"), r"\1\2***"),
]


def redact(text: str) -> str:
    """Mask API keys, ephemeral secrets and bearer tokens in arbitrary text."""
    for pattern, replacement in _REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


class RedactingFormatter(logging.Formatter):
    """Applies ``redact`` to the fully formatted record (message *and* traceback)."""

    def format(self, record: logging.LogRecord) -> str:
        return redact(super().format(record))


def setup_logging(level: int = logging.INFO) -> None:
    """Configure the root logger once: single stream handler on stdout, journald-friendly, redacting."""
    root = logging.getLogger()
    for handler in list(root.handlers):
        if getattr(handler, "_peri", False):
            root.removeHandler(handler)
    handler = logging.StreamHandler(sys.stdout)
    handler._peri = True  # type: ignore[attr-defined]
    # journald stamps its own timestamps; add ours only when running in a terminal.
    under_journal = bool(os.environ.get("JOURNAL_STREAM"))
    fmt = "%(levelname)s %(name)s: %(message)s" if under_journal else "%(asctime)s %(levelname)-7s %(name)s: %(message)s"
    handler.setFormatter(RedactingFormatter(fmt, "%H:%M:%S"))
    root.addHandler(handler)
    root.setLevel(level)
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
