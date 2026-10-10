#!/usr/bin/env bash
# ui-watchdog.sh - one pass of the Peri UI watchdog. Run as root by peri-ui-watchdog.timer every 30 s (logs to the
# journal with the identifier "peri-ui-watchdog": journalctl -t peri-ui-watchdog).
#
# What it does: the kiosk browser can wedge (GPU hiccup, renderer crash loop, lost websocket) while systemd still thinks
# peri-kiosk.service is fine. The server knows how many UI websockets are connected (/api/system/status -> .ui.clients).
# When the server has been healthy for a while and NO UI is connected for 3 consecutive passes (~90 s) the kiosk is
# restarted: `systemctl restart peri-kiosk`.
#
# Safety rules (each one is a "do nothing" exit, on purpose):
#   * PERI_UI_WATCHDOG=0 in /etc/peri/peri.env disables it.
#   * peri-kiosk not active (stopped by `peri-kiosk stop`, desktop mode, still booting/restarting under systemd's own
#     Restart=always): never start or restart anything.
#   * server down / status unreadable / server (unit) up for less than 120 s / the server does not report .ui.clients:
#     never restart (the UI cannot be blamed for that; a rebooting server also drops every websocket).
#   * at most 3 restarts per rolling hour; after that it only logs.
#
# State lives in /run/peri-ui-watchdog (tmpfs, gone after a reboot): fails (counter), restarts (epoch per line), last.
# The env file is parsed with grep (never sourced). Everything below can be overridden through PERI_WD_* variables, which
# exists for tests: PERI_ENV_FILE PERI_WD_STATE_DIR PERI_WD_SYSTEMCTL PERI_WD_UPTIME_FILE PERI_WD_NOW PERI_WD_MIN_UP_S
# PERI_WD_FAILS PERI_WD_MAX_RESTARTS PERI_WD_URL.
set -Eeuo pipefail
export LC_ALL=C

ENV_FILE="${PERI_ENV_FILE:-/etc/peri/peri.env}"
STATE_DIR="${PERI_WD_STATE_DIR:-/run/peri-ui-watchdog}"
SYSTEMCTL="${PERI_WD_SYSTEMCTL:-systemctl}"
UPTIME_FILE="${PERI_WD_UPTIME_FILE:-/proc/uptime}"
MIN_UP_S="${PERI_WD_MIN_UP_S:-120}"
FAILS_NEEDED="${PERI_WD_FAILS:-3}"
MAX_RESTARTS="${PERI_WD_MAX_RESTARTS:-3}"
WINDOW_S=3600

log() { printf '%s\n' "$*"; }
# log_once STATE MESSAGE : log only when the state changed since the last pass (a pass every 30 s would flood the journal).
log_once() {
    local last=""
    [[ -f "$STATE_DIR/last" ]] && last=$(cat "$STATE_DIR/last" 2>/dev/null || true)
    if [[ "$last" != "$1" ]]; then
        log "$2"
        printf '%s' "$1" > "$STATE_DIR/last"
    fi
}

# env_get KEY : last active KEY=value of the env file, whitespace and one pair of quotes stripped; empty when unset.
env_get() {
    local key="$1" line val
    [[ -r "$ENV_FILE" ]] || return 0
    line=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1) || true
    [[ -n "$line" ]] || return 0
    val=${line#*=}
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    case "$val" in \"*\") val=${val#\"}; val=${val%\"} ;; \'*\') val=${val#\'}; val=${val%\'} ;; esac
    printf '%s' "$val"
}

http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 3 "$1"
    else
        python3 -c 'import sys, urllib.request as u; sys.stdout.write(u.urlopen(sys.argv[1], timeout=3).read().decode())' "$1"
    fi
}

# server_uptime_s : seconds since peri-server.service became active (systemd monotonic clock vs /proc/uptime).
server_uptime_s() {
    local enter up
    enter=$("$SYSTEMCTL" show -p ActiveEnterTimestampMonotonic --value peri-server.service 2>/dev/null) || return 1
    [[ "$enter" =~ ^[0-9]+$ && "$enter" -gt 0 ]] || return 1
    read -r up _ < "$UPTIME_FILE" || return 1
    awk -v u="$up" -v e="$enter" 'BEGIN { s = u - e / 1000000; if (s < 0) s = 0; printf "%d", s }'
}

reset_counter() { printf '0' > "$STATE_DIR/fails"; }

main() {
    mkdir -p "$STATE_DIR"
    local now="${PERI_WD_NOW:-$(date +%s)}"

    local enabled; enabled=$(env_get PERI_UI_WATCHDOG | tr '[:upper:]' '[:lower:]')
    case "$enabled" in
        0|false|no|off) reset_counter; log_once disabled "watchdog disabled (PERI_UI_WATCHDOG=$enabled in $ENV_FILE)"; return 0 ;;
    esac

    if ! "$SYSTEMCTL" is-active --quiet peri-kiosk.service; then
        reset_counter; log_once kiosk-inactive "peri-kiosk is not active: nothing to watch (it is never started by this watchdog)"; return 0
    fi

    local port; port=$(env_get PERI_PORT); port=${port:-8420}
    [[ "$port" =~ ^[0-9]+$ ]] || port=8420
    local base="${PERI_WD_URL:-http://127.0.0.1:$port}" json
    if ! json=$(http_get "$base/api/system/status" 2>/dev/null); then
        reset_counter; log_once server-down "server not reachable at $base: not acting (the UI cannot be blamed)"; return 0
    fi

    local clients sys_up
    read -r clients sys_up < <(printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    c = (d.get("ui") or {}).get("clients")
    u = d.get("uptime_s")
    print(int(c) if c is not None else -1, int(u) if u is not None else -1)
except Exception:
    print(-1, -1)
' 2>/dev/null || echo "-1 -1")
    if [[ "${clients:--1}" -lt 0 ]]; then
        reset_counter; log_once no-ui-info "status has no ui.clients (unreadable or older server): not acting"; return 0
    fi

    local up
    if ! up=$(server_uptime_s); then up=${sys_up:--1}; fi      # fallback: system uptime reported by the API
    if [[ "$up" -lt 0 ]]; then
        reset_counter; log_once no-uptime "cannot determine how long the server has been up: not acting"; return 0
    fi
    if [[ "$up" -lt "$MIN_UP_S" ]]; then
        reset_counter; log_once young "server up for ${up}s (< ${MIN_UP_S}s): giving the UI time to connect"; return 0
    fi

    if [[ "$clients" -gt 0 ]]; then
        local prev=0; [[ -f "$STATE_DIR/fails" ]] && prev=$(cat "$STATE_DIR/fails" 2>/dev/null || echo 0)
        [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
        [[ "$prev" -gt 0 ]] && log "UI connected again ($clients client(s)) after $prev missed pass(es)"
        reset_counter; log_once ok "UI connected ($clients client(s)): all good"; return 0
    fi

    local fails=0; [[ -f "$STATE_DIR/fails" ]] && fails=$(cat "$STATE_DIR/fails" 2>/dev/null || echo 0)
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
    fails=$((fails + 1))
    printf '%s' "$fails" > "$STATE_DIR/fails"
    log "no UI connected to the server (server up ${up}s): pass $fails/$FAILS_NEEDED"
    printf 'missing-%s' "$fails" > "$STATE_DIR/last"
    [[ "$fails" -ge "$FAILS_NEEDED" ]] || return 0

    # Restart budget: MAX_RESTARTS per rolling hour.
    local recent=0 ts kept=""
    if [[ -f "$STATE_DIR/restarts" ]]; then
        while read -r ts; do
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            if [[ $((now - ts)) -lt "$WINDOW_S" ]]; then kept+="$ts"$'\n'; recent=$((recent + 1)); fi
        done < "$STATE_DIR/restarts"
    fi
    printf '%s' "$kept" > "$STATE_DIR/restarts"
    if [[ "$recent" -ge "$MAX_RESTARTS" ]]; then
        log_once budget "UI still missing but $recent kiosk restart(s) already happened within the last hour: NOT restarting again (check: journalctl -u peri-kiosk -n 50)"
        return 0
    fi

    log "restarting peri-kiosk (restart $((recent + 1))/$MAX_RESTARTS this hour)"
    if "$SYSTEMCTL" restart peri-kiosk.service; then
        printf '%s\n' "$now" >> "$STATE_DIR/restarts"
        reset_counter
        printf 'restarted' > "$STATE_DIR/last"
    else
        log "ERROR: systemctl restart peri-kiosk failed"
        return 1
    fi
}

main "$@"
