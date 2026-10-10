"""Peri server: local backend for the Peri desktop companion (UI hosting, OpenAI Realtime proxy, neck + system control)."""
from __future__ import annotations

from .config import read_version

__version__ = read_version()
__all__ = ["__version__"]
