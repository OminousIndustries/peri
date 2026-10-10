#!/usr/bin/env bash
# x11-session.sh - the X client that xinit runs (launch-kiosk.sh with PERI_KIOSK=x11); DISPLAY is set. It prepares the X
# session and finishes with `exec launch-browser.sh`, so when the browser exits X ends and systemd restarts the kiosk unit:
#   * screen saver and DPMS off (an appliance screen must never blank)
#   * when a DSI output is connected every other connected output (HDMI ...) is switched off, the DSI output is primary;
#     PERI_KIOSK_OUTPUT (e.g. DSI-1) overrides which output that is
#   * touch is mapped to that output (xinput map-to-output) so touches land where they are made
#   * the mouse pointer is hidden (unclutter-xfixes / unclutter)
#   * openbox provides the fullscreen handling Chromium's --kiosk needs (X has no compositor of its own)
# Every step is best effort: a missing tool is logged, never fatal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf 'peri-x11: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '/^set -u/d' -e 's/^# \{0,1\}//'; exit 0 ;;
esac

if have xset; then
    xset s off 2>/dev/null; xset -dpms 2>/dev/null; xset s noblank 2>/dev/null
else
    log "xset not found (apt install x11-xserver-utils): the screen may blank"
fi

# ---- outputs
primary="${PERI_KIOSK_OUTPUT:-}"
if have xrandr; then
    connected=$(xrandr 2>/dev/null | awk '$2 == "connected" {print $1}')
    if [[ -z "$primary" ]]; then
        primary=$(printf '%s\n' "$connected" | grep -E '^DSI' | head -n 1 || true)
    fi
    if [[ -n "$primary" ]] && printf '%s\n' "$connected" | grep -qxF -- "$primary"; then
        for out in $connected; do
            if [[ "$out" != "$primary" ]]; then xrandr --output "$out" --off 2>/dev/null && log "switched off output $out"; fi
        done
        xrandr --output "$primary" --auto --primary 2>/dev/null && log "primary output: $primary"
    else
        log "no DSI output connected (connected: ${connected:-none}): leaving the outputs as they are"
        primary=""
    fi
else
    log "xrandr not found (apt install x11-xserver-utils): outputs left as they are"
fi

# ---- touch -> the panel
if have xinput && [[ -n "$primary" ]]; then
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        xinput map-to-output "$name" "$primary" 2>/dev/null && log "touch device '$name' mapped to $primary"
    done < <(xinput list --name-only 2>/dev/null | grep -iE 'goodix|touchscreen|ft5406' | sort -u || true)
fi

# ---- pointer
if have unclutter-xfixes; then
    if unclutter-xfixes --help 2>&1 | grep -q -- '--hide-on-touch'; then unclutter-xfixes --timeout 1 --hide-on-touch &
    else unclutter-xfixes --timeout 1 & fi
elif have unclutter; then
    unclutter -idle 0.1 -root &
else
    log "unclutter not installed: the mouse pointer stays visible (the UI hides it in CSS)"
fi

# ---- window manager
if have openbox; then
    openbox --sm-disable >/dev/null 2>&1 &
    sleep 0.5
else
    log "openbox not installed (apt install openbox): Chromium's kiosk mode may not fill the screen"
fi

exec "$SCRIPT_DIR/launch-browser.sh"
