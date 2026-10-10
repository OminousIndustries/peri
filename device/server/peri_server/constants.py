"""Static lists and limits shared by several modules (kept in one place so API.md and code cannot drift apart)."""
from __future__ import annotations

PRODUCT = "Peri"

#: Realtime models offered to the UI (any other model id matching MODEL_ID_RE may still be set through settings).
MODELS = ["gpt-realtime-2.1", "gpt-realtime-2.1-mini", "gpt-realtime-2", "gpt-realtime-1.5"]
VOICES = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
REASONING_EFFORTS = ["minimal", "low", "medium", "high", "xhigh"]
MODEL_ID_RE = r"^[A-Za-z0-9][A-Za-z0-9._:\-]{0,63}$"
LANGUAGE_RE = r"^(auto|[a-z]{2,3}(-[A-Za-z0-9]{2,8})*)$"

GESTURES = ["shake_no", "perk_up", "look_around", "ponder", "settle", "wake", "sleep"]

OPENAI_BASE_URL = "https://api.openai.com"

#: Websocket client -> server head messages are limited to this many per second per connection.
WS_HEAD_MSG_RATE = 20
#: /api/client-log accepts at most this many entries per second (extra entries are dropped).
CLIENT_LOG_RATE = 50
CLIENT_LOG_MAX_ENTRIES_PER_REQUEST = 100

#: Helps the transcriber with the (unusual) device name; sent in every session's input transcription config.
TRANSCRIPTION_PROMPT = "Peri (pronounced PEH-ree) is the name of the device the speaker is talking to."

#: Runaway-loop guard for POST /api/realtime/session: sustained rate (per second) and burst. Normal use is a few per minute.
SESSION_RATE = 0.5
SESSION_BURST = 10
