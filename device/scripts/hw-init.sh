#!/usr/bin/env bash
# hw-init.sh - Peri hardware initialisation. Runs as root at EVERY boot from peri-hwinit.service (before peri-server and
# peri-kiosk) and can be run by hand at any time:
#
#     sudo /opt/peri/scripts/hw-init.sh [--no-wait] [--no-defaults] [--no-store] [--card ID]
#
#   1. backlight permissions: group "video" (user peri) may write brightness (the udev rule does the same for class devices).
#   2. waits up to PERI_HWINIT_CARD_WAIT seconds (default 30) for the WM8960 / seeed-voicecard ALSA card, then applies the
#      mixer levels by control NAME with `amixer cset` (every control guarded: absent controls are logged and skipped) and
#      stores the state with `alsactl store`. Levels can be tuned in /etc/peri/peri.env (read with grep, never sourced):
#      PERI_MIXER_CAPTURE (0-63, default 39) PERI_MIXER_BOOST (0-3, default 3) PERI_MIXER_ADC (0-255, default 195)
#      PERI_MIXER_SPEAKER (0-127, default 121 = 0 dB) PERI_MIXER_SPK_GAIN (0-5, default 4).
#   3. best effort, bounded by PERI_HWINIT_DEFAULTS_WAIT seconds (default 45): waits for the peri user's PipeWire /
#      PulseAudio, makes the WM8960 the default sink and source (wpctl set-default / pactl set-default-*), unmutes and sets
#      the sink volume from /var/lib/peri/settings.json (.audio.volume, default 70).
#
# This script is NEVER fatal: it always exits 0 (a missing card only produces log lines; scripts/verify.sh reports it).
# Output goes to stdout (= the journal under systemd). Environment: PERI_ROOT (fake-root prefix for tests), PERI_USER
# (default peri), PERI_STATE_DIR (default /var/lib/peri), PERI_ENV_FILE (default /etc/peri/peri.env).
set -uo pipefail

ROOT="${PERI_ROOT:-}"; ROOT="${ROOT%/}"
PERI_USER="${PERI_USER:-peri}"
STATE_DIR="${PERI_STATE_DIR:-/var/lib/peri}"
ENV_FILE="${PERI_ENV_FILE:-/etc/peri/peri.env}"
CARD_WAIT="${PERI_HWINIT_CARD_WAIT:-30}"
DEFAULTS_WAIT="${PERI_HWINIT_DEFAULTS_WAIT:-45}"
CARD_PATTERN='wm8960|seeed|voicecard'          # matched (case-insensitively) against card id + name in /proc/asound/cards
NODE_PATTERN='wm8960|seeed|soc_sound|voicecard' # matched against PipeWire/Pulse node names

DO_DEFAULTS=1; DO_STORE=1; FORCE_CARD=""

log()  { printf 'peri-hwinit: %s\n' "$*"; }
warn() { printf 'peri-hwinit: WARNING: %s\n' "$*" >&2; }   # stderr: level() is used inside $(...)
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-wait) CARD_WAIT=0 ;;
        --no-defaults) DO_DEFAULTS=0 ;;
        --no-store) DO_STORE=0 ;;
        --card) shift; FORCE_CARD="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "hw-init.sh: unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

# env_get KEY DEFAULT : process environment first, then peri.env (grep, never sourced), then DEFAULT.
env_get() {
    local key="$1" def="$2" val="${!1:-}"
    if [[ -z "$val" && -r "$ROOT$ENV_FILE" ]]; then
        val=$(grep -E "^[[:space:]]*${key}=" "$ROOT$ENV_FILE" 2>/dev/null | tail -n 1 | sed -E "s/^[^=]*=[[:space:]]*//; s/[[:space:]]+\$//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/" || true)
    fi
    if [[ -n "$val" ]]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

# level KEY DEFAULT MAX : integer 0..MAX from env/peri.env, else DEFAULT (with a warning when the value is unusable).
level() {
    local v; v=$(env_get "$1" "$2")
    if [[ "$v" =~ ^[0-9]+$ && "$v" -le "$3" ]]; then printf '%s' "$v"; else warn "ignoring $1='$v' (want an integer 0-$3), using $2"; printf '%s' "$2"; fi
}

# ------------------------------------------------------------------------------------------------ 1. backlight
fix_backlight() {
    local f n=0
    if ! getent group video >/dev/null 2>&1; then warn "group 'video' does not exist: backlight permissions not changed"; return 0; fi
    for f in "$ROOT"/sys/class/backlight/*/brightness "$ROOT/sys/waveshare/rpi_backlight/brightness"; do
        [[ -e "$f" ]] || continue
        if chgrp video "$f" 2>/dev/null && chmod g+w "$f" 2>/dev/null; then n=$((n + 1)); else warn "could not fix permissions of ${f#"$ROOT"}"; fi
    done
    log "backlight: group video may set the brightness through $n file(s)"
}

# ----------------------------------------------------------------------------------------------------- 2. card
# find_card : print "NUM ID" of the first WM8960-like ALSA card (empty output when there is none)
find_card() {
    local f="$ROOT/proc/asound/cards" line
    if [[ -r "$f" ]]; then
        line=$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\) \[\([^] ]*\)[[:space:]]*\]: \(.*\)$/\1 \2 \3/p' "$f" | grep -iE "$CARD_PATTERN" | head -n 1 || true)
    elif have aplay; then
        line=$(aplay -l 2>/dev/null | sed -n 's/^card \([0-9][0-9]*\): \([^ ]*\) \[\([^]]*\)\].*$/\1 \2 \3/p' | grep -iE "$CARD_PATTERN" | head -n 1 || true)
    else
        line=""
    fi
    [[ -n "$line" ]] && printf '%s %s\n' "${line%% *}" "$(printf '%s' "${line#* }" | cut -d' ' -f1)"
    return 0
}

wait_for_card() {
    local deadline=$(( $(date +%s) + CARD_WAIT )) found
    while :; do
        found=$(find_card)
        if [[ -n "$found" ]]; then printf '%s' "$found"; return 0; fi
        (( $(date +%s) >= deadline )) && return 1
        sleep 1
    done
}

APPLIED=0; SKIPPED=0; CARD_REF=""
# cset NAME VALUE : set one mixer control by name; a control the driver does not have is logged and skipped.
cset() {
    if amixer -q -c "$CARD_REF" cset "name=$1" "$2" >/dev/null 2>&1; then
        APPLIED=$((APPLIED + 1))
    else
        SKIPPED=$((SKIPPED + 1))
        log "mixer control not present (or value rejected), skipped: $1 = $2"
    fi
}

apply_mixer() {
    local cap boost adc spk gain
    cap=$(level PERI_MIXER_CAPTURE 39 63); boost=$(level PERI_MIXER_BOOST 3 3); adc=$(level PERI_MIXER_ADC 195 255)
    spk=$(level PERI_MIXER_SPEAKER 121 127); gain=$(level PERI_MIXER_SPK_GAIN 4 5)
    log "mixer levels: capture=$cap boost=$boost adc=$adc speaker=$spk speaker-gain=$gain"
    # capture path: MEMS mics -> LINPUT1/RINPUT1 -> boost mixer -> input mixer -> ADC
    cset 'Capture Switch' on,on
    cset 'Capture Volume' "$cap,$cap"
    cset 'Left Input Boost Mixer LINPUT1 Volume' "$boost"
    cset 'Right Input Boost Mixer RINPUT1 Volume' "$boost"
    cset 'Left Boost Mixer LINPUT1 Switch' on
    cset 'Right Boost Mixer RINPUT1 Switch' on
    cset 'Left Input Mixer Boost Switch' on
    cset 'Right Input Mixer Boost Switch' on
    cset 'ADC PCM Capture Volume' "$adc,$adc"
    cset 'ALC Function' Off
    # playback path: DAC -> output mixer (OFF by default = silence!) -> speaker / headphone
    cset 'Playback Volume' 255,255
    cset 'Left Output Mixer PCM Playback Switch' on
    cset 'Right Output Mixer PCM Playback Switch' on
    cset 'Speaker Playback Volume' "$spk,$spk"
    cset 'Headphone Playback Volume' 109,109
    cset 'Speaker DC Volume' "$gain"
    cset 'Speaker AC Volume' "$gain"
    cset 'Speaker Playback ZC Switch' off,off
    cset 'PCM Playback -6dB Switch' off
    # no bypass / LINPUT3 leakage from the inputs to the outputs (feedback)
    cset 'Left Output Mixer Boost Bypass Switch' off
    cset 'Right Output Mixer Boost Bypass Switch' off
    cset 'Left Output Mixer LINPUT3 Switch' off
    cset 'Right Output Mixer LINPUT3 Switch' off
    log "mixer: applied $APPLIED control(s), skipped $SKIPPED (not present on this driver)"
}

init_card() {
    local found num id
    if [[ -n "$FORCE_CARD" ]]; then
        CARD_REF="$FORCE_CARD"; log "using the card given on the command line: $CARD_REF"
    else
        if ! found=$(wait_for_card); then
            warn "no WM8960 / seeed-voicecard ALSA card appeared within ${CARD_WAIT}s (see: aplay -l ; dmesg | grep -i -E 'wm8960|seeed|i2s') - mixer not initialised"
            return 1
        fi
        num=${found%% *}; id=${found#* }
        CARD_REF="$id"; log "audio card: $num [$id]"
    fi
    if ! have amixer; then warn "amixer is not installed (apt install alsa-utils): mixer not initialised"; return 1; fi
    apply_mixer
    if [[ "$DO_STORE" == 1 && "$APPLIED" -gt 0 ]]; then
        if have alsactl; then
            if alsactl store "$CARD_REF" >/dev/null 2>&1; then log "alsactl store: mixer state saved"; else warn "alsactl store failed (soft): the levels are re-applied at every boot anyway"; fi
        else
            log "alsactl not installed: mixer state not stored (re-applied at every boot anyway)"
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------------------ 3. audio server
settings_volume() {
    local f="$ROOT$STATE_DIR/settings.json" v=""
    if [[ -r "$f" ]] && have python3; then
        v=$(python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("audio", {}).get("volume")
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        print(int(max(0, min(100, v))))
except Exception:
    pass
PY
)
    fi
    if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; else printf '70'; fi
}

PERI_UID=""
# as_peri CMD... : run CMD as the peri user with XDG_RUNTIME_DIR pointing at its runtime dir
as_peri() {
    local rt="$ROOT/run/user/$PERI_UID"
    if [[ "$(id -u)" == "$PERI_UID" ]]; then
        env "XDG_RUNTIME_DIR=$rt" "$@"
    elif [[ "$(id -u)" == 0 ]] && have runuser; then
        runuser -u "$PERI_USER" -- env "XDG_RUNTIME_DIR=$rt" "$@"
    else
        env "XDG_RUNTIME_DIR=$rt" "$@"
    fi
}

# pipewire_ids : print "SINK_ID SOURCE_ID" of the WM8960 nodes found in `pw-dump` (either may be empty). The node NAME differs by
# board (Pi 4: alsa_output.platform-soc_sound..., Pi 5 may be ...platform-sound...), so the ALSA card name / description
# ("wm8960-soundcard", "seeed-2mic-voicecard") is matched too.
pipewire_ids() {
    as_peri timeout 8 pw-dump 2>/dev/null | NODE_PATTERN="$NODE_PATTERN" python3 -c '
import json, os, re, sys
pat = re.compile(os.environ["NODE_PATTERN"], re.I)
KEYS = ("node.name", "node.nick", "node.description", "alsa.card_name", "alsa.long_card_name", "api.alsa.card.name",
        "api.alsa.card.longname", "device.description", "device.product.name")
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sink = src = ""
for o in data:
    if o.get("type") != "PipeWire:Interface:Node":
        continue
    p = (o.get("info") or {}).get("props") or {}
    cls = str(p.get("media.class", ""))
    name = str(p.get("node.name", ""))
    if not (name.startswith("alsa_output") or name.startswith("alsa_input")):
        continue
    if not pat.search(" ".join(str(p.get(k, "")) for k in KEYS)):
        continue
    if cls == "Audio/Sink" and not sink:
        sink = str(o.get("id"))
    elif cls == "Audio/Source" and not src:
        src = str(o.get("id"))
print(sink, src)
' 2>/dev/null
}

# pulse_names : print "SINK_NAME SOURCE_NAME" of the WM8960 devices known to the Pulse-compatible server. Uses the long
# listing so that the card description / properties ("wm8960-soundcard") match as well as the device name.
pulse_names() {
    local sink src
    sink=$(as_peri timeout 8 pactl list sinks 2>/dev/null | pulse_pick_name || true)
    src=$(as_peri timeout 8 pactl list sources 2>/dev/null | pulse_pick_name || true)
    printf '%s %s\n' "$sink" "$src"
}
# pulse_pick_name : stdin = `pactl list sinks|sources`; prints the Name: of the first block that mentions the WM8960 (never a .monitor)
pulse_pick_name() {
    awk -v pat="$NODE_PATTERN" '
        function flush() { if (name != "" && name !~ /\.monitor$/ && tolower(block) ~ pat && !done) { print name; done = 1 } }
        /^(Sink|Source) #/ { flush(); name = ""; block = "" }
        /^[ \t]+Name: / { name = $2 }
        { block = block "\n" $0 }
        END { flush() }'
}

# do_as_peri MESSAGE CMD... : run CMD as the peri user; log MESSAGE on success, a warning otherwise
do_as_peri() {
    local msg="$1"; shift
    if as_peri "$@" >/dev/null 2>&1; then log "$msg"; else warn "failed: $*"; fi
}

set_defaults() {
    local start deadline rt mode="" vol ids sink="" src="" sink_seen=0
    start=$(date +%s); deadline=$(( start + DEFAULTS_WAIT ))
    if ! PERI_UID=$(id -u "$PERI_USER" 2>/dev/null); then log "audio defaults: user '$PERI_USER' does not exist: skipped"; return 0; fi
    if have wpctl && have pw-dump && have python3; then mode=pipewire
    elif have pactl; then mode=pulse
    else log "audio defaults: no wpctl/pw-dump/pactl installed (plain ALSA setup): nothing to do"; return 0; fi
    rt="$ROOT/run/user/$PERI_UID"
    # wait for the user's audio server socket (the user manager is started by linger; PipeWire is socket-activated)
    while [[ ! -e "$rt/pipewire-0" && ! -e "$rt/pulse/native" ]]; do
        if (( $(date +%s) - start >= 20 )) || (( $(date +%s) >= deadline )); then
            log "audio defaults: no PipeWire/PulseAudio socket in ${rt#"$ROOT"} after 20s: skipped (WirePlumber priorities still prefer the WM8960)"
            return 0
        fi
        sleep 1
    done
    # wait for the card's nodes to show up (first the sink, then up to 5 more seconds for the source)
    while :; do
        if [[ "$mode" == pipewire ]]; then ids=$(pipewire_ids); else ids=$(pulse_names); fi
        sink=${ids%% *}; src=${ids#* }; [[ "$src" == "$ids" ]] && src=""
        if [[ -n "$sink" ]]; then
            [[ $sink_seen -eq 0 ]] && sink_seen=$(date +%s)
            [[ -n "$src" ]] && break
            (( $(date +%s) - sink_seen >= 5 )) && break
        fi
        (( $(date +%s) >= deadline )) && break
        sleep 1
    done
    if [[ -z "$sink" ]]; then
        warn "audio defaults: no WM8960 playback node appeared in the $mode server within ${DEFAULTS_WAIT}s: defaults not set"
        return 0
    fi
    vol=$(settings_volume)
    if [[ "$mode" == pipewire ]]; then
        do_as_peri "default sink -> PipeWire node $sink" wpctl set-default "$sink"
        if [[ -n "$src" ]]; then do_as_peri "default source -> PipeWire node $src" wpctl set-default "$src"
        else warn "no WM8960 capture node found: default source not set"; fi
        as_peri wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 >/dev/null 2>&1
        do_as_peri "sink unmuted, volume ${vol}%" wpctl set-volume @DEFAULT_AUDIO_SINK@ "${vol}%"
        as_peri wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0 >/dev/null 2>&1
    else
        do_as_peri "default sink -> $sink" pactl set-default-sink "$sink"
        if [[ -n "$src" ]]; then do_as_peri "default source -> $src" pactl set-default-source "$src"
        else warn "no WM8960 capture device found: default source not set"; fi
        as_peri pactl set-sink-mute "$sink" 0 >/dev/null 2>&1
        do_as_peri "sink unmuted, volume ${vol}%" pactl set-sink-volume "$sink" "${vol}%"
        if [[ -n "$src" ]]; then as_peri pactl set-source-mute "$src" 0 >/dev/null 2>&1; fi
    fi
    return 0
}

# ------------------------------------------------------------------------------------------------------ main
log "start (user=$PERI_USER, card wait ${CARD_WAIT}s)"
fix_backlight
CARD_OK=0
init_card && CARD_OK=1
if [[ "$DO_DEFAULTS" != 1 ]]; then log "audio defaults: skipped (--no-defaults)"
elif [[ $CARD_OK -ne 1 ]]; then log "audio defaults: skipped (no WM8960 card, so there is nothing to make the default)"
else set_defaults || true; fi
fix_backlight >/dev/null   # second pass: a panel driver that bound late has its brightness file by now
log "done"
exit 0
