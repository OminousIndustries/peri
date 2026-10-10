#!/usr/bin/env bash
# setup-display.sh - installer step "display": make the Waveshare 4inch DSI LCD (C), 720x720 + Goodix touch, work.
#
# Policy (decided from what is actually there, never from the OS name alone; see docs in RESEARCH.md section 1):
#   1. legacy Waveshare driver lines (dtoverlay=WS_xinchDSI_*) in config.txt      -> SKIP (never mix them with the upstream overlay)
#   2. our own managed block "peri:display" already in config.txt                 -> re-render it (options may have changed)
#   3. a DSI connector is already `connected` at 720x720                          -> SKIP (it works; do not rewrite what works)
#   4. the upstream overlay is configured by someone else (image, user)           -> SKIP
#   5. the kernel's vc4-kms-dsi-waveshare-panel overlay knows `4_0_inchC`         -> managed block with the upstream overlay
#   6. otherwise (old Bullseye kernel)                                            -> optional Waveshare bundle install, or refuse
#      with precise instructions (needs internet + git + a bundle directory that matches `uname -r`).
# Always: udev rule so user peri (group video) may set the backlight; `disable_touchscreen=1` is commented out when it
# would disable touch. Panel rotation is NEVER set (the Peri UI rotates itself in CSS). PERI_OPT_DISABLE_HDMI is applied
# by the boot step (the only step that edits cmdline.txt), not here.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: setup-display.sh [-h|--help]        (environment driven; run as root; DRY_RUN=1 shows a diff and changes nothing)

Environment:
  PERI_ROOT              fake-root prefix for tests (empty on a device)
  DRY_RUN=0|1            1 = print what would change, change nothing
  ASSUME_YES=0|1         1 = do not ask before running the vendor driver bundle (Bullseye without upstream support)
  PERI_OPT_DSI_PORT=1    0|1 - DSI connector on Pi 5 / Compute Module (0 adds ",dsi0"); ignored on Pi 3/4 (one connector)
  PERI_OPT_DSI_I2C=0     0|1 - 1 adds ",i2c1": panel wired with the jumper cable on GPIO2/3 instead of the DSI cable's own I2C
  PERI_DISPLAY_BUNDLE=1  0 = never download/run the Waveshare driver bundle (only relevant on old Bullseye kernels)
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=detect.sh
source "$SCRIPT_DIR/detect.sh"
# shellcheck source=data/hw-common.sh
source "$SCRIPT_DIR/data/hw-common.sh"
PERI_STEP=display

BUNDLE_URL="https://github.com/waveshare/Waveshare-DSI-LCD"   # vendor repo, cloned over https (never piped into a shell)
KBITS=64                                                       # the vendor bundle directory is per KERNEL word size (set in main)
UDEV_RULE=/etc/udev/rules.d/90-peri-backlight.rules

display_udev_rule() {
    install_file "$PERI_SRC/scripts/data/90-peri-backlight.rules" "$UDEV_RULE" 0644
    if [[ $LAST_CHANGED -eq 1 ]]; then
        sysrun_soft udevadm control --reload-rules
        sysrun_soft udevadm trigger --subsystem-match=backlight --action=change
    fi
}

# Only a panel that is NOT reporting touch (or one we configure ourselves) is worth touching config.txt for.
display_touch_fix() {
    if cfg_has '^disable_touchscreen=1'; then
        info "config.txt has disable_touchscreen=1 (turns the touch controller off): commenting it out (kept as '#peri-disabled: ...')"
        comment_out_matching "$CONFIG_TXT" '^disable_touchscreen=1'
    fi
}

display_hint() {
    info "after the reboot check the panel with:  dmesg | grep -iE 'waveshare|goodix|dsi|panel' ; grep -i -A4 goodix /proc/bus/input/devices ; cat /sys/class/drm/card*-DSI-*/status"
    info "no touch while the picture works? re-run with PERI_OPT_DSI_I2C=1 (install.sh --dsi-i2c 1) when the panel's DIP switch / jumper cable uses I2C1 (GPIO2/3)"
}

# display_upstream : managed block with the kernel's own overlay. Idempotent; the block decides from what is OUTSIDE it.
display_upstream() {
    local port i2c overlay body before snap
    port=$(hw_opt01 "${PERI_OPT_DSI_PORT:-1}" 1)
    i2c=$(hw_opt01 "${PERI_OPT_DSI_I2C:-0}" 0)
    overlay="vc4-kms-dsi-waveshare-panel,4_0_inchC"
    if [[ "$port" == 0 ]]; then
        if hw_can_choose_dsi_port; then
            overlay+=",dsi0"; info "using DSI0 (PERI_OPT_DSI_PORT=0) on ${PI_MODEL:-this board}"
        else
            info "PERI_OPT_DSI_PORT=0 ignored: ${PI_MODEL:-this Pi} has a single DSI connector (the default one, DSI1)"
        fi
    fi
    if [[ "$i2c" == 1 ]]; then overlay+=",i2c1"; info "using the i2c1 overlay option (panel controlled over GPIO2/3, PERI_OPT_DSI_I2C=1)"; fi

    before=$(hw_changes)
    snap=$(hw_snapshot "$CONFIG_TXT")
    body="[all]"$'\n'"# Waveshare 4inch DSI LCD (C) 720x720 with Goodix touch: the kernel's own overlay, no driver install needed."$'\n'
    # vc4-kms-v3d must be loaded; vc4-fkms-v3d is wrong for this overlay (and refused outright on a Pi 5).
    if cfg_has_outside display '^dtoverlay=vc4-fkms-v3d' && ! cfg_has_outside display '^dtoverlay=vc4-kms-v3d'; then
        info "config.txt uses the legacy vc4-fkms-v3d driver: replacing it by vc4-kms-v3d (old line kept as '#peri-disabled: ...')"
        comment_out_matching "$CONFIG_TXT" '^dtoverlay=vc4-fkms-v3d'
    fi
    if ! cfg_has_outside display '^dtoverlay=vc4-kms-v3d'; then
        body+="dtoverlay=vc4-kms-v3d"$'\n'
        info "dtoverlay=vc4-kms-v3d is not active in config.txt: adding it to the display block (the panel overlay requires it)"
    fi
    body+="dtoverlay=$overlay"
    info "writing the display block: dtoverlay=$overlay"
    set_managed_block "$CONFIG_TXT" display <<< "$body"
    display_touch_fix
    hw_config_guard_end "$snap" "$CONFIG_TXT" '^(dtoverlay=vc4-fkms-v3d|disable_touchscreen=1)' display || return 1
    if [[ $(hw_changes) -gt $before ]]; then
        need_reboot "display overlay (dtoverlay=$overlay) added to $CONFIG_TXT"
    else
        skip "display block in $CONFIG_TXT already up to date"
    fi
}

bundle_refuse() {
    err "Cannot set up the 720x720 DSI panel automatically: $1"
    err "  Kernel $KERNEL on ${OS_PRETTY:-this OS}: the kernel's overlay does not know the Waveshare panel '4_0_inchC'."
    err "  Fix (pick one):"
    err "   1. Re-flash Raspberry Pi OS Bookworm or Trixie (64-bit): the upstream overlay works out of the box (recommended)."
    err "   2. Try a newer kernel:  sudo apt update && sudo apt full-upgrade && sudo reboot   (the Bullseye kernel package may already be at its last version), then re-run this installer."
    err "   3. Install the vendor bundle by hand (kernel-specific; the directory must match 'uname -r' = $KERNEL):"
    err "        git clone $BUNDLE_URL && cd Waveshare-DSI-LCD/${KERNEL%%[-+]*}/$KBITS && sudo bash ./WS_xinchDSI_MAIN.sh 40C I2C0 && sudo reboot"
    err "      then re-run this installer (it will see the WS_xinchDSI_* lines and leave the display alone)."
}

# _display_bundle_run WORKDIR I2C_ARG KVER BITS : the real (mutating) part of the vendor bundle install.
_display_bundle_run() {
    local work="$1" i2c_arg="$2" kver="$3" bits="$4" src rc=0
    if ! sysrun git clone --depth 1 "$BUNDLE_URL" "$work/bundle"; then bundle_refuse "git clone of $BUNDLE_URL failed"; return 1; fi
    src="$work/bundle/$kver/$bits"
    if [[ ! -d "$src" ]]; then
        bundle_refuse "the vendor repo has no directory '$kver/$bits' (available: $(find "$work/bundle" -mindepth 1 -maxdepth 1 -type d -not -name '.git' -printf '%f ' 2>/dev/null))"
        return 1
    fi
    [[ -f "$src/WS_xinchDSI_MAIN.sh" ]] || { bundle_refuse "$kver/$bits does not contain WS_xinchDSI_MAIN.sh"; return 1; }
    backup_file "$CONFIG_TXT"
    info "running the vendor installer: bash ./WS_xinchDSI_MAIN.sh 40C $i2c_arg  (in $kver/$bits)"
    ( cd "$src" && sysrun bash ./WS_xinchDSI_MAIN.sh 40C "$i2c_arg" < /dev/null ) || rc=$?
    if [[ $rc -ne 0 ]] || ! grep -Eq '^dtoverlay=WS_xinchDSI_Screen' "$(rp "$CONFIG_TXT")"; then
        err "the vendor installer did not leave the WS_xinchDSI_Screen overlay in $CONFIG_TXT (exit status $rc)"
        if [[ -e "$(rp "$CONFIG_TXT").peri-bak" ]]; then
            cp -p "$(rp "$CONFIG_TXT").peri-bak" "$(rp "$CONFIG_TXT")" && warn "restored $CONFIG_TXT from $CONFIG_TXT.peri-bak"
        fi
        bundle_refuse "the vendor installer failed"
        return 1
    fi
    _note_change "Waveshare DSI driver bundle ($kver/$bits)"
    ok "Waveshare DSI driver bundle installed"
    return 0
}

# display_bundle : Bullseye kernels without upstream panel support. Guarded, logged, non-destructive: config.txt is backed up
# first and restored when the vendor script did not leave its overlay lines behind. Returns non-zero when it could not help.
display_bundle() {
    local i2c_arg=I2C0 kver bits work rc=0
    [[ "$(hw_opt01 "${PERI_OPT_DSI_I2C:-0}" 0)" == 1 ]] && i2c_arg=I2C1
    if [[ "${PERI_DISPLAY_BUNDLE:-1}" == 0 ]]; then bundle_refuse "the vendor bundle is disabled (PERI_DISPLAY_BUNDLE=0)"; return 1; fi
    if [[ "$OS_CODENAME" != bullseye ]]; then bundle_refuse "the vendor bundle is only supported here on Raspberry Pi OS Bullseye (this is '${OS_CODENAME:-unknown}')"; return 1; fi
    kver=${KERNEL%%[-+]*}
    bits=$KBITS
    if [[ "$HAVE_INTERNET" -ne 1 ]]; then bundle_refuse "no internet connection to download $BUNDLE_URL"; return 1; fi
    if ! confirm "Download the Waveshare DSI driver bundle from $BUNDLE_URL and run its installer for kernel $kver/$bits ($i2c_arg)?"; then
        bundle_refuse "not confirmed (use --yes to allow the download, or install the bundle by hand)"; return 1
    fi
    apt_install git || { bundle_refuse "git is not installed and could not be installed"; return 1; }

    if ! mutating_ok; then
        info "would: git clone --depth 1 $BUNDLE_URL, cd <clone>/$kver/$bits, bash ./WS_xinchDSI_MAIN.sh 40C $i2c_arg (after backing up $CONFIG_TXT)"
        info "would: check that config.txt then contains dtoverlay=WS_xinchDSI_Screen, else restore the backup"
        need_reboot "Waveshare DSI driver bundle installed for kernel $kver"
        return 0
    fi

    work=$(mktemp -d "${TMPDIR:-/tmp}/peri-waveshare-dsi.XXXXXX")
    _display_bundle_run "$work" "$i2c_arg" "$kver" "$bits" || rc=$?
    rm -rf "$work"
    [[ $rc -eq 0 ]] || return "$rc"
    need_reboot "Waveshare DSI driver bundle installed for kernel $kver"
}

main() {
    step "Display: Waveshare 4inch DSI LCD (C) 720x720"
    detect_all
    hw_require_pi "display setup" || return 0
    case "${ARCH:-}" in aarch64|arm64) KBITS=64 ;; *) KBITS=32 ;; esac
    info "display state: KMS overlay=${KMS_OVERLAY:-none}, DSI connector=${DSI_CONNECTOR:-none} connected=$DSI_CONNECTED mode=${DSI_MODE:-n/a}, configured=${DSI_CONFIGURED:-no}, touch=$TOUCH_PRESENT, upstream 4_0_inchC support=$DSI_UPSTREAM_SUPPORTED"

    display_udev_rule
    [[ "$(hw_opt01 "${PERI_OPT_DISABLE_HDMI:-0}" 0)" != 1 ]] || info "display: PERI_OPT_DISABLE_HDMI=1 is applied by the boot step (it is the only step that edits cmdline.txt)"

    if cfg_has '^dtoverlay=WS_xinchDSI'; then
        if cfg_block_present display; then
            warn "config.txt has BOTH the Waveshare legacy driver (WS_xinchDSI_*) and a Peri upstream display block: removing the Peri block (they must never be combined)"
            set_managed_block "$CONFIG_TXT" display < /dev/null
            need_reboot "removed the conflicting upstream display block from $CONFIG_TXT"
        fi
        local state=""
        [[ $DSI_CONNECTED -eq 1 ]] && state=" (DSI $DSI_CONNECTOR connected, mode ${DSI_MODE:-?})"
        skip "display: the legacy Waveshare driver (dtoverlay=WS_xinchDSI_*) is configured - leaving config.txt untouched$state"
        [[ $TOUCH_PRESENT -eq 1 ]] || display_touch_fix
        return 0
    fi

    if cfg_block_present display; then
        info "display: the Peri block is already in $CONFIG_TXT: re-applying it with the current options"
        display_upstream
        if [[ $DSI_CONNECTED -eq 1 ]]; then ok "DSI ${DSI_CONNECTOR} is connected (mode ${DSI_MODE:-?})"; else warn "the display overlay is configured but no DSI connector is connected yet: reboot pending, or check the ribbon cable / DIP switch (see hint below)"; display_hint; fi
        return 0
    fi

    if [[ $DSI_CONNECTED -eq 1 ]]; then
        if [[ "$DSI_MODE" == 720x720* ]]; then
            skip "display: DSI connector $DSI_CONNECTOR is already connected at 720x720 (${DSI_CONFIGURED:-driver configured outside config.txt}) - the panel works, leaving config.txt untouched"
            [[ $TOUCH_PRESENT -eq 1 ]] || { warn "the panel works but no touch device is registered"; display_touch_fix; display_hint; }
        else
            warn "display: DSI connector $DSI_CONNECTOR is connected but reports '${DSI_MODE:-no mode}', not 720x720: not adding the Waveshare overlay on top of another DSI panel"
            warn "  if this IS the Peri panel: remove the other DSI overlay from $CONFIG_TXT and re-run"
        fi
        return 0
    fi

    if [[ "$DSI_CONFIGURED" == upstream ]]; then
        skip "display: the upstream overlay is already configured in $CONFIG_TXT (not by Peri) - leaving it alone"
        warn "  no DSI connector is connected yet: reboot pending, or check the ribbon cable / DIP switch"; display_hint
        return 0
    fi

    if [[ $DSI_UPSTREAM_SUPPORTED -eq 1 ]]; then
        info "display: the kernel's vc4-kms-dsi-waveshare-panel overlay supports the 4_0_inchC panel: configuring the upstream overlay"
        display_upstream
        display_hint
        return 0
    fi

    warn "display: the kernel's DSI overlay does not know '4_0_inchC' and no Waveshare driver is installed"
    display_bundle || return 1
    display_hint
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi   # sourced by the tests: functions only
