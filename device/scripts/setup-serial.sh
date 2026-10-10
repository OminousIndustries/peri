#!/usr/bin/env bash
# setup-serial.sh - installer step "serial": make USB-serial adapters usable for the head (Arduino Nano) controller.
#
#   sudo scripts/setup-serial.sh         (normally run by install.sh; safe to re-run)
#   DRY_RUN=1 scripts/setup-serial.sh    (shows the udev rule and what it would run, changes nothing)
#
# 1. udev rule /etc/udev/rules.d/60-peri-head.rules for the usual Nano adapters (CH340/CH341, CH9102, FTDI, CP210x, Arduino):
#    group dialout, mode 0660, symlink /dev/peri-head, and ID_MM_DEVICE_IGNORE so ModemManager does not probe the port
#    (a probed port is opened, and the Nano resets on every open). The package ModemManager itself is left alone.
# 2. brltty (braille display daemon) claims CH340/CP210x/FTDI adapters and makes the tty vanish: it is PURGED when installed
#    (only if apt would remove nothing else; otherwise its udev rule is overridden and its units are masked). Documented behaviour.
# 3. user peri must be in group dialout (install-app normally did that).
# 4. informational: which serial devices exist right now (the Nano may simply not be plugged in yet: never a failure) and a
#    note when the Pi's own UART console (console=serial0) is enabled on the kernel command line (left alone).
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=detect.sh
. "$HERE/detect.sh"
PERI_STEP="${PERI_STEP:-serial}"
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"      # sbin tools are not in the PATH of a plain `su`

RULES_FILE=/etc/udev/rules.d/60-peri-head.rules
BRLTTY_RULES=/etc/udev/rules.d/85-brltty.rules
PERI_USER=peri

usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# One rule per adapter family. A device that matches is: tty, owned by group dialout, 0660, ignored by ModemManager, and
# reachable as /dev/peri-head. (ATTRS{} walks up to the USB device, so ttyUSB* and ttyACM* both match.)
render_rules() {
    cat <<'EOF'
# Managed by the Peri installer (scripts/setup-serial.sh). Uninstall: sudo /opt/peri/uninstall.sh
# USB-serial adapters commonly found on an Arduino Nano head controller. ID_MM_* keeps ModemManager from probing the port
# (it would open it, which resets the Nano); /dev/peri-head is a stable name the server also scans.
# CH340/CH341 (most Nano clones)
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", SYMLINK+="peri-head"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7522", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", SYMLINK+="peri-head"
# CH9102 (newer Nano clones, shows up as ttyACM)
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d4", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", SYMLINK+="peri-head"
# FTDI FT232R (genuine Nano)
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", SYMLINK+="peri-head"
# Silicon Labs CP210x
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", SYMLINK+="peri-head"
# Arduino SA / Arduino.org boards (Uno-type CDC ACM: 2341:0043, 2341:0001, 2341:0010, 2a03:*)
SUBSYSTEM=="tty", ATTRS{idVendor}=="2341", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", SYMLINK+="peri-head"
SUBSYSTEM=="tty", ATTRS{idVendor}=="2a03", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", SYMLINK+="peri-head"
EOF
}

reload_udev() {
    if ! have udevadm && ! is_fakeroot; then warn "udevadm not found: the udev rule takes effect at the next boot"; return 0; fi
    sysrun_soft udevadm control --reload-rules
    sysrun_soft udevadm trigger --subsystem-match=tty
}

# brltty_purge_is_safe : would `apt-get purge brltty` remove nothing but brltty itself? (simulation, no changes)
brltty_purge_is_safe() {
    is_fakeroot && return 0
    have apt-get || return 1
    local removed extra
    removed=$(apt-get -s purge brltty 2>/dev/null | awk '/^Remv /{print $2}') || return 1
    extra=$(printf '%s\n' "$removed" | grep -v -E '^(brltty|brltty-.*)$' || true)
    if [[ -n "$extra" ]]; then
        warn "purging brltty would also remove: $(printf '%s' "$extra" | tr '\n' ' ')"
        return 1
    fi
    return 0
}

BRLTTY_CHANGED=0
handle_brltty() {
    if ! pkg_installed brltty; then skip "brltty is not installed: nothing to remove"; return 0; fi
    info "brltty is installed: it grabs CH340/CP210x/FTDI USB-serial adapters (the tty disappears when the Nano is plugged in)"
    if brltty_purge_is_safe; then
        info "purging brltty (only brltty itself is removed; reinstall later with: sudo apt-get install brltty)"
        if sysrun env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 purge -y brltty; then
            manifest_add pkg-removed brltty
            BRLTTY_CHANGED=1
            mutating_ok && _note_change "purged package brltty"
            return 0
        fi
        warn "purging brltty failed: falling back to disabling it"
    else
        warn "not purging brltty (it would take other packages with it): disabling its udev rule and units instead"
    fi
    # Fallback: a file of the same name in /etc/udev/rules.d overrides the packaged /lib/udev/rules.d/85-brltty.rules.
    write_file "$BRLTTY_RULES" 0644 root:root < <(printf '%s\n' \
        '# Managed by the Peri installer: overrides the packaged 85-brltty.rules so brltty cannot claim USB-serial adapters.')
    [[ "$LAST_CHANGED" == 1 ]] && BRLTTY_CHANGED=1
    if mutating_ok && [[ "$(systemctl is-enabled brltty-udev.service 2>/dev/null || true)" == masked ]]; then
        skip "brltty-udev.service is already masked"
    elif sysrun systemctl mask brltty-udev.service brltty.service; then
        manifest_add svc-masked brltty-udev.service; manifest_add svc-masked brltty.service
        mutating_ok && _note_change "masked brltty units"
    fi
    return 0
}

ensure_dialout() {
    if ! group_exists dialout; then warn "group dialout does not exist on this system: USB-serial access relies on the udev rule's GROUP only"; return 0; fi
    if ! user_exists "$PERI_USER"; then
        if mutating_ok; then warn "user $PERI_USER does not exist yet: run the app step first (it creates the user and adds it to dialout)"
        else skip "user $PERI_USER does not exist here (dry run / fake root / app step not run yet): it joins dialout when the app step creates it"; fi
        return 0
    fi
    if is_fakeroot; then sysrun usermod -aG dialout "$PERI_USER"; return 0; fi     # cannot inspect memberships in a fake root
    if id -nG "$PERI_USER" | tr ' ' '\n' | grep -x dialout >/dev/null; then
        skip "$PERI_USER is already in group dialout"
    else
        info "adding $PERI_USER to group dialout"
        sysrun usermod -aG dialout "$PERI_USER" && mutating_ok && _note_change "usermod -aG dialout $PERI_USER"
    fi
    return 0
}

report_devices() {
    local dev found=0 list=()
    local devdir; devdir=$(rp /dev)
    for dev in "$devdir"/ttyUSB* "$devdir"/ttyACM* "$devdir"/serial/by-id/* "$devdir"/peri-head; do
        [[ -e "$dev" || -L "$dev" ]] || continue
        found=1; list+=("${dev#"$PERI_ROOT"}")
    done
    if [[ $found -eq 1 ]]; then
        info "serial devices present right now: ${list[*]}"
    else
        info "no USB-serial device (ttyUSB*/ttyACM*) is present right now. That is fine: plug the Arduino Nano head controller in whenever you like; the udev rule applies automatically and the server scans for it."
    fi
    detect_boot
    local cmd; cmd=$(rp "$CMDLINE_TXT")
    if [[ -r "$cmd" ]] && grep -Eq '(^| )console=(serial0|ttyAMA0|ttyS0)' "$cmd"; then
        info "note: the kernel command line has a serial console (console=serial0): it uses the Pi's own UART pins (GPIO14/15), not USB adapters. Left as it is; it only matters if the head is wired to those pins."
    fi
}

main() {
    case "${1:-}" in -h|--help) usage; return 0 ;; esac
    require_root
    write_file "$RULES_FILE" 0644 root:root < <(render_rules)
    local rules_changed="$LAST_CHANGED"
    handle_brltty
    if [[ "$rules_changed" == 1 || "$BRLTTY_CHANGED" == 1 ]]; then reload_udev; else skip "udev rules unchanged: no reload needed"; fi
    ensure_dialout
    report_devices
    info "ModemManager (if present) is told to ignore these adapters by the udev rule; the package is not removed"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi     # sourced (by tests) it only defines functions
