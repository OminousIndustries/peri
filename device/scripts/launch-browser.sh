#!/usr/bin/env bash
# launch-browser.sh - run Chromium in kiosk mode on the Peri UI. Started by launch-kiosk.sh INSIDE the compositor (cage /
# labwc: Wayland) or by x11-session.sh (X11), as user peri. It can also be run by hand from a desktop terminal.
#
# Robustness (all of it matters on an unattended appliance):
#   * waits for the server's /healthz (up to PERI_KIOSK_WAIT seconds, default 60) and then launches ANYWAY: Chromium shows its
#     own error page and the UI watchdog / Restart= recover the rest
#   * removes stale Singleton* locks from the profile (a crash or power cut leaves them behind; a cloned SD card has another hostname)
#   * marks the previous session as cleanly exited in Default/Preferences (no "Chromium didn't shut down correctly" bubble)
#   * flags per compositor: --ozone-platform=wayland only when WAYLAND_DISPLAY is set (cage/labwc), nothing extra under X11
#   * `exec chromium`: the browser IS the session's main process - when it exits the compositor ends and systemd restarts the unit
#
# Environment (all optional; systemd passes /etc/peri/peri.env): PERI_URL (default http://127.0.0.1:$PERI_PORT/), PERI_PORT
# (8420), PERI_STATE_DIR (/var/lib/peri; the profile is $PERI_STATE_DIR/chromium), PERI_KIOSK_WAIT (60),
# PERI_CHROMIUM_DEBUG_PORT (9222, loopback only; set it EMPTY to switch the debugging port off), PERI_CHROMIUM_BIN.
set -u

log() { printf 'peri-browser: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '/^set -u/d' -e 's/^# \{0,1\}//'; exit 0 ;;
esac

# The compositor and the browser never need the API key or the admin token.
unset OPENAI_API_KEY PERI_ADMIN_TOKEN

URL="${PERI_URL:-http://127.0.0.1:${PERI_PORT:-8420}/}"
STATE="${PERI_STATE_DIR:-/var/lib/peri}"
PROFILE="$STATE/chromium"
WAIT="${PERI_KIOSK_WAIT:-60}"
[[ "$WAIT" =~ ^[0-9]+$ ]] || WAIT=60
DEBUG_PORT="${PERI_CHROMIUM_DEBUG_PORT-9222}"          # `-` not `:-`: an explicitly empty value disables the port
ORIGIN=$(printf '%s' "$URL" | sed -E 's|^(https?://[^/]+).*$|\1|')

# ---------------------------------------------------------------------------------------------- the browser
CHROMIUM="${PERI_CHROMIUM_BIN:-}"
if [[ -z "$CHROMIUM" ]]; then
    for c in chromium chromium-browser; do have "$c" && { CHROMIUM=$(command -v "$c"); break; }; done
fi
[[ -n "$CHROMIUM" ]] || { log "ERROR: neither chromium nor chromium-browser is installed (sudo apt install chromium)"; exit 1; }

# -------------------------------------------------------------------------------------------------- profile
mkdir -p "$PROFILE" 2>/dev/null || log "WARNING: cannot create the profile directory $PROFILE"
if have pgrep && pgrep -u "$(id -u)" -f -- "--user-data-dir=$PROFILE" >/dev/null 2>&1; then
    log "another Chromium is already running with the profile $PROFILE: not starting a second one"
    exit 1
fi
rm -f "$PROFILE"/SingletonLock "$PROFILE"/SingletonSocket "$PROFILE"/SingletonCookie 2>/dev/null

fix_preferences() {
    local f="$PROFILE/Default/Preferences"
    [[ -f "$f" ]] || return 0
    if have python3; then
        python3 - "$f" <<'PY' 2>/dev/null && return 0
import json, os, sys
p = sys.argv[1]
try:
    with open(p, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)          # unreadable/corrupt: leave it, Chromium rewrites it
prof = d.setdefault("profile", {})
if prof.get("exit_type") != "Normal" or prof.get("exited_cleanly") is not True:
    prof["exit_type"] = "Normal"
    prof["exited_cleanly"] = True
    tmp = p + ".peri-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh, separators=(",", ":"))
    os.replace(tmp, p)
PY
    fi
    sed -i -e 's/"exited_cleanly":false/"exited_cleanly":true/' -e 's/"exit_type":"[A-Za-z]*"/"exit_type":"Normal"/' "$f" 2>/dev/null || true
}
fix_preferences

# ------------------------------------------------------------------------------------------ wait for the UI
http_ok() {
    if have curl; then curl -fsS -m 3 -o /dev/null "$1" 2>/dev/null
    elif have python3; then python3 -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=3).read(1)' "$1" 2>/dev/null
    else return 1; fi
}
if [[ "$WAIT" -gt 0 ]]; then
    end=$((SECONDS + WAIT)); up=0
    while (( SECONDS < end )); do
        if http_ok "$ORIGIN/healthz"; then up=1; break; fi
        sleep 1
    done
    if [[ $up -eq 1 ]]; then log "server is up ($ORIGIN/healthz)"
    else log "WARNING: $ORIGIN/healthz did not answer within ${WAIT}s - launching the browser anyway"; fi
fi

# ------------------------------------------------------------------------------------------------- launch
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

FLAGS=(
    --kiosk --noerrdialogs --disable-infobars --no-first-run --no-default-browser-check
    --disable-session-crashed-bubble --disable-translate "--disable-features=TranslateUI,Translate"
    --autoplay-policy=no-user-gesture-required --overscroll-history-navigation=0 --disable-pinch
    --check-for-update-interval=31536000 "--user-data-dir=$PROFILE" --password-store=basic
    --enable-gpu-rasterization --ignore-gpu-blocklist --force-device-scale-factor=1 --touch-events=enabled
    --disable-background-networking --disable-sync --disable-component-update --disable-breakpad
    # microphone without a prompt: the managed policy allows it for the UI origin, this flag is the belt to that pair of braces
    --use-fake-ui-for-media-stream
)
if [[ -n "$DEBUG_PORT" ]]; then
    FLAGS+=("--remote-debugging-port=$DEBUG_PORT" "--remote-debugging-address=127.0.0.1")
fi
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    FLAGS+=(--ozone-platform=wayland)
fi

SESSION=none
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then SESSION=wayland; elif [[ -n "${DISPLAY:-}" ]]; then SESSION=x11; fi
log "starting $CHROMIUM on $URL (profile $PROFILE, session: $SESSION)"
exec "$CHROMIUM" "${FLAGS[@]}" "$URL"
