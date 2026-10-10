#!/usr/bin/env bash
# audio-test.sh - play a 1 s tone, then record from the capture device and report the microphone level.
#
#   audio-test.sh [--no-play] [--no-record] [--seconds N] [--card NAME] [--device PCM] [--freq HZ] [--user USER] [--json]
#
#   --no-play        skip the tone            --no-record   skip the recording
#   --seconds N      recording length in seconds (1-30, default 3)
#   --card NAME      address the ALSA card directly (plughw:CARD=NAME,DEV=0) instead of the default device. Direct hardware
#                    access fails with "busy" while PipeWire/PulseAudio holds the card: use the default device normally.
#   --device PCM     any ALSA PCM name (overrides --card), e.g. default, plughw:2,0
#   --freq HZ        tone frequency (default 440)
#   --user USER      run the audio commands as USER (default: peri, the user the UI runs as) - via runuser as root, via
#                    `sudo -n` for another user; works as root, as peri or as any other user
#   --json           machine readable: exactly one JSON line on stdout (the human report goes to stderr)
#
# Capture classification (loudest channel): SILENT = digital zero / constant signal (mic path broken or muted),
# QUIET = RMS below -65 dBFS (gain too low), CLIPPING = at least 0.1 % of the samples at full scale, OK otherwise.
# Exit status: 0 = ran fine (capture OK, QUIET or CLIPPING), 1 = playback/recording failed or capture is SILENT, 2 = usage.
# Whether the tone was AUDIBLE cannot be measured: ask the human. Only the standard library of python3 is used (audioop
# is gone in Python 3.13, so the level maths is done by hand).
set -uo pipefail

PLAY=1; RECORD=1; SECS=3; CARD=""; DEVICE=""; FREQ=440; RUN_AS="${PERI_USER:-peri}"; JSON=0

usage() { sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; }
die_usage() { echo "audio-test.sh: $1 (see --help)" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-play) PLAY=0 ;;
        --no-record) RECORD=0 ;;
        --seconds) shift; SECS="${1:-}" ;;
        --card) shift; CARD="${1:-}" ;;
        --device) shift; DEVICE="${1:-}" ;;
        --freq) shift; FREQ="${1:-}" ;;
        --user) shift; RUN_AS="${1:-}" ;;
        --json) JSON=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown option: $1" ;;
    esac
    shift
done
[[ "$SECS" =~ ^[0-9]+$ && "$SECS" -ge 1 && "$SECS" -le 30 ]] || die_usage "--seconds wants an integer 1-30"
[[ "$FREQ" =~ ^[0-9]+$ && "$FREQ" -ge 20 && "$FREQ" -le 20000 ]] || die_usage "--freq wants an integer 20-20000"
command -v python3 >/dev/null 2>&1 || { echo "audio-test.sh: python3 is required" >&2; exit 1; }

# The human report goes to stdout normally, to stderr with --json (stdout is then exactly one JSON line).
say() { if [[ "$JSON" == 1 ]]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/peri-audio-test.XXXXXX") || { echo "audio-test.sh: cannot create a temp dir" >&2; exit 1; }
chmod 0700 "$WORK"          # widened below only when another user has to write the recording here
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------- how to run
# Run the audio commands as the user that really uses the sound card (peri; its PipeWire/Pulse sockets live in /run/user/UID):
# via runuser as root, via `sudo -n` for another user that may (as the pi/admin user usually may), otherwise directly - and the
# report says so. Never as root when peri exists: an ALSA dmix/dsnoop IPC object created by root would lock peri out until reboot.
RUNNER=(); WHO="$(id -un)"; NOTE_USER=""
me=$(id -u)
if [[ -n "$RUN_AS" && "$RUN_AS" != root ]] && peri_uid=$(id -u "$RUN_AS" 2>/dev/null) && [[ "$me" != "$peri_uid" ]]; then
    rt_env=(env)
    [[ -d "/run/user/$peri_uid" ]] && rt_env=(env "XDG_RUNTIME_DIR=/run/user/$peri_uid")
    if [[ "$me" == 0 ]] && command -v runuser >/dev/null 2>&1; then
        RUNNER=(runuser -u "$RUN_AS" -- "${rt_env[@]}"); WHO="$RUN_AS"
        chown "$RUN_AS" "$WORK" 2>/dev/null || chmod 0777 "$WORK"        # only that user (and root) may enter the directory
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        RUNNER=(sudo -n -u "$RUN_AS" "${rt_env[@]}"); WHO="$RUN_AS"
        chmod 0777 "$WORK"                                                # a different normal user has to write the recording
    else
        NOTE_USER="cannot switch to user $RUN_AS without a password: testing as $WHO (run with sudo to test as $RUN_AS)"
    fi
fi
if [[ ${#RUNNER[@]} -eq 0 && -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$me" ]]; then export XDG_RUNTIME_DIR="/run/user/$me"; fi
[[ -z "$NOTE_USER" ]] || say "note: $NOTE_USER"
if [[ -n "$DEVICE" ]]; then PCM="$DEVICE"
elif [[ -n "$CARD" ]]; then PCM="plughw:CARD=$CARD,DEV=0"
else PCM="default"; fi

PLAY_RESULT="skipped"; PLAY_NOTE=""; CAP_JSON='{"capture":"skipped"}'; CAP_CLASS="skipped"; FAIL=0

# ------------------------------------------------------------------------------------------------ playback
if [[ "$PLAY" == 1 ]]; then
    say "Playback: ${FREQ} Hz tone, 1 s, device '$PCM' (running as $WHO)"
    if ! command -v aplay >/dev/null 2>&1; then
        PLAY_RESULT="failed"; PLAY_NOTE="aplay not installed (apt install alsa-utils)"; FAIL=1
    else
        python3 - "$WORK/tone.wav" "$FREQ" <<'PY'
import math, struct, sys, wave
path, freq = sys.argv[1], float(sys.argv[2])
rate, n, fade, amp = 48000, 48000, 960, 0.2          # 1 s, 20 ms fades, -14 dBFS: clearly audible, not deafening
frames = bytearray()
for i in range(n):
    env = min(1.0, i / fade, (n - i) / fade)
    v = int(amp * 32767 * env * math.sin(2 * math.pi * freq * i / rate))
    frames += struct.pack("<hh", v, v)
with wave.open(path, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(frames))
PY
        chmod 0644 "$WORK/tone.wav"
        if err=$("${RUNNER[@]}" timeout 15 aplay -q -D "$PCM" "$WORK/tone.wav" 2>&1 >/dev/null); then
            PLAY_RESULT="ok"; PLAY_NOTE="tone played without errors - ask the human whether it was audible"
        else
            PLAY_RESULT="failed"; PLAY_NOTE="aplay failed: ${err:-no message}"; FAIL=1
        fi
    fi
    say "  -> $PLAY_RESULT: $PLAY_NOTE"
fi

# ------------------------------------------------------------------------------------------------ capture
if [[ "$RECORD" == 1 ]]; then
    say "Capture: ${SECS} s from '$PCM' (running as $WHO) - speak or clap now"
    if ! command -v arecord >/dev/null 2>&1; then
        CAP_JSON='{"capture":"ERROR","note":"arecord not installed (apt install alsa-utils)"}'; CAP_CLASS="ERROR"; FAIL=1
    else
        recorded=0; err=""
        for channels in 2 1; do
            if err=$("${RUNNER[@]}" timeout $((SECS + 10)) arecord -q -D "$PCM" -f S16_LE -r 48000 -c "$channels" -d "$SECS" -t wav "$WORK/rec.wav" 2>&1 >/dev/null); then recorded=1; break; fi
        done
        if [[ "$recorded" != 1 ]]; then
            CAP_JSON=$(python3 -c 'import json,sys; print(json.dumps({"capture":"ERROR","note":"arecord failed: "+sys.argv[1]}))' "${err:-no message}")
            CAP_CLASS="ERROR"; FAIL=1
        else
            # analysis: human meter -> stderr/stdout via say, one JSON line -> the last line of the output
            report=$(python3 - "$WORK/rec.wav" "$PCM" <<'PY'
import array, json, math, sys, wave

path, pcm = sys.argv[1], sys.argv[2]
FS = 32768.0

def db(x):
    if x <= 0:
        return None
    r = round(20.0 * math.log10(x / FS), 1)
    return 0.0 if r == 0 else r          # no "-0.0"

def fmt(v):
    return "-inf" if v is None else "%.1f" % v

with wave.open(path, "rb") as w:
    ch, sw, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(n)
if sw != 2:
    print(json.dumps({"capture": "ERROR", "note": "unexpected sample width %d" % sw}))
    sys.exit(0)
a = array.array("h")
a.frombytes(raw[: len(raw) // 2 * 2])
if sys.byteorder == "big":
    a.byteswap()
chans = [a[c::ch] for c in range(ch)]
if not chans or len(chans[0]) == 0:
    print(json.dumps({"capture": "ERROR", "note": "empty recording"}))
    sys.exit(0)

def stats(x):
    n = len(x)
    rms = math.sqrt(sum(v * v for v in x) / n)
    peak = max(max(x), -min(x))
    clipped = sum(1 for v in x if v >= 32700 or v <= -32700)
    const = max(x) == min(x)
    if peak == 0 or const:
        cls = "SILENT"
    elif clipped / n >= 0.001:
        cls = "CLIPPING"
    elif db(rms) is not None and db(rms) < -65.0:
        cls = "QUIET"
    else:
        cls = "OK"
    return {"class": cls, "rms": rms, "peak": peak, "rms_dbfs": db(rms), "peak_dbfs": db(peak), "clip_pct": round(100.0 * clipped / n, 3)}

per = [stats(x) for x in chans]
severity = {"OK": 0, "QUIET": 1, "CLIPPING": 1, "SILENT": 2}
best = min(range(len(per)), key=lambda i: (severity[per[i]["class"]], -per[i]["rms"]))
overall = per[best]

# window meter over the loudest channel: 250 ms windows, bar from -80 to 0 dBFS
win = max(1, int(rate * 0.25))
lines = []
x = chans[best]
for i in range(0, len(x), win):
    seg = x[i : i + win]
    if not seg:
        break
    r = math.sqrt(sum(v * v for v in seg) / len(seg))
    p = max(max(seg), -min(seg))
    rd = db(r)
    bar = 0 if rd is None else max(0, min(40, int(round((rd + 80.0) / 80.0 * 40))))
    lines.append("  %4.2f-%4.2f s  rms %6s dBFS  peak %6s dBFS |%s%s|" % (i / rate, min(len(x), i + win) / rate, fmt(rd), fmt(db(p)), "#" * bar, "." * (40 - bar)))
print("\n".join(lines))
for i, s in enumerate(per):
    print("  channel %d: rms %s dBFS, peak %s dBFS, clipped %.3f %% -> %s" % (i + 1, fmt(s["rms_dbfs"]), fmt(s["peak_dbfs"]), s["clip_pct"], s["class"]))
note = ""
if len(per) > 1 and len({s["class"] for s in per}) > 1:
    note = "channels differ (" + ", ".join("ch%d %s" % (i + 1, s["class"]) for i, s in enumerate(per)) + "): one microphone may be dead or muted"
    print("  note: " + note)
print("JSON " + json.dumps({
    "capture": overall["class"], "device": pcm, "seconds": round(len(x) / rate, 2), "rate": rate, "channels": ch,
    "rms_dbfs": overall["rms_dbfs"], "peak_dbfs": overall["peak_dbfs"], "clip_pct": overall["clip_pct"], "note": note,
    "per_channel": [{"class": s["class"], "rms_dbfs": s["rms_dbfs"], "peak_dbfs": s["peak_dbfs"]} for s in per]}))
PY
)
            while IFS= read -r line; do
                case "$line" in JSON\ *) CAP_JSON="${line#JSON }" ;; *) say "$line" ;; esac
            done <<< "$report"
            CAP_CLASS=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("capture","ERROR"))' "$CAP_JSON")
            case "$CAP_CLASS" in SILENT|ERROR) FAIL=1 ;; esac
        fi
    fi
    say "  -> capture: $CAP_CLASS"
fi

# ------------------------------------------------------------------------------------------------- summary
RESULT=$(python3 - "$PLAY_RESULT" "$PLAY_NOTE" "$CAP_JSON" "$FAIL" <<'PY'
import json, sys
play, note, cap, fail = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
out = {"playback": play, "playback_note": note, "ok": fail == "0"}
out.update(cap)
print(json.dumps(out))
PY
)
if [[ "$JSON" == 1 ]]; then
    printf '%s\n' "$RESULT"
else
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
f = lambda v: "n/a" if "rms_dbfs" not in d else ("-inf" if v is None else v)
print("RESULT playback=%s capture=%s rms_dbfs=%s peak_dbfs=%s" % (d.get("playback"), d.get("capture"), f(d.get("rms_dbfs")), f(d.get("peak_dbfs"))))' "$RESULT"
fi
exit "$FAIL"
