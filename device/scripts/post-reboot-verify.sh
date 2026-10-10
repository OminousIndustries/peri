#!/usr/bin/env bash
# post-reboot-verify.sh - run this after the reboot that finishes the installation:
#
#     sudo /opt/peri/scripts/post-reboot-verify.sh [--wait SECONDS] [--no-audio] [--json]
#
# It waits (bounded, default 120 s) for peri-server to answer and for the kiosk to settle (peri-kiosk active, the hardware
# init finished, a UI websocket connected), then runs verify.sh, prints the final verdict and - on FAIL - the exact commands to
# run next, followed by the reminder of the physical checks only a human can do (screen, touch, sound, neck).
#
#   --wait N     give the device N seconds to come up (default 120)
#   --no-audio   do not play the tone / record the microphone
#   --json       verify.sh's JSON on stdout and nothing else (progress goes to stderr); exit status as below
# Exit status: 0 = PASS or WARN, 1 = at least one check FAILED.
# Environment: as verify.sh (PERI_BASE_URL, PERI_ROOT, PERI_USER ...).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAIT=120; NO_AUDIO=0; JSON=0

usage() { sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait) shift; WAIT="${1:-}" ;;
        --no-audio) NO_AUDIO=1 ;;
        --json) JSON=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "post-reboot-verify.sh: unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
[[ "$WAIT" =~ ^[0-9]+$ ]] || { echo "post-reboot-verify.sh: --wait wants a number of seconds" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }
say() { if [[ $JSON -eq 1 ]]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }

BASE_URL="${PERI_BASE_URL:-}"
if [[ -z "$BASE_URL" ]]; then
    port=8420
    if [[ -r "${PERI_ROOT:-}/etc/peri/peri.env" ]]; then
        p=$(grep -E '^[[:space:]]*PERI_PORT=' "${PERI_ROOT:-}/etc/peri/peri.env" 2>/dev/null | tail -n 1 | sed -E 's/^[^=]*=[[:space:]]*//; s/["'"'"']//g; s/[[:space:]]+$//' || true)
        [[ "$p" =~ ^[0-9]{2,5}$ ]] && port="$p"
    fi
    BASE_URL="http://127.0.0.1:${PERI_PORT:-$port}"
fi
BASE_URL="${BASE_URL%/}"

http_get() {
    if have curl; then curl -fsS -m 4 "$1" 2>/dev/null
    elif have python3; then python3 -c 'import sys, urllib.request; sys.stdout.write(urllib.request.urlopen(sys.argv[1], timeout=4).read().decode())' "$1" 2>/dev/null
    else return 1; fi
}

ui_clients() {
    http_get "$BASE_URL/api/system/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ui",{}).get("clients",-1))' 2>/dev/null || echo -1
}

START=$SECONDS
DEADLINE=$((START + WAIT))
say "== Peri post-reboot verification (waiting up to ${WAIT}s for the device to come up) =="

# ---- 1. the server
last=-100
while ! http_get "$BASE_URL/healthz" >/dev/null; do
    if (( SECONDS >= DEADLINE )); then say "peri-server did not answer within ${WAIT}s - verify.sh will report it"; break; fi
    if (( SECONDS - last >= 10 )); then say "  [+$((SECONDS - START))s] waiting for peri-server at $BASE_URL/healthz ..."; last=$SECONDS; fi
    sleep 2
done
if http_get "$BASE_URL/healthz" >/dev/null; then say "  [+$((SECONDS - START))s] peri-server answers"; fi

# ---- 2. the kiosk and the hardware init settle
last=-100; settled=0
while :; do
    kiosk="unknown"; hw="unknown"
    if have systemctl; then kiosk=$(systemctl is-active peri-kiosk 2>/dev/null || true); hw=$(systemctl is-active peri-hwinit 2>/dev/null || true); fi
    clients=$(ui_clients)
    if [[ "$kiosk" == active && "$hw" != activating && "$clients" =~ ^[0-9]+$ && "$clients" -ge 1 ]]; then settled=1; break; fi
    if ! have systemctl && [[ "$clients" =~ ^[0-9]+$ && "$clients" -ge 1 ]]; then settled=1; break; fi
    (( SECONDS >= DEADLINE )) && break
    if (( SECONDS - last >= 10 )); then say "  [+$((SECONDS - START))s] waiting for the kiosk: peri-kiosk=${kiosk:-?}, peri-hwinit=${hw:-?}, UI clients=$clients"; last=$SECONDS; fi
    sleep 3
done
if [[ $settled -eq 1 ]]; then say "  [+$((SECONDS - START))s] kiosk is up and the UI is connected"
else say "  [+$((SECONDS - START))s] the kiosk did not settle in time (peri-kiosk=${kiosk:-?}, UI clients=${clients:-?}) - verify.sh will show what is wrong"; fi

# ---- 3. the checks
args=(--wait "$([[ $settled -eq 1 ]] && echo 10 || echo 2)")     # everything that could settle has had its time already
[[ $NO_AUDIO -eq 1 ]] && args+=(--no-audio)
[[ $JSON -eq 1 ]] && args+=(--json)
out=$(bash "$SCRIPT_DIR/verify.sh" "${args[@]}"); rc=$?
printf '%s\n' "$out"
[[ $JSON -eq 1 ]] && exit "$rc"

echo
if [[ $rc -eq 0 ]]; then
    if grep -q '^RESULT: WARN' <<< "$out"; then verdict=WARN; else verdict=PASS; fi
else
    verdict=FAIL
fi
echo "FINAL VERDICT: $verdict"
if [[ "$verdict" == FAIL ]]; then
    cat <<'EOF'

What to run next (in this order):
  sudo journalctl -b -u peri-server -u peri-kiosk -u peri-hwinit --no-pager | tail -n 150
  sudo peri-config status                        # services + server status summary
  sudo peri-kiosk status; sudo peri-kiosk logs   # compositor / browser
  sudo peri-config key-check                     # OpenAI key + reachability
  sudo tail -n 80 /var/log/peri-install.log      # what the installer did and why
  sudo /opt/peri/scripts/verify.sh               # run again when fixed
EOF
fi
cat <<'EOF'

Physical checks only a human can do:
  [ ] the panel shows the Peri UI (not a console, a desktop or a blank screen); the boot splash appeared during the boot
  [ ] touch works: tap the screen - the UI reacts where you touch
  [ ] sound out: the test tone from verify.sh was audible from the speakers (sudo /opt/peri/scripts/audio-test.sh plays it again)
  [ ] sound in: speak or clap - the level in audio-test.sh moves, and the UI hears you

Optional Arduino: powered and tested separately. The standard enclosure has no
Pi-to-Arduino connection; these Pi checks cannot verify its movement.
EOF
exit "$rc"
