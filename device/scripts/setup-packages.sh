#!/usr/bin/env bash
# setup-packages.sh - installer step "packages": the GENERIC runtime dependencies of the Peri server and of the installer.
#
#   sudo scripts/setup-packages.sh          (normally run by install.sh; safe to run alone and to re-run)
#   DRY_RUN=1 scripts/setup-packages.sh     (shows what would be installed, changes nothing)
#
# Installs only what the server/scripts need on every target (Bullseye, Bookworm, Trixie; Lite or Desktop):
#   critical  : python3 python3-aiohttp python3-serial curl ca-certificates rsync sudo alsa-utils
#   secondary : python3-gpiozero + a GPIO backend (python3-lgpio, or python3-rpi.gpio where lgpio does not exist, i.e.
#               Bullseye), i2c-tools, libasound2-plugins (ALSA dmix/rate conversion), usbutils, brightnessctl (if available)
# Kiosk (chromium, cage/X11 ...), audio-server (PipeWire) and boot (plymouth) packages belong to their own steps.
# Never runs `apt-get upgrade`/`dist-upgrade` and never touches the kernel or the firmware.
# Fails (exit 1) when python3 is older than 3.9 or python3-aiohttp is not importable afterwards: the server cannot run then.
#
# Bullseye after its end of life: when apt cannot fetch the Debian bullseye repositories (they move to archive.debian.org)
# and the archive answers, the Debian entries of /etc/apt/sources.list(.d) are pointed at archive.debian.org (with a
# .peri-bak backup; `bullseye-updates` is disabled, it is not archived) and Acquire::Check-Valid-Until is turned off.
# The Raspberry Pi repository (archive.raspberrypi.org) is not touched. Disable with PERI_NO_APT_EOL_FIX=1.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=detect.sh
. "$HERE/detect.sh"
PERI_STEP="${PERI_STEP:-packages}"
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"      # sbin tools are not in the PATH of a plain `su`

TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}"; return 0; }
trap cleanup EXIT

CRITICAL_PKGS=(python3 python3-aiohttp python3-serial curl ca-certificates rsync sudo alsa-utils)
SECONDARY_PKGS=(python3-gpiozero i2c-tools libasound2-plugins usbutils)
OPTIONAL_PKGS=(brightnessctl)          # nice to have: skipped silently (with a log line) when apt does not know it

usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# _apt_hints LOG_BYTES_BEFORE : after a failed apt/dpkg call, look at what apt printed (it went to the log file) and say what
# usually fixes it. Purely advisory.
_apt_hints() {
    local since="$1" text
    [[ -n "${PERI_LOG_FILE:-}" && -r "$PERI_LOG_FILE" ]] || return 0
    text=$(tail -c +"$((since + 1))" "$PERI_LOG_FILE" 2>/dev/null || true)
    [[ "$text" == *"is not valid yet"* ]] && warn "hint: the system clock is wrong (apt says a Release file is not valid yet). Enable time sync and retry: sudo timedatectl set-ntp true ; wait for 'System clock synchronized: yes' in timedatectl"
    [[ "$text" == *"Temporary failure resolving"* || "$text" == *"Could not resolve"* || "$text" == *"Network is unreachable"* ]] \
        && warn "hint: no network/DNS. Check: ping -c1 deb.debian.org ; nmcli device status ; cat /etc/resolv.conf"
    [[ "$text" == *"does not have a Release file"* || ( "$text" == *"404  Not Found"* && "${OS_CODENAME:-}" == bullseye ) ]] \
        && warn "hint: the package repositories of ${OS_CODENAME:-this release} no longer answer (an end-of-life release moves to archive.debian.org). Recommended: re-flash Raspberry Pi OS Bookworm or Trixie; otherwise point /etc/apt/sources.list at archive.debian.org and re-run."
    [[ "$text" == *"Could not get lock"* || "$text" == *"Unable to acquire the dpkg frontend lock"* ]] \
        && warn "hint: another package manager is running (first boot updates, unattended-upgrades). Wait a few minutes, or: sudo systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service ; then re-run."
    [[ "$text" == *"dpkg was interrupted"* ]] && warn "hint: an earlier dpkg run was interrupted: sudo dpkg --configure -a"
    [[ "$text" == *"Unable to locate package"* ]] && warn "hint: apt does not know one of the packages (stale index?): sudo apt-get update"
    [[ "$text" == *"Hash Sum mismatch"* ]] && warn "hint: the mirror served inconsistent files; retry in a few minutes: sudo apt-get update"
    return 0
}

_log_size() { stat -c %s "${PERI_LOG_FILE:-/nonexistent}" 2>/dev/null || echo 0; }

# fix_interrupted_dpkg : a previous installer run killed mid-apt (SSH dropped, agent timeout) leaves dpkg half-configured,
# and every later apt call then fails. `dpkg --audit` prints problems only.
fix_interrupted_dpkg() {
    mutating_ok || return 0
    have dpkg || return 0
    if [[ -n "$(dpkg --audit 2>/dev/null || true)" ]]; then
        warn "dpkg reports half-installed/half-configured packages (an earlier install was interrupted?): running dpkg --configure -a"
        sysrun_soft env DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold
    fi
}

# eol_rewrite_sources : stdin -> stdout. Active Debian bullseye lines get archive.debian.org as host; bullseye-updates (not
# archived) is commented out. Idempotent: an already rewritten file comes out unchanged.
eol_rewrite_sources() {
    awk '
    /^[[:space:]]*deb(-src)?[[:space:]]/ && /bullseye/ {
        line = $0
        if (line ~ /bullseye-updates/) { print "#peri-disabled: " line; next }
        gsub(/(https?|ftp):\/\/(deb|httpredir|ftp[a-z0-9.-]*)\.debian\.org\/debian-security\/?/, "http://archive.debian.org/debian-security/", line)
        gsub(/(https?|ftp):\/\/security\.debian\.org(\/debian-security)?\/?/, "http://archive.debian.org/debian-security/", line)
        gsub(/(https?|ftp):\/\/(deb|httpredir|ftp[a-z0-9.-]*)\.debian\.org\/debian\/?/, "http://archive.debian.org/debian/", line)
        print line; next
    }
    { print }'
}

# archive_reachable : does archive.debian.org serve the bullseye Release file?
archive_reachable() {
    local url=https://archive.debian.org/debian/dists/bullseye/Release
    if have curl; then curl -fsS -m 15 -o /dev/null -I "$url" 2>/dev/null
    elif have wget; then wget -q -T 15 --spider "$url" 2>/dev/null
    else python3 -c 'import sys, urllib.request as u; u.urlopen(u.Request(sys.argv[1], method="HEAD"), timeout=15)' "$url" 2>/dev/null; fi
}

# eol_repair_needed LOG_BYTES_BEFORE : bullseye + apt says the repositories are gone + the archive has them.
eol_repair_needed() {
    [[ "${OS_CODENAME:-}" == bullseye && "${PERI_NO_APT_EOL_FIX:-0}" != 1 ]] || return 1
    [[ "${PERI_FORCE_APT_EOL:-0}" == 1 ]] && return 0                      # test hook
    local text; text=$(tail -c +"$(($1 + 1))" "${PERI_LOG_FILE:-/nonexistent}" 2>/dev/null || true)
    [[ "$text" == *"does not have a Release file"* || ( "$text" == *"404  Not Found"* && "$text" == *"debian"* ) ]] || return 1
    archive_reachable
}

eol_repair() {
    warn "Debian bullseye has reached its end of life and apt cannot fetch its repositories: pointing the Debian entries at archive.debian.org (backups: FILE.peri-bak)"
    local f g tmp
    local -a files=(/etc/apt/sources.list)
    for g in "$(rp /etc/apt/sources.list.d)"/*.list; do [[ -f "$g" ]] && files+=("${g#"$PERI_ROOT"}"); done
    for f in "${files[@]}"; do
        [[ -f "$(rp "$f")" ]] || continue
        tmp=$(mktemp); TMP_FILES+=("$tmp")
        eol_rewrite_sources < "$(rp "$f")" > "$tmp"
        if cmp -s "$tmp" "$(rp "$f")"; then skip "$f needs no change"; else write_file "$f" < "$tmp"; fi
    done
    write_file /etc/apt/apt.conf.d/99peri-archive 0644 root:root <<'CONF'
// Managed by the Peri installer: the Release files on archive.debian.org are old and would be rejected as expired.
Acquire::Check-Valid-Until "false";
CONF
    rm -f "${PERI_STATE_INSTALL_DIR}/apt-updated"
}

main() {
    case "${1:-}" in -h|--help) usage; return 0 ;; esac
    require_root
    detect_os; detect_hw; detect_python
    info "OS: ${OS_PRETTY:-unknown}, ${BITS}-bit userland, python3: ${PY_VERSION:-not installed}"
    [[ "$OS_SUPPORTED" == 1 ]] || warn "OS release '${OS_CODENAME:-unknown}' is not one of bullseye/bookworm/trixie: package names may differ"

    # Which packages are missing at all? Only then is a (network-heavy) `apt-get update` worth it.
    local p missing_critical=() missing_secondary=() missing_optional=() all_missing=()
    for p in "${CRITICAL_PKGS[@]}";  do pkg_installed "$p" || missing_critical+=("$p"); done
    for p in "${SECONDARY_PKGS[@]}"; do pkg_installed "$p" || missing_secondary+=("$p"); done
    for p in "${OPTIONAL_PKGS[@]}";  do pkg_installed "$p" || missing_optional+=("$p"); done
    # GPIO backend for gpiozero: decided below (needs the package index for python3-lgpio).
    local gpio_installed=0
    if pkg_installed python3-lgpio || pkg_installed python3-rpi.gpio || pkg_installed python3-rpi-lgpio; then gpio_installed=1; fi
    all_missing=("${missing_critical[@]}" "${missing_secondary[@]}" "${missing_optional[@]}")

    if [[ ${#all_missing[@]} -eq 0 && $gpio_installed -eq 1 ]]; then
        skip "all runtime packages are already installed (no apt-get update needed): ${CRITICAL_PKGS[*]} ${SECONDARY_PKGS[*]}"
    else
        fix_interrupted_dpkg
        local before; before=$(_log_size)
        apt_update_once
        _apt_hints "$before"
        if eol_repair_needed "$before"; then
            eol_repair
            before=$(_log_size)
            apt_update_once
            _apt_hints "$before"
        fi

        # Filter by what apt can actually install (after the update): one unknown name would abort the whole apt call.
        local avail_critical=() avail_secondary=() unavailable=()
        for p in "${missing_critical[@]}"; do
            if pkg_available "$p"; then avail_critical+=("$p"); else unavailable+=("$p"); fi
        done
        for p in "${missing_secondary[@]}"; do
            if pkg_available "$p"; then avail_secondary+=("$p"); else warn "package $p is not available from apt on this system: skipping it"; fi
        done
        for p in "${missing_optional[@]}"; do
            if pkg_available "$p"; then avail_secondary+=("$p"); else skip "optional package $p is not available from apt on ${OS_CODENAME:-this OS}"; fi
        done
        if [[ $gpio_installed -eq 0 ]]; then
            if pkg_available python3-lgpio; then avail_secondary+=(python3-lgpio); info "GPIO backend: python3-lgpio"
            elif pkg_available python3-rpi.gpio; then avail_secondary+=(python3-rpi.gpio); info "GPIO backend: python3-rpi.gpio (python3-lgpio does not exist on ${OS_CODENAME:-this OS})"
            else warn "no GPIO backend package (python3-lgpio / python3-rpi.gpio) available: a direct-GPIO head driver will not work (the default USB-serial head does not need it)"; fi
        else
            skip "a GPIO backend for gpiozero is already installed"
        fi
        if [[ ${#unavailable[@]} -gt 0 ]]; then
            if is_fakeroot; then
                warn "required package(s) not in the fake root's availability list (a real system would fail here): ${unavailable[*]}"
            else
                err "required package(s) not available from apt: ${unavailable[*]}"
                die "cannot continue without: ${unavailable[*]} (is this a supported Debian/Raspberry Pi OS release with working apt sources? try: sudo apt-get update)"
            fi
        fi

        local rc=0
        if [[ ${#avail_critical[@]} -gt 0 ]]; then
            before=$(_log_size)
            apt_install "${avail_critical[@]}" || rc=$?
            if [[ $rc -ne 0 ]]; then
                _apt_hints "$before"
                die "installing the required packages failed (${avail_critical[*]}); apt output is above and in ${PERI_LOG_FILE:-the log}"
            fi
        fi
        if [[ ${#avail_secondary[@]} -gt 0 ]]; then
            before=$(_log_size)
            if ! apt_install "${avail_secondary[@]}"; then
                _apt_hints "$before"
                warn "installing the secondary packages failed (${avail_secondary[*]}); continuing: only optional features are affected"
            fi
        fi
    fi

    # ---- verification (only meaningful on the real system) ----
    if ! mutating_ok; then
        skip "verification skipped: nothing is installed in dry-run/fake-root mode"
        return 0
    fi
    detect_python
    if [[ "$PY_OK" != 1 ]]; then
        die "python3 >= 3.9 is required by the Peri server, found: ${PY_VERSION:-no python3}. Use Raspberry Pi OS Bullseye or newer (Bullseye ships 3.9)."
    fi
    if [[ "$PY_HAS_AIOHTTP" != 1 ]]; then
        die "python3-aiohttp is not importable (python3 ${PY_VERSION}). The server cannot run without it: sudo apt-get install python3-aiohttp ; check: python3 -c 'import aiohttp'"
    fi
    ok "python3 $PY_VERSION with aiohttp $(python3 -c 'import aiohttp; print(aiohttp.__version__)' 2>/dev/null || echo '?')"
    [[ "$PY_HAS_SERIAL" == 1 ]]   || warn "python3-serial (pyserial) is not importable: the USB-serial head driver will not work"
    [[ "$PY_HAS_GPIOZERO" == 1 ]] || warn "python3-gpiozero is not importable: the direct-GPIO head driver will not work (serial/sim heads are fine)"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi     # sourced (by tests) it only defines functions
