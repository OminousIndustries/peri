#!/usr/bin/env bash
# setup-services.sh - installer step "services": systemd units, the sudoers drop-in, enabling and (re)starting.
#
#   sudo scripts/setup-services.sh        (normally run by install.sh; safe to re-run: this is also the UPDATE step)
#   DRY_RUN=1 scripts/setup-services.sh   (shows the rendered units/sudoers diffs and the commands, changes nothing)
#
# 1. Renders EVERY systemd/*.service and systemd/*.timer of the source tree (peri-server, peri-ui-watchdog, and whatever
#    the kiosk/hardware steps ship: peri-kiosk, peri-hwinit) into /etc/systemd/system, replacing the placeholders
#    @PERI_UID@ @PERI_USER@ @PERI_HOME@ @PERI_STATE@ @PERI_INSTALL@ and @PERI_GROUPS@ (the supplementary groups of the
#    server that exist on this OS). An unknown/unresolved placeholder fails the step.
# 2. /etc/sudoers.d/peri-power (0440): user peri may run, without password and nothing else, `systemctl reboot|poweroff|
#    restart peri-kiosk|restart peri-server` (both /usr/bin and /bin paths). The file is validated with `visudo -cf` BEFORE
#    it is installed and the whole configuration is re-checked afterwards: a broken sudoers file locks everybody out.
# 3. daemon-reload; enables peri-hwinit, peri-server, peri-kiosk (only when the kiosk is part of this install or was set up
#    before) and peri-ui-watchdog.timer; skips units whose file does not exist (with a log line saying so).
# 4. Starts what should run now: peri-hwinit (unless a reboot is pending), restarts peri-server and waits up to 20 s for
#    /healthz (failure = step failure with the journal excerpt), starts the watchdog timer, starts peri-kiosk when
#    PERI_OPT_START_KIOSK allows it: auto = only when no reboot is pending and no desktop session owns the display,
#    1 = also with a pending reboot, 0 = never. Nothing is started in dry-run/fake-root mode.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=detect.sh
. "$HERE/detect.sh"
PERI_STEP="${PERI_STEP:-services}"
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"      # sbin tools are not in the PATH of a plain `su`

PERI_USER=peri
PERI_HOME=/var/lib/peri
PERI_STATE=/var/lib/peri
PERI_INSTALL=/opt/peri
UNIT_DIR=/etc/systemd/system
SUDOERS_FILE=/etc/sudoers.d/peri-power
ENV_FILE=/etc/peri/peri.env
ENABLE_UNITS=(peri-hwinit.service peri-server.service peri-kiosk.service peri-ui-watchdog.timer)
SUPP_GROUPS_WANTED=(audio video dialout gpio input render)
KNOWN_PLACEHOLDERS=" PERI_UID PERI_USER PERI_HOME PERI_STATE PERI_INSTALL PERI_GROUPS "
HEALTH_WAIT_S="${PERI_HEALTH_WAIT_S:-20}"

TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}"; return 0; }
trap cleanup EXIT

RC=0
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# ------------------------------------------------------------------------------------------------ helpers

peri_uid() {
    if ! is_fakeroot && user_exists "$PERI_USER"; then id -u "$PERI_USER"; else printf '%s' "${PERI_FAKE_UID:-1001}"; fi
}

supplementary_groups() {
    local g out=()
    for g in "${SUPP_GROUPS_WANTED[@]}"; do
        if group_exists "$g"; then out+=("$g"); else debug "group $g does not exist here: left out of SupplementaryGroups"; fi
    done
    printf '%s' "${out[*]:-}"
}

# env_get KEY : last active KEY=value of the (target) env file; empty when unset. Never sourced.
env_get() {
    local f line val; f=$(rp "$ENV_FILE")
    [[ -r "$f" ]] || return 0
    line=$(grep -E "^[[:space:]]*$1=" "$f" | tail -n1) || true
    [[ -n "$line" ]] || return 0
    val=${line#*=}
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    case "$val" in \"*\") val=${val#\"}; val=${val%\"} ;; \'*\') val=${val#\'}; val=${val%\'} ;; esac
    printf '%s' "$val"
}

reboot_pending() { [[ -s "$PERI_REBOOT_FLAG" ]]; }

http_get() {
    if have curl; then curl -fsS -m 3 "$1"
    else python3 -c 'import sys, urllib.request as u; sys.stdout.write(u.urlopen(sys.argv[1], timeout=3).read().decode())' "$1"; fi
}

wait_healthz() {  # PORT SECONDS
    local i
    for ((i = 0; i < $2; i++)); do
        if http_get "http://127.0.0.1:$1/healthz" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------------------------- units

render_units() {
    local uid groups f name ph unknown units_changed=0
    uid=$(peri_uid); groups=$(supplementary_groups)
    if ! is_fakeroot && ! user_exists "$PERI_USER"; then
        if mutating_ok; then die "user $PERI_USER does not exist: run the app step first (sudo ./install.sh --yes --only app,services)"; fi
        info "user $PERI_USER does not exist yet (dry run): rendering with the placeholder uid $uid"
    fi
    info "rendering units with user=$PERI_USER uid=$uid home=$PERI_HOME install=$PERI_INSTALL groups='${groups}'"
    local found=0
    for f in "$PERI_SRC"/systemd/*.service "$PERI_SRC"/systemd/*.timer; do
        [[ -f "$f" ]] || continue
        found=1; name=$(basename "$f")
        unknown=""
        for ph in $(grep -o '@[A-Z_]\+@' "$f" | sort -u | tr -d '@'); do
            [[ "$KNOWN_PLACEHOLDERS" == *" $ph "* ]] || unknown+=" @$ph@"
        done
        if [[ -n "$unknown" ]]; then err "unit template $name uses unknown placeholder(s):$unknown (known:${KNOWN_PLACEHOLDERS})"; RC=1; continue; fi
        render_to "$f" "$UNIT_DIR/$name" 0644 root:root \
            "PERI_UID=$uid" "PERI_USER=$PERI_USER" "PERI_HOME=$PERI_HOME" "PERI_STATE=$PERI_STATE" \
            "PERI_INSTALL=$PERI_INSTALL" "PERI_GROUPS=$groups"
        if [[ "$LAST_CHANGED" == 1 ]]; then
            units_changed=1
            [[ "$name" == peri-kiosk.service ]] && KIOSK_UNIT_CHANGED=1
        fi
    done
    if [[ $found -eq 0 ]]; then err "no unit templates found in $PERI_SRC/systemd"; RC=1; fi
    if [[ ! -f "$PERI_SRC/systemd/peri-server.service" ]]; then err "systemd/peri-server.service is missing from the source tree"; RC=1; fi
    UNITS_CHANGED=$units_changed
}
UNITS_CHANGED=0
KIOSK_UNIT_CHANGED=0

# kiosk_needs_restart : a running kiosk only needs a restart (instead of a UI reload) when its unit or its launcher scripts
# changed in this run; changed web files are picked up by reloading the page.
kiosk_needs_restart() {
    [[ "$KIOSK_UNIT_CHANGED" == 1 ]] && return 0
    grep -q '^write.app files: scripts/' "$PERI_CHANGE_LOG" 2>/dev/null
}

# verify_units : `systemd-analyze verify` on the installed units; only syntax problems are reported (missing users/executables
# on a half-installed system are not interesting).
verify_units() {
    mutating_ok || return 0
    have systemd-analyze || return 0
    local f out
    for f in "$(rp "$UNIT_DIR")"/peri-*.service "$(rp "$UNIT_DIR")"/peri-*.timer; do
        [[ -f "$f" ]] || continue
        out=$(systemd-analyze verify "$f" 2>&1 || true)
        if grep -Eq 'Unknown (key|section|lvalue)|Invalid|Failed to parse|not a valid|Assignment outside' <<<"$out"; then
            warn "systemd-analyze verify reports problems in $(basename "$f"):"
            printf '%s\n' "$out" | sed -n '1,10s/^/        /p' >&2
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------------------------- sudoers

sudoers_content() {
    cat <<EOF
# Managed by the Peri installer (scripts/setup-services.sh) - do not edit; uninstall removes it.
# The Peri server (user $PERI_USER) may reboot/power off the device and restart the UI/server, without a password, and
# nothing else. It calls: sudo -n systemctl <verb> ... (so peri-server.service must not set NoNewPrivileges).
Cmnd_Alias PERI_POWER = /usr/bin/systemctl reboot, /bin/systemctl reboot, \\
    /usr/bin/systemctl poweroff, /bin/systemctl poweroff, \\
    /usr/bin/systemctl restart peri-kiosk, /bin/systemctl restart peri-kiosk, \\
    /usr/bin/systemctl restart peri-server, /bin/systemctl restart peri-server
$PERI_USER ALL=(root) NOPASSWD: PERI_POWER
EOF
}

install_sudoers() {
    local tmp out baseline_ok=1
    tmp=$(mktemp); TMP_FILES+=("$tmp")
    sudoers_content > "$tmp"; chmod 0440 "$tmp"
    if have visudo; then
        if ! out=$(visudo -cf "$tmp" 2>&1); then
            err "the generated sudoers file failed validation and is NOT installed (a broken sudoers file would lock everybody out):"
            printf '%s\n' "$out" | sed 's/^/        /' >&2
            RC=1; return 0
        fi
        debug "visudo: $out"
    elif mutating_ok; then
        warn "visudo not found (sudo is not installed?): NOT installing $SUDOERS_FILE, because it cannot be validated. The UI's reboot/shutdown buttons will not work until 'sudo' is installed and this step re-run."
        return 0
    else
        skip "visudo not available on this machine: sudoers validation skipped (fake root / dry run)"
    fi
    if mutating_ok && have visudo && ! visudo -c >/dev/null 2>&1; then
        baseline_ok=0
        warn "the existing sudoers configuration already has errors (not caused by this installer)"
    fi
    write_file "$SUDOERS_FILE" 0440 root:root < "$tmp"
    if mutating_ok && have visudo && [[ $baseline_ok -eq 1 ]] && ! visudo -c >/dev/null 2>&1; then
        err "visudo -c fails after installing $SUDOERS_FILE: removing that file again"
        rm -f "$(rp "$SUDOERS_FILE")"; RC=1
    fi
    return 0
}

# --------------------------------------------------------------------------------------------- enabling

# kiosk_is_part_of_install : should peri-kiosk.service be enabled? Not when the kiosk step was deliberately left out of a
# fresh install (a unit without its browser/compositor would crash-loop on tty1 at every boot).
kiosk_is_part_of_install() {
    if [[ -z "${PERI_STEPS_RUN:-}" ]]; then return 0; fi                 # run alone: enable what is there
    [[ " $PERI_STEPS_RUN " == *" kiosk "* ]] && return 0                 # the kiosk step is part of this run
    [[ -x "$(rp /usr/local/bin/peri-kiosk)" ]] && return 0               # it was set up by an earlier run
    [[ -n "$(env_get PERI_KIOSK)" ]] && return 0
    if mutating_ok && have systemctl && [[ "$(systemctl is-enabled peri-kiosk.service 2>/dev/null || true)" == enabled ]]; then return 0; fi
    return 1
}

enable_units() {
    local u st
    if mutating_ok && ! have systemctl; then
        err "systemctl not found: cannot enable the Peri units (this installer needs a systemd based system)"; RC=1; return 0
    fi
    for u in "${ENABLE_UNITS[@]}"; do
        if [[ ! -f "$PERI_SRC/systemd/$u" ]]; then
            skip "unit $u is not in $PERI_SRC/systemd (its step has not provided it): not enabling it"; continue
        fi
        if [[ "$u" == peri-kiosk.service ]] && ! kiosk_is_part_of_install; then
            skip "not enabling $u: the kiosk step is not part of this install and no kiosk was set up before (enable later: sudo systemctl enable $u)"; continue
        fi
        service_enable "$u" || { warn "could not enable $u"; RC=1; continue; }
        if mutating_ok; then      # service_enable does not report a failed `systemctl enable`: check the result
            st=$(systemctl is-enabled "$u" 2>/dev/null || true)
            case "$st" in
                enabled|enabled-runtime|static|alias) debug "$u: $st" ;;
                *) err "$u is not enabled after 'systemctl enable' (state: ${st:-unknown}); look at the systemctl output above"; RC=1 ;;
            esac
        fi
    done
}

# reload_units : daemon-reload after unit files changed (skipped when systemd is not running, e.g. in a chroot: not needed there).
reload_units() {
    if [[ "$UNITS_CHANGED" != 1 ]]; then skip "no unit file changed: no daemon-reload needed"; return 0; fi
    if mutating_ok && { ! have systemctl || [[ ! -d "${PERI_SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]; }; then
        skip "systemd is not running here (chroot/container?): daemon-reload skipped, the units are read at the next boot"; return 0
    fi
    daemon_reload || { warn "systemctl daemon-reload failed: newly written units may not be known to systemd yet"; RC=1; }
    return 0
}

# ---------------------------------------------------------------------------------------------- starting

# kiosk_start_decision : prints "start" or "skip:<reason>".
kiosk_start_decision() {
    local opt="${PERI_OPT_START_KIOSK:-auto}"
    if [[ "$opt" == 0 ]]; then echo "skip:--start-kiosk 0"; return; fi
    if [[ ! -f "$PERI_SRC/systemd/peri-kiosk.service" ]]; then echo "skip:peri-kiosk.service does not exist (kiosk step not available)"; return; fi
    if ! kiosk_is_part_of_install; then echo "skip:the kiosk step is not part of this install"; return; fi
    if reboot_pending && [[ "$opt" != 1 ]]; then echo "skip:a reboot is pending, the kiosk starts at boot (force with --start-kiosk 1)"; return; fi
    if mutating_ok && have systemctl && systemctl is-active --quiet display-manager.service >/dev/null 2>&1; then
        echo "skip:a desktop session (display manager) currently owns the display; the kiosk takes over at the next boot"; return
    fi
    echo start
}

start_services() {
    if ! mutating_ok; then skip "not starting anything (dry run / fake root); on a real run the units are started here"; return 0; fi
    if ! have systemctl || [[ ! -d "${PERI_SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]; then
        warn "systemd is not the running init system: units are installed but cannot be started now"; return 0
    fi
    local port; port=$(env_get PERI_PORT); port=${port:-8420}
    [[ "$port" =~ ^[0-9]+$ ]] || port=8420

    if [[ ! -f "$(rp "$PERI_INSTALL/server/peri_server/__main__.py")" ]]; then
        err "$PERI_INSTALL/server/peri_server/__main__.py does not exist: run the app step first"; RC=1; return 0
    fi

    if [[ -f "$UNIT_DIR/peri-hwinit.service" ]]; then
        if reboot_pending; then skip "peri-hwinit not started now: a reboot is pending (it runs at boot)"
        else sysrun_soft systemctl start peri-hwinit.service; fi
    fi

    sysrun_soft systemctl reset-failed peri-server.service
    info "(re)starting peri-server (the server re-centres the neck when it stops)"
    if ! sysrun systemctl restart peri-server.service; then
        err "systemctl restart peri-server failed"; sysrun_soft journalctl -u peri-server -n 30 --no-pager; RC=1; return 0
    fi
    if wait_healthz "$port" "$HEALTH_WAIT_S"; then
        ok "peri-server is up: http://127.0.0.1:$port/healthz answers"
        summarize_status "$port"
    else
        err "peri-server did not answer http://127.0.0.1:$port/healthz within ${HEALTH_WAIT_S}s. Last log lines follow; more: journalctl -u peri-server -n 100 --no-pager"
        sysrun_soft journalctl -u peri-server -n 30 --no-pager
        RC=1
    fi

    [[ -f "$UNIT_DIR/peri-ui-watchdog.timer" ]] && { systemctl is-active --quiet peri-ui-watchdog.timer || sysrun_soft systemctl start peri-ui-watchdog.timer; }

    local decision; decision=$(kiosk_start_decision)
    if [[ "$decision" == start ]]; then
        if systemctl is-active --quiet peri-kiosk.service; then
            if kiosk_needs_restart; then
                info "restarting peri-kiosk: its unit or launcher scripts changed"
                sysrun_soft systemctl restart peri-kiosk.service
            else
                skip "peri-kiosk is already running and unchanged: asking the UI to reload instead of restarting the browser"
                ui_reload "$port"
            fi
        else
            info "starting peri-kiosk"
            sysrun_soft systemctl start peri-kiosk.service
            local i
            for ((i = 0; i < 20; i++)); do systemctl is-active --quiet peri-kiosk.service && break; sleep 1; done
            if systemctl is-active --quiet peri-kiosk.service; then ok "peri-kiosk is active"
            else warn "peri-kiosk is not active after 20 s: journalctl -u peri-kiosk -n 50 --no-pager (a reboot may be needed for the display)"; fi
        fi
    else
        skip "not starting peri-kiosk now: ${decision#skip:}"
        if [[ "$decision" == *"display manager"* ]]; then need_reboot "switch from the running desktop session to the Peri kiosk"; fi
    fi
    return 0
}

# summarize_status PORT : a few facts from /api/system/status in the log (nothing secret in there).
summarize_status() {
    local json line
    json=$(http_get "http://127.0.0.1:$1/api/system/status" 2>/dev/null) || return 0
    line=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
h = d.get("head") or {}
o = d.get("openai") or {}
print("version %s, head driver %s (connected: %s), OpenAI key configured: %s, UI clients: %s" % (
    d.get("version", "?"), h.get("driver", "?"), h.get("connected", "?"), o.get("configured", "?"), (d.get("ui") or {}).get("clients", "?")))
' 2>/dev/null) || return 0
    [[ -n "$line" ]] && info "server status: $line"
    return 0
}

ui_reload() {  # PORT : best effort, loopback only endpoint
    have curl || return 0
    curl -fsS -m 3 -X POST -H 'Content-Type: application/json' -d '{"cmd":"reload"}' "http://127.0.0.1:$1/api/ui/command" >/dev/null 2>&1 || true
}

main() {
    case "${1:-}" in -h|--help) usage; return 0 ;; esac
    require_root
    detect_boot
    render_units
    install_sudoers
    reload_units
    verify_units
    enable_units
    start_services
    if [[ "$RC" -ne 0 ]]; then err "services step finished with errors (see above)"; else ok "services step finished"; fi
    return "$RC"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi     # sourced (by tests) it only defines functions
