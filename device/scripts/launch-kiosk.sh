#!/usr/bin/env bash
# launch-kiosk.sh - ExecStart of peri-kiosk.service (user peri on tty1). Starts the compositor chosen by PERI_KIOSK and runs
# the browser in it (scripts/launch-browser.sh):
#     PERI_KIOSK=cage   cage -s -- launch-browser.sh                  Wayland kiosk compositor (Bookworm/Trixie default)
#     PERI_KIOSK=x11    xinit x11-session.sh -- :0 vtN ...             X11 + openbox (Bullseye default)
#     PERI_KIOSK=labwc  labwc -C /etc/peri/labwc -S launch-browser.sh   only when asked for
# PERI_KIOSK comes from /etc/peri/peri.env (EnvironmentFile= in the unit; written by the kiosk step, changed with
# `peri-kiosk mode`). Empty/auto = the first one that is installed (cage, x11, labwc); a chosen one that is not installed falls
# back to the next installed one. Nothing here changes the system: it only starts processes.
#
# Screen never blanks and the pointer stays hidden in every mode: X11 - x11-session.sh runs `xset s off -dpms s noblank` and
# unclutter; cage / labwc - neither has an idle blanker and no idle daemon is started (labwc runs with the private config dir
# /etc/peri/labwc, so no desktop autostart), the UI hides the pointer itself (cursor:none) and a Wayland compositor shows
# none without a mouse; the text console cannot blank either (consoleblank=0 on the kernel command line, see the boot step).
#
# Environment: PERI_KIOSK, PERI_KIOSK_OUTPUT (preferred output, e.g. DSI-1; honoured by x11 and labwc), PERI_URL / PERI_PORT /
# PERI_STATE_DIR / PERI_KIOSK_WAIT / PERI_CHROMIUM_DEBUG_PORT (see launch-browser.sh), PERI_LABWC_DIR (/etc/peri/labwc),
# PERI_KIOSK_FAIL_SLEEP (seconds to wait before exiting when no compositor is installed; default 30, slows the restart loop).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf 'peri-kiosk: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -e '/^set -u/d' -e 's/^# \{0,1\}//'; exit 0 ;;
esac

# Neither the compositor nor the browser needs the API key or the admin token (peri.env also carries them).
unset OPENAI_API_KEY PERI_ADMIN_TOKEN

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PERI_STATE_DIR="${PERI_STATE_DIR:-/var/lib/peri}"
unset DISPLAY WAYLAND_DISPLAY                      # a stale value from a login shell would make the compositor a nested client
LABWC_DIR="${PERI_LABWC_DIR:-/etc/peri/labwc}"

mode_available() {
    case "$1" in
        cage) have cage ;;
        x11) have xinit && { have Xorg || [[ -x /usr/lib/xorg/Xorg ]]; } ;;
        labwc) have labwc ;;
        *) return 1 ;;
    esac
}

requested="${PERI_KIOSK:-auto}"
case "$requested" in cage|x11|labwc|auto) ;; "") requested=auto ;; *) log "unknown PERI_KIOSK='$requested' - using auto"; requested=auto ;; esac
if [[ "$requested" == auto ]]; then order=(cage x11 labwc); else order=("$requested" cage x11 labwc); fi
mode=""
for m in "${order[@]}"; do
    if mode_available "$m"; then mode="$m"; break; fi
done
if [[ -z "$mode" ]]; then
    log "ERROR: no kiosk compositor is installed (need cage, xinit+Xorg or labwc): sudo /opt/peri/install.sh --only kiosk"
    sleep "${PERI_KIOSK_FAIL_SLEEP:-30}"            # slow the systemd restart loop down instead of spamming the journal
    exit 1
fi
[[ "$mode" == "$requested" || "$requested" == auto ]] || log "WARNING: PERI_KIOSK=$requested is not installed - using $mode instead"
log "compositor: $mode (PERI_KIOSK=${PERI_KIOSK:-unset}); browser: $SCRIPT_DIR/launch-browser.sh"
export PERI_KIOSK_RESOLVED="$mode"

case "$mode" in
    cage)
        export XDG_SESSION_TYPE=wayland WLR_LIBINPUT_NO_DEVICES=1      # cage still starts when the touch controller is missing
        [[ -n "${PERI_KIOSK_OUTPUT:-}" ]] && log "note: cage cannot choose an output (PERI_KIOSK_OUTPUT=$PERI_KIOSK_OUTPUT ignored); use install.sh --disable-hdmi to keep HDMI off"
        # -s: allow VT switching (Ctrl+Alt+F2 gives a login on tty2 with a USB keyboard)
        exec cage -s -- "$SCRIPT_DIR/launch-browser.sh"
        ;;
    x11)
        export XDG_SESSION_TYPE=x11
        vt=1
        if tty_name=$(tty 2>/dev/null) && [[ "$tty_name" =~ ^/dev/tty([0-9]+)$ ]]; then vt="${BASH_REMATCH[1]}"; fi
        exec xinit "$SCRIPT_DIR/x11-session.sh" -- :0 "vt$vt" -keeptty -nolisten tcp -noreset
        ;;
    labwc)
        export XDG_SESSION_TYPE=wayland WLR_LIBINPUT_NO_DEVICES=1
        if labwc --help 2>&1 | grep -q -- '--session'; then
            exec labwc -C "$LABWC_DIR" -S "$SCRIPT_DIR/launch-browser.sh"
        fi
        # older labwc: no -S (exit when the session command exits) - emulate it: ask the compositor to quit when the browser ends
        exec labwc -C "$LABWC_DIR" -s "sh -c '$SCRIPT_DIR/launch-browser.sh; labwc --exit'"
        ;;
esac
