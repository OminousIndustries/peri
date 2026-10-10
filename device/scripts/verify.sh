#!/usr/bin/env bash
# verify.sh - self-check of a Peri device. Prints one table  CHECK | STATUS | DETAIL  (STATUS = PASS / WARN / FAIL / SKIP), then
# "RESULT: PASS|WARN|FAIL" and, for every WARN/FAIL, the exact commands to look at next. Exit status 1 when any check FAILs.
# Safe to run repeatedly, as root or as a normal user; never prints secrets (it only reads booleans from the server status).
#
#   verify.sh [--json] [--no-audio] [--quick] [--wait SECONDS]
#
#   --json         machine readable: one JSON document {overall, counts, checks:[{check,status,detail,hint}]} on stdout
#   --no-audio     skip the tone and the microphone recording
#   --quick        skip the slow things (audio, waiting for the server/UI/OpenAI check): every check is a single look
#   --wait N       how long to retry while the server is starting / the UI connects / the OpenAI check runs (default 30 s)
#
# Checks: os, boot-config, display, touch, audio-card, audio-play (only "ran without error": ask the human whether it was
# audible), audio-capture (3 s: digital silence = FAIL, very low = WARN), audio-default, audio-server, server, openai, head,
# unit:peri-server/peri-kiosk/peri-hwinit/peri-ui-watchdog, kiosk-process, ui-connected (status.ui.clients >= 1),
# ui-page (Chromium debug port), failed-units, disk, temperature, throttling.
# Environment: PERI_ROOT (fake-root prefix, tests), PERI_BASE_URL (default http://127.0.0.1:$PERI_PORT), PERI_USER (peri),
# PERI_STATE_DIR (/var/lib/peri), PERI_CHROMIUM_DEBUG_PORT (9222; empty = debug port off), PERI_AUDIO_TEST (path of audio-test.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PERI_ROOT:-}"; ROOT="${ROOT%/}"
PERI_USER="${PERI_USER:-peri}"
STATE_DIR="${PERI_STATE_DIR:-/var/lib/peri}"
DEBUG_PORT="${PERI_CHROMIUM_DEBUG_PORT-9222}"
AUDIO_TEST="${PERI_AUDIO_TEST:-$SCRIPT_DIR/audio-test.sh}"
WAIT=30; JSON=0; NO_AUDIO=0; QUICK=0

usage() { sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON=1 ;;
        --no-audio) NO_AUDIO=1 ;;
        --quick) QUICK=1 ;;
        --wait) shift; WAIT="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify.sh: unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
[[ "$WAIT" =~ ^[0-9]+$ ]] || { echo "verify.sh: --wait wants a number of seconds" >&2; exit 2; }
if [[ $QUICK -eq 1 ]]; then NO_AUDIO=1; WAIT=0; fi

have() { command -v "$1" >/dev/null 2>&1; }
rp() { printf '%s%s' "$ROOT" "$1"; }

if [[ -z "${PERI_BASE_URL:-}" ]]; then
    port="8420"
    if [[ -r "$(rp /etc/peri/peri.env)" ]]; then
        p=$(grep -E '^[[:space:]]*PERI_PORT=' "$(rp /etc/peri/peri.env)" 2>/dev/null | tail -n 1 | sed -E 's/^[^=]*=[[:space:]]*//; s/["'"'"']//g; s/[[:space:]]+$//' || true)
        [[ "$p" =~ ^[0-9]{2,5}$ ]] && port="$p"
    fi
    port="${PERI_PORT:-$port}"
    BASE_URL="http://127.0.0.1:$port"
else
    BASE_URL="${PERI_BASE_URL%/}"
fi

# ----------------------------------------------------------------------------------------------- results
NAMES=(); STATUSES=(); DETAILS=(); HINTS=()
# add STATUS NAME DETAIL [HINT]
add() {
    NAMES+=("$2"); STATUSES+=("$1"); HINTS+=("${4:-}")
    local d="${3//$'\n'/ }"; DETAILS+=("${d//$'\t'/ }")
}

# ----------------------------------------------------------------------------------------------- helpers
http_get() {
    if have curl; then curl -fsS -m 4 "$1" 2>/dev/null
    elif have python3; then python3 -c 'import sys, urllib.request; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=4).read().decode())' "$1" 2>/dev/null
    else return 1; fi
}
# mask anything that looks like an API key before it can reach the output
scrub() { sed -E 's/sk-[A-Za-z0-9_-]{6,}/sk-***/g; s/(Bearer[[:space:]]+|token=)[A-Za-z0-9._~+\/=-]+/\1***/g' | cut -c1-160; }

# ---------------------------------------------------------------------------------------------- the checks
check_os() {
    local pretty="" codename="" model="" kernel arch
    if [[ -r "$(rp /etc/os-release)" ]]; then
        pretty=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$(rp /etc/os-release)" | head -n 1)
        codename=$(sed -n 's/^VERSION_CODENAME=//p' "$(rp /etc/os-release)" | head -n 1 | tr -d '"')
    fi
    [[ -r "$(rp /proc/device-tree/model)" ]] && model=$(tr -d '\0' < "$(rp /proc/device-tree/model)")
    kernel=$(uname -r 2>/dev/null || echo "?"); arch=$(uname -m 2>/dev/null || echo "?")
    local d="${pretty:-unknown OS}, ${model:-not a Raspberry Pi}, kernel $kernel, $arch"
    if [[ "$model" == "Raspberry Pi"* && "$codename" =~ ^(bullseye|bookworm|trixie)$ ]]; then add PASS os "$d"
    elif [[ "$model" == "Raspberry Pi"* ]]; then add WARN os "$d - OS is not one of bullseye/bookworm/trixie (untested)"
    else add WARN os "$d - this is not a Raspberry Pi (the display/audio checks below will fail)"; fi
}

check_boot() {
    local boot cmd cfg missing=() tokens
    if [[ -f "$(rp /boot/firmware/config.txt)" ]]; then boot=/boot/firmware; else boot=/boot; fi
    cmd="$(rp $boot/cmdline.txt)"; cfg="$(rp $boot/config.txt)"
    if [[ ! -f "$cmd" ]]; then add SKIP boot-config "no $boot/cmdline.txt (not a Raspberry Pi image)"; return; fi
    tokens=$(tr -s '[:space:]' '\n' < "$cmd")
    if [[ $(grep -c '' "$cmd") -ne 1 ]] || ! grep -q '^root=' <<< "$tokens"; then
        add FAIL boot-config "$boot/cmdline.txt is not ONE line with root= - the Pi may not boot!" "compare with $boot/cmdline.txt.peri-bak; fix it, or: sudo cp $boot/cmdline.txt.peri-bak $boot/cmdline.txt"
        return
    fi
    grep -qx 'quiet' <<< "$tokens" || missing+=("cmdline quiet")
    grep -qx 'splash' <<< "$tokens" || missing+=("cmdline splash")
    grep -Eq '^[[:space:]]*disable_splash=1' "$cfg" 2>/dev/null || missing+=("config.txt disable_splash=1")
    if [[ ${#missing[@]} -eq 0 ]]; then add PASS boot-config "quiet + splash + disable_splash=1, single-line cmdline with root="
    else add WARN boot-config "cosmetic: missing ${missing[*]} (boot messages/rainbow screen visible)" "sudo /opt/peri/install.sh --yes --only boot   (splash needs a reboot)"; fi
}

check_display() {
    local d name st mode found=0 out
    for d in "$(rp /sys/class/drm)"/card*-DSI-*; do
        [[ -d "$d" ]] || continue
        found=1; name=${d##*/}; name=${name#card*-}
        st=$(head -n 1 "$d/status" 2>/dev/null || true); mode=$(head -n 1 "$d/modes" 2>/dev/null || true)
        if [[ "$st" == connected || ( "$st" == unknown && -n "$mode" ) ]]; then
            if [[ "$mode" == 720x720* ]]; then add PASS display "DSI connector $name connected, mode $mode"
            else add WARN display "DSI connector $name connected but mode is '${mode:-unknown}', expected 720x720" "grep -i -E 'waveshare|panel|dsi' <(dmesg); check dtoverlay in /boot*/config.txt"; fi
            return
        fi
    done
    if [[ $found -eq 0 ]] && have kmsprint; then
        out=$(kmsprint 2>/dev/null | grep -i 'dsi' || true)
        if grep -qi 'connected' <<< "$out" && ! grep -qi 'disconnected' <<< "$out"; then
            if grep -q '720x720' <<< "$out"; then add PASS display "kmsprint: DSI connected at 720x720"; else add WARN display "kmsprint: DSI connected: $(head -n 1 <<< "$out")"; fi
            return
        fi
    fi
    if [[ $found -eq 0 ]] && have modetest; then
        out=$(modetest -c 2>/dev/null | grep -i -A3 'DSI' || true)
        if grep -q '720x720' <<< "$out"; then add PASS display "modetest: DSI connector with a 720x720 mode"; return; fi
    fi
    if [[ $found -eq 0 && -r "$(rp /sys/class/graphics/fb0/virtual_size)" && "$(head -n 1 "$(rp /sys/class/graphics/fb0/virtual_size)" 2>/dev/null)" == "720,720" ]]; then
        add PASS display "framebuffer fb0 is 720x720 (this driver shows no DSI connector in /sys/class/drm)"
        return
    fi
    if [[ $found -eq 1 ]]; then
        add FAIL display "a DSI connector exists but is not connected (ribbon cable? panel power? DIP switch I2C0/I2C1?)" "dmesg | grep -i -E 'waveshare|goodix|dsi|panel'; cat /sys/class/drm/card*-DSI-*/status"
    else
        add FAIL display "no DSI connector in /sys/class/drm: the panel overlay/driver is not active (config.txt not applied yet? reboot pending?)" "grep -n -i -E 'dsi|vc4' /boot*/config.txt; dmesg | grep -i -E 'waveshare|dsi|panel'; sudo /opt/peri/install.sh --yes --only display"
    fi
}

check_touch() {
    local f name
    f="$(rp /proc/bus/input/devices)"
    if [[ ! -r "$f" ]]; then add SKIP touch "/proc/bus/input/devices not readable"; return; fi
    name=$(sed -n 's/^N: Name="\(.*[Gg]oodix.*\)"$/\1/p' "$f" | head -n 1)
    if [[ -n "$name" ]]; then add PASS touch "input device '$name'"; return; fi
    name=$(sed -n 's/^N: Name="\(.*\([Tt]ouch\|ft5406\).*\)"$/\1/p' "$f" | head -n 1)
    if [[ -n "$name" ]]; then add PASS touch "touch device '$name' (not the expected Goodix controller)"; return; fi
    add FAIL touch "no Goodix touch controller in /proc/bus/input/devices (I2C0/I2C1 mismatch? disable_touchscreen=1 in config.txt?)" "dmesg | grep -i goodix; sudo PERI_OPT_DSI_I2C=1 /opt/peri/install.sh --yes --only display   (panel wired on GPIO2/3)"
}

check_audio_card() {
    local line=""
    if [[ -r "$(rp /proc/asound/cards)" ]]; then
        line=$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\) \[\([^] ]*\)[[:space:]]*\]: \(.*\)$/card \1 [\2] \3/p' "$(rp /proc/asound/cards)" | grep -iE 'wm8960|seeed|voicecard' | head -n 1 || true)
    elif have aplay; then
        line=$(aplay -l 2>/dev/null | grep -iE '^card.*(wm8960|seeed|voicecard)' | head -n 1 || true)
    fi
    if [[ -n "$line" ]]; then add PASS audio-card "$line"
    else add FAIL audio-card "no WM8960 / seeed-voicecard sound card (aplay -l)" "aplay -l; dmesg | grep -i -E 'wm8960|seeed|i2s'; grep -n -E 'i2s|i2c_arm|wm8960|seeed' /boot*/config.txt; sudo /opt/peri/install.sh --yes --only audio"; fi
}

# audio play + capture in ONE run of audio-test.sh (about 5 s)
check_audio() {
    local out fields play note cap rms peak anote
    if [[ $NO_AUDIO -eq 1 ]]; then
        add SKIP audio-play "skipped (--no-audio / --quick)"; add SKIP audio-capture "skipped (--no-audio / --quick)"; return
    fi
    if [[ ! -f "$AUDIO_TEST" ]]; then
        add WARN audio-play "audio-test.sh not found next to verify.sh"; add WARN audio-capture "audio-test.sh not found next to verify.sh"; return
    fi
    out=$(bash "$AUDIO_TEST" --json --seconds 3 2>/dev/null || true)
    fields=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read().strip().splitlines()[-1])
except Exception:
    print("unparsable"); sys.exit(0)
def f(v):
    return "-inf" if v is None else v
print(d.get("playback", ""))
print(d.get("playback_note", ""))
print(d.get("capture", ""))
print(f(d.get("rms_dbfs")) if "rms_dbfs" in d else "n/a")
print(f(d.get("peak_dbfs")) if "peak_dbfs" in d else "n/a")
print(d.get("note", ""))' 2>/dev/null || echo unparsable)
    if [[ "$fields" == unparsable || -z "$fields" ]]; then
        add FAIL audio-play "audio-test.sh produced no usable result" "sudo $AUDIO_TEST"; add FAIL audio-capture "audio-test.sh produced no usable result" "sudo $AUDIO_TEST"; return
    fi
    { read -r play; read -r note; read -r cap; read -r rms; read -r peak; read -r anote; } <<< "$fields"
    case "$play" in
        ok) add PASS audio-play "1 s tone played without error - ask the human whether it was audible" ;;
        failed) add FAIL audio-play "$(scrub <<< "$note")" "aplay -l; amixer -c 0 scontents | head; sudo /opt/peri/scripts/hw-init.sh; sudo -u $PERI_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $PERI_USER) wpctl status" ;;
        *) add SKIP audio-play "not run" ;;
    esac
    case "$cap" in
        OK) add PASS audio-capture "3 s recorded: rms $rms dBFS, peak $peak dBFS${anote:+ ($anote)}" ;;
        QUIET) add WARN audio-capture "very quiet: rms $rms dBFS, peak $peak dBFS (mic gain too low or covered?)" "PERI_MIXER_CAPTURE / PERI_MIXER_BOOST in /etc/peri/peri.env, then sudo /opt/peri/scripts/hw-init.sh" ;;
        CLIPPING) add WARN audio-capture "clipping: rms $rms dBFS, peak $peak dBFS (loud sound during the test, or gain too high)" "lower PERI_MIXER_CAPTURE in /etc/peri/peri.env, then sudo /opt/peri/scripts/hw-init.sh" ;;
        SILENT) add FAIL audio-capture "digital silence: the microphone path delivers zeros (muted, wrong routing or dead codec)" "sudo /opt/peri/scripts/hw-init.sh; amixer -c 0 cget name='Capture Switch'; dmesg | grep -i wm8960" ;;
        *) add FAIL audio-capture "$(scrub <<< "${anote:-recording failed}")" "arecord -l; sudo $AUDIO_TEST --no-play" ;;
    esac
}

# ---- server (the retry window covers a server that is still starting)
STATUS_JSON=""
declare -A ST=()
fetch_status() {
    local parsed k v
    STATUS_JSON=$(http_get "$BASE_URL/api/system/status" || true)
    ST=()
    [[ -n "$STATUS_JSON" ]] || return 1
    parsed=$(printf '%s' "$STATUS_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
def g(*ks, default=""):
    v = d
    for k in ks:
        if not isinstance(v, dict) or k not in v:
            return default
        v = v[k]
    return default if v is None else v
def s(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v).replace("\n", " ")
rows = {
    "version": g("version"), "ui_clients": g("ui", "clients", default="-1"),
    "openai_configured": g("openai", "configured"), "openai_reachable": g("openai", "reachable", default="null"),
    "openai_error": g("openai", "last_error"),
    "head_driver": g("head", "driver"), "head_connected": g("head", "connected"), "head_error": g("head", "error"), "head_angle": g("head", "angle"),
    "audio_backend": g("audio", "backend"), "audio_sink": g("audio", "sink"), "audio_source": g("audio", "source"),
    "audio_volume": g("audio", "volume"), "audio_muted": g("audio", "muted"),
    "has_openai": "openai" in d, "has_head": "head" in d, "has_audio": "audio" in d, "has_ui": "ui" in d,
}
for k, v in rows.items():
    print("%s=%s" % (k, s(v)))' 2>/dev/null) || return 1
    while IFS='=' read -r k v; do [[ -n "$k" ]] && ST[$k]="$v"; done <<< "$parsed"
    return 0
}

check_server() {
    local end=$((SECONDS + WAIT)) body ver=""
    while :; do
        body=$(http_get "$BASE_URL/healthz" || true)
        [[ -n "$body" ]] && break
        (( SECONDS >= end )) && break
        sleep 1
    done
    if [[ -z "$body" ]]; then
        add FAIL server "no answer from $BASE_URL/healthz$([[ $WAIT -gt 0 ]] && printf ' within %ss' "$WAIT")" "systemctl status peri-server --no-pager; journalctl -u peri-server -n 80 --no-pager; sudo peri-config status"
        return
    fi
    ver=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d.get("ok") else "not-ok", d.get("version",""))' 2>/dev/null || echo "? ")
    if [[ "$ver" == ok* ]]; then add PASS server "healthy, version ${ver#ok }"; else add FAIL server "/healthz answered but not ok: $(scrub <<< "$body")" "journalctl -u peri-server -n 80 --no-pager"; fi
    fetch_status || true
}

check_openai() {
    local end=$((SECONDS + (WAIT > 20 ? 20 : WAIT)))
    if [[ ${#ST[@]} -eq 0 ]]; then add SKIP openai "server status not available"; return; fi
    if [[ "${ST[openai_configured]:-}" != true ]]; then
        add FAIL openai "OPENAI_API_KEY is not configured" "echo 'sk-...' | sudo peri-config set OPENAI_API_KEY -    (restarts the server); check: sudo peri-config key-check"
        return
    fi
    while [[ "${ST[openai_reachable]:-null}" == null && $SECONDS -lt $end ]]; do sleep 2; fetch_status || break; done
    case "${ST[openai_reachable]:-null}" in
        true) add PASS openai "key configured and api.openai.com accepted it" ;;
        false) add FAIL openai "key configured but not usable: $(scrub <<< "${ST[openai_error]:-no error text}")" "curl -sS -o /dev/null -w '%{http_code}\n' https://api.openai.com/v1/models   (network? key valid? clock right?); journalctl -u peri-server -n 50 --no-pager" ;;
        *) add WARN openai "key configured; the reachability check has not completed yet" "run verify.sh again in a minute" ;;
    esac
}

check_head() {
    if [[ ${#ST[@]} -eq 0 ]]; then add SKIP head "server status not available"; return; fi
    if [[ "${ST[has_head]:-false}" != true ]]; then add WARN head "the server status has no head section"; return; fi
    if [[ "${ST[head_driver]:-}" == none ]]; then add SKIP head "Pi motor control disabled; an optional standalone Arduino is powered and tested separately"; return; fi
    if [[ "${ST[head_connected]:-}" == true ]]; then
        add PASS head "driver ${ST[head_driver]:-?} connected, angle ${ST[head_angle]:-?} deg"
    else
        add WARN head "driver '${ST[head_driver]:-none}' not connected${ST[head_error]:+ ($(scrub <<< "${ST[head_error]}"))}: the Nano may be unplugged or not flashed; the UI works without the neck" "ls -l /dev/ttyUSB* /dev/ttyACM* /dev/peri-head; curl -s $BASE_URL/api/head; scripts/flash-firmware.sh"
    fi
}

check_units() {
    local u state enabled level
    if ! have systemctl; then add SKIP "unit:peri-server" "systemctl not available"; return; fi
    for u in peri-server peri-kiosk peri-hwinit peri-ui-watchdog.timer; do
        state=$(systemctl is-active "$u" 2>/dev/null || true); enabled=$(systemctl is-enabled "$u" 2>/dev/null || true)
        case "$u" in peri-server|peri-kiosk) level=FAIL ;; *) level=WARN ;; esac
        if [[ "$state" == active ]]; then add PASS "unit:${u%.timer}" "active (${enabled:-?} at boot)"
        else add "$level" "unit:${u%.timer}" "${state:-unknown} (${enabled:-not installed})" "systemctl status $u --no-pager; journalctl -u ${u%.timer} -n 60 --no-pager"; fi
    done
}

check_kiosk() {
    local pids end=$((SECONDS + WAIT)) clients page title url
    if have pgrep; then
        pids=$(pgrep -f -- "--user-data-dir=${STATE_DIR}/chromium" 2>/dev/null | head -n 20 | tr '\n' ' ' || true)
        if [[ -n "${pids// /}" ]]; then add PASS kiosk-process "Chromium running (pids ${pids% })"
        else add FAIL kiosk-process "no Chromium kiosk process found" "peri-kiosk status; peri-kiosk logs; sudo peri-kiosk restart"; fi
    else
        add SKIP kiosk-process "pgrep not available"
    fi
    if [[ ${#ST[@]} -eq 0 ]]; then add SKIP ui-connected "server status not available"; else
        while :; do
            clients="${ST[ui_clients]:--1}"
            [[ "$clients" =~ ^[0-9]+$ && "$clients" -ge 1 ]] && break
            (( SECONDS >= end )) && break
            sleep 2; fetch_status || true
        done
        clients="${ST[ui_clients]:--1}"
        if [[ "$clients" =~ ^[0-9]+$ && "$clients" -ge 1 ]]; then add PASS ui-connected "$clients UI websocket client(s) connected to the server"
        elif [[ "${ST[has_ui]:-false}" != true ]]; then add WARN ui-connected "the server status has no ui.clients field (older server?)"
        else add FAIL ui-connected "the server sees no UI client: the kiosk page is not loaded" "peri-kiosk logs; sudo peri-kiosk restart; curl -s $BASE_URL/healthz"; fi
    fi
    # what the browser shows, when its debugging port answers
    if [[ -z "$DEBUG_PORT" ]]; then add SKIP ui-page "Chromium debug port disabled (PERI_CHROMIUM_DEBUG_PORT empty)"; return; fi
    page=$(http_get "http://127.0.0.1:$DEBUG_PORT/json" || true)
    if [[ -z "$page" ]]; then add SKIP ui-page "Chromium debug port $DEBUG_PORT does not answer (browser not started, or debug port off)"; return; fi
    { read -r title; read -r url; } < <(printf '%s' "$page" | python3 -c '
import json, sys
try:
    pages = [t for t in json.load(sys.stdin) if t.get("type") == "page"]
except Exception:
    pages = []
t = pages[0] if pages else {}
print(t.get("title", ""))
print(t.get("url", "-"))' 2>/dev/null)
    case "${url:--}" in
        -) add WARN ui-page "debug port answers but lists no page" ;;
        chrome-error:*|about:blank*|data:*) add FAIL ui-page "the browser shows an error/blank page: title '${title}' url '${url}'" "peri-kiosk logs; sudo peri-kiosk restart" ;;
        *) add PASS ui-page "title '${title}' url ${url}" ;;
    esac
}

check_audio_server() {
    local uid rt pw=0 wp=0 pa=0
    uid=$(id -u "$PERI_USER" 2>/dev/null || echo "")
    rt="$(rp /run/user)/${uid:-x}"
    if have pgrep && [[ -n "$uid" ]]; then
        pgrep -u "$uid" -x pipewire >/dev/null 2>&1 && pw=1
        pgrep -u "$uid" -x wireplumber >/dev/null 2>&1 && wp=1
        pgrep -u "$uid" -x pulseaudio >/dev/null 2>&1 && pa=1
    fi
    if [[ $pw -eq 1 && $wp -eq 1 ]]; then add PASS audio-server "PipeWire + WirePlumber running for user $PERI_USER"
    elif [[ $pa -eq 1 ]]; then add PASS audio-server "PulseAudio running for user $PERI_USER"
    elif [[ $pw -eq 1 ]]; then add WARN audio-server "PipeWire runs but WirePlumber does not (no devices)" "sudo -u $PERI_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $PERI_USER) systemctl --user status wireplumber"
    elif have pipewire || have wpctl || [[ -e "$rt/pipewire-0" ]]; then
        add WARN audio-server "PipeWire is installed but not running for user $PERI_USER (it starts on first use; linger enabled? loginctl show-user $PERI_USER)" "loginctl show-user $PERI_USER | grep Linger; sudo -u $PERI_USER XDG_RUNTIME_DIR=/run/user/\$(id -u $PERI_USER) systemctl --user status pipewire wireplumber"
    else
        add SKIP audio-server "no PipeWire/PulseAudio installed (plain ALSA)"
    fi
}

check_audio_default() {
    local sink="${ST[audio_sink]:-}" src="${ST[audio_source]:-}" backend="${ST[audio_backend]:-}"
    if [[ ${#ST[@]} -eq 0 ]]; then add SKIP audio-default "server status not available"; return; fi
    if [[ "${ST[has_audio]:-false}" != true ]]; then add SKIP audio-default "the server status has no audio section"; return; fi
    if [[ "$backend" == alsa || -z "$backend" ]] && [[ -z "$sink" ]]; then add SKIP audio-default "server uses plain ALSA (backend '${backend:-none}')"; return; fi
    if [[ "${ST[audio_muted]:-false}" == true ]]; then add WARN audio-default "sink is muted (backend $backend, sink '${sink}')" "wpctl set-mute @DEFAULT_AUDIO_SINK@ 0   or the UI volume control"; return; fi
    if grep -qiE 'wm8960|seeed|soc_sound|voicecard|waveshare' <<< "$sink"; then
        add PASS audio-default "backend $backend, sink '${sink}', source '${src:-?}', volume ${ST[audio_volume]:-?}%"
    else
        add WARN audio-default "default sink is '${sink:-unknown}', not the WM8960 (backend $backend)" "sudo /opt/peri/scripts/hw-init.sh   (sets the WM8960 as default sink/source)"
    fi
}

check_failed_units() {
    local failed
    if ! have systemctl; then add SKIP failed-units "systemctl not available"; return; fi
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -i 'peri' | tr '\n' ' ' || true)
    if [[ -z "${failed// /}" ]]; then add PASS failed-units "no failed peri units"
    else add FAIL failed-units "failed: ${failed% }" "systemctl status ${failed% } --no-pager; journalctl -u ${failed%% *} -n 60 --no-pager; sudo systemctl reset-failed"; fi
}

check_system() {
    local use free t c thr bits=() v
    use=$(df -P / 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}'); free=$(df -Pm / 2>/dev/null | awk 'NR == 2 {print $4}')
    if [[ "$use" =~ ^[0-9]+$ ]]; then
        if [[ $use -ge 97 ]]; then add FAIL disk "root filesystem ${use}% full (${free} MB free)" "sudo journalctl --vacuum-size=50M; sudo apt-get clean; du -xh / | sort -h | tail"
        elif [[ $use -ge 85 ]]; then add WARN disk "root filesystem ${use}% full (${free} MB free)"
        else add PASS disk "root filesystem ${use}% full (${free} MB free)"; fi
    else add SKIP disk "df not available"; fi
    t=""
    [[ -r "$(rp /sys/class/thermal/thermal_zone0/temp)" ]] && t=$(head -n 1 "$(rp /sys/class/thermal/thermal_zone0/temp)" 2>/dev/null || true)
    if [[ "$t" =~ ^[0-9]+$ ]]; then
        c=$((t / 1000))
        if [[ $c -ge 85 ]]; then add FAIL temperature "${c} C - throttling territory" "vcgencmd get_throttled; improve airflow/case"
        elif [[ $c -ge 75 ]]; then add WARN temperature "${c} C - getting hot"
        else add PASS temperature "${c} C"; fi
    else add SKIP temperature "no thermal zone"; fi
    if have vcgencmd; then
        thr=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=//p' || true)
        if [[ "$thr" =~ ^0x[0-9a-fA-F]+$ ]]; then
            v=$((thr))
            (( v & 0x1 )) && bits+=("under-voltage NOW")
            (( v & 0x2 )) && bits+=("arm frequency capped NOW")
            (( v & 0x4 )) && bits+=("throttled NOW")
            (( v & 0x8 )) && bits+=("soft temperature limit NOW")
            (( v & 0x10000 )) && bits+=("under-voltage occurred")
            (( v & 0x20000 )) && bits+=("frequency cap occurred")
            (( v & 0x40000 )) && bits+=("throttling occurred")
            (( v & 0x80000 )) && bits+=("soft temp limit occurred")
            if [[ $v -eq 0 ]]; then add PASS throttling "no throttling or under-voltage since boot (0x0)"
            else add WARN throttling "$thr: ${bits[*]} - use a 5 V / 3 A supply and a short, thick cable" "vcgencmd get_throttled; dmesg | grep -i -E 'voltage|throttl'"; fi
        else add SKIP throttling "vcgencmd get_throttled gave no value"; fi
    else add SKIP throttling "vcgencmd not installed"; fi
}

# ------------------------------------------------------------------------------------------------- report
report_table() {
    local i n=0 pass=0 warn=0 fail=0 skip=0 overall=PASS
    printf '%-22s | %-6s | %s\n' "CHECK" "STATUS" "DETAIL"
    printf '%s\n' "-----------------------+--------+-----------------------------------------------------------"
    for i in "${!NAMES[@]}"; do
        printf '%-22s | %-6s | %s\n' "${NAMES[$i]}" "${STATUSES[$i]}" "${DETAILS[$i]}"
        case "${STATUSES[$i]}" in PASS) pass=$((pass + 1)) ;; WARN) warn=$((warn + 1)) ;; FAIL) fail=$((fail + 1)) ;; SKIP) skip=$((skip + 1)) ;; esac
        n=$((n + 1))
    done
    [[ $warn -gt 0 ]] && overall=WARN
    [[ $fail -gt 0 ]] && overall=FAIL
    echo
    echo "RESULT: $overall ($pass PASS, $warn WARN, $fail FAIL, $skip SKIP)"
    if [[ $warn -gt 0 || $fail -gt 0 ]]; then
        echo
        echo "Next steps:"
        for i in "${!NAMES[@]}"; do
            if [[ ( "${STATUSES[$i]}" == FAIL || "${STATUSES[$i]}" == WARN ) && -n "${HINTS[$i]}" ]]; then
                printf '  [%s] %s: %s\n' "${STATUSES[$i]}" "${NAMES[$i]}" "${HINTS[$i]}"
            fi
        done
    fi
    [[ $fail -eq 0 ]]
}

report_json() {
    local i
    for i in "${!NAMES[@]}"; do printf '%s\t%s\t%s\t%s\n' "${NAMES[$i]}" "${STATUSES[$i]}" "${DETAILS[$i]}" "${HINTS[$i]}"; done | python3 -c '
import json, socket, sys, time
checks = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    parts += [""] * (4 - len(parts))
    checks.append({"check": parts[0], "status": parts[1], "detail": parts[2], "hint": parts[3]})
counts = {k: sum(1 for c in checks if c["status"] == k) for k in ("PASS", "WARN", "FAIL", "SKIP")}
overall = "FAIL" if counts["FAIL"] else ("WARN" if counts["WARN"] else "PASS")
print(json.dumps({"overall": overall, "counts": counts, "checks": checks, "host": socket.gethostname(),
                  "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}))
'
    for i in "${!STATUSES[@]}"; do [[ "${STATUSES[$i]}" == FAIL ]] && return 1; done
    return 0
}

main() {
    have python3 || { echo "verify.sh: python3 is required" >&2; exit 2; }
    check_os
    check_boot
    check_display
    check_touch
    check_audio_card
    check_audio
    check_server
    check_openai
    check_head
    check_units
    check_kiosk
    check_audio_server
    check_audio_default
    check_failed_units
    check_system
    if [[ $JSON -eq 1 ]]; then report_json; else report_table; fi
}

main
exit $?
