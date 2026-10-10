#!/usr/bin/env bash
# setup-boot.sh - installer step "boot": quiet boot and the Peri splash screen (RESEARCH.md section 4).
#
#   config.txt   disable_splash=1 (no rainbow square), boot_delay=0            (in place when present, else a managed block "peri:boot")
#   cmdline.txt  console=tty1 -> console=tty3, quiet loglevel=3 logo.nologo vt.global_cursor_default=0 consoleblank=0
#                plymouth.ignore-serial-consoles, splash (only when the Peri Plymouth theme is in place and PERI_OPT_NO_SPLASH != 1),
#                and with PERI_OPT_DISABLE_HDMI=1: video=HDMI-A-1:d video=HDMI-A-2:d (so the UI cannot land on an HDMI screen).
#   Plymouth     package plymouth (when missing), theme "peri" in /usr/share/plymouth/themes/peri (script module: the 720x720
#                boot logo centred on #0A0B0E; rotation by PERI_OPT_SPLASH_ROTATE), plymouth-set-default-theme peri (no -R),
#                initramfs rebuilt only when one is actually in use. Everything Plymouth is cosmetic: failures only warn.
#   --no-splash  (PERI_OPT_NO_SPLASH=1) means "leave the boot experience alone", as INSTALL.md promises: no Plymouth theme, no
#                splash token AND none of the quiet-boot edits above. The one exception is PERI_OPT_DISABLE_HDMI=1, which is
#                still applied (a functional setting, not cosmetics).
#
# The kernel command line is the one file here that can leave a Pi unbootable, so it is handled defensively: the new line is
# COMPOSED in memory, validated (exactly one line, root= and every other root/rootwait/fsck token of the old line still
# present, < 500 bytes) BEFORE anything is written, written once (backup FILE.peri-bak), validated again afterwards and
# restored to the pre-run content when that fails (the step then fails). root=, rootfstype=, rootwait, fsck.* are never touched.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: setup-boot.sh [-h|--help]           (environment driven; run as root; DRY_RUN=1 shows a diff and changes nothing)

Environment:
  PERI_ROOT                  fake-root prefix for tests (empty on a device)
  DRY_RUN=0|1                1 = print what would change, change nothing
  PERI_OPT_NO_SPLASH=0|1     1 = leave the boot experience alone: no Plymouth theme, no quiet-boot changes (only HDMI, if asked)
  PERI_OPT_SPLASH_ROTATE=0   0|90|180|270 - rotate the splash logo clockwise
  PERI_OPT_DISABLE_HDMI=0    1 = add video=HDMI-A-1:d video=HDMI-A-2:d to cmdline.txt
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
PERI_STEP=boot

THEME=peri
THEME_DIR="/usr/share/plymouth/themes/$THEME"
PROTECTED_ERE='^(root=|rootfstype=|rootflags=|rootwait$|fsck\.|init=|ro$|rw$)'   # tokens that must survive every edit
SNAP_CFG=""; SNAP_CMD=""
FAILED=0

cleanup() { rm -f "$SNAP_CFG" "$SNAP_CMD" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------- config.txt
boot_config() {
    local kv key val body="" before after
    before=$(hw_changes)
    for kv in disable_splash=1 boot_delay=0; do
        key=${kv%%=*}; val=${kv#*=}
        if cfg_has_outside boot "^${key}="; then
            kv_set "$CONFIG_TXT" "$key" "$val"                      # someone already has the key: change it where it is
        else
            body+="${kv}"$'\n'
        fi
    done
    if [[ -n "$body" ]]; then
        set_managed_block "$CONFIG_TXT" boot <<< "[all]"$'\n'"# quiet boot: no rainbow splash, no boot delay (Peri installer)"$'\n'"${body%$'\n'}"
    else
        set_managed_block "$CONFIG_TXT" boot < /dev/null            # nothing of ours left to keep in a block
    fi
    after=$(hw_changes)
    if [[ "$after" -gt "$before" ]]; then
        if ! hw_config_intact "$SNAP_CFG" "$CONFIG_TXT" '^(disable_splash|boot_delay)=' boot; then
            hw_restore "$SNAP_CFG" "$CONFIG_TXT" || true
            err "config.txt failed the integrity check after the edit: restored, boot step FAILED"
            FAILED=1; return 1
        fi
        info "config.txt: disable_splash=1 and boot_delay=0 set"
    else
        skip "config.txt: disable_splash=1 and boot_delay=0 already set"
    fi
}

# -------------------------------------------------------------------------------------------------- Plymouth
# boot_plymouth : 0 when the Peri theme is (or, in dry-run/fake root, would be) in place, so `splash` may go on the command line.
boot_plymouth() {
    local logo="$PERI_SRC/assets/boot-logo.png" rot deg rad before current="" changed=0
    if [[ "$(hw_opt01 "${PERI_OPT_NO_SPLASH:-0}" 0)" == 1 ]]; then return 1; fi
    if [[ ! -f "$logo" ]]; then warn "splash: $logo not found - skipping the Plymouth theme"; return 1; fi
    rot=${PERI_OPT_SPLASH_ROTATE:-0}
    case "$rot" in
        0) deg=0; rad=0 ;;
        90) deg=90; rad="Math.Pi / 2" ;;
        180) deg=180; rad="Math.Pi" ;;
        270) deg=270; rad="3 * Math.Pi / 2" ;;
        *) warn "splash: PERI_OPT_SPLASH_ROTATE='$rot' is not one of 0/90/180/270 - using 0"; deg=0; rad=0 ;;
    esac
    if ! pkg_installed plymouth; then
        apt_update_once
        if ! pkg_available plymouth; then warn "splash: package plymouth is not available (offline / no package index?) - no splash"; return 1; fi
        if ! apt_install plymouth; then warn "splash: plymouth could not be installed - no splash"; return 1; fi
    else
        info "splash: plymouth is already installed"
    fi
    before=$(hw_changes)
    install_file "$logo" "$THEME_DIR/boot-logo.png" 0644
    install_file "$PERI_SRC/scripts/data/plymouth/peri.plymouth" "$THEME_DIR/$THEME.plymouth" 0644
    render_to "$PERI_SRC/scripts/data/plymouth/peri.script.in" "$THEME_DIR/$THEME.script" 0644 root:root \
        "PERI_SPLASH_ROTATE_DEG=$deg" "PERI_SPLASH_ROTATE_RAD=$rad"
    [[ $(hw_changes) -gt $before ]] && changed=1
    current=$(sed -n 's/^[[:space:]]*Theme=[[:space:]]*//p' "$(rp /etc/plymouth/plymouthd.conf)" 2>/dev/null | tail -n 1 || true)
    if [[ "$current" == "$THEME" ]]; then
        skip "splash: $THEME is already the default Plymouth theme"
    else
        info "splash: making '$THEME' the default Plymouth theme (was: ${current:-not set})"
        backup_file /etc/plymouth/plymouthd.conf
        sysrun_soft plymouth-set-default-theme "$THEME"        # no -R: the initramfs is rebuilt below, and only if in use
        changed=1
    fi
    if [[ $changed -eq 1 ]]; then boot_initramfs; fi
    return 0
}

# boot_initramfs : only when an initramfs is really in use (auto_initramfs=1 / initramfs line + a file); soft-fail.
boot_initramfs() {
    local boot; boot=$(rp "$BOOT_DIR")
    if { cfg_has '^auto_initramfs=1' || cfg_has '^initramfs '; } && compgen -G "$boot/initramfs*" > /dev/null; then
        info "splash: an initramfs is in use: rebuilding it so the theme is part of it"
        sysrun_soft update-initramfs -u
    else
        info "splash: no initramfs in use (Plymouth starts from the running system): not rebuilding one"
    fi
}

# ---------------------------------------------------------------------------------------------- cmdline.txt
# boot_cmdline_compose SRCFILE < SPEC : print the new one-line command line. SPEC lines are TAB separated:
#   replace<TAB>OLD<TAB>NEW    exact token OLD becomes NEW (no-op when absent)
#   set<TAB>TOKEN              TOKEN is "flag" or "key=value": the first token with that key becomes TOKEN, later duplicates
#                              are dropped, appended when there is none
#   add<TAB>TOKEN              append the exact token unless it is already there (for repeatable keys such as video=)
boot_cmdline_compose() {
    awk -F'\t' -v srcfile="$1" '
        BEGIN { getline line < srcfile; close(srcfile); gsub(/\r/, "", line); n = split(line, tok, " "); for (i = 1; i <= n; i++) keep[i] = 1 }
        $1 == "replace" { for (i = 1; i <= n; i++) if (keep[i] && tok[i] == $2) tok[i] = $3; next }
        $1 == "set" {
            key = $2; sub(/=.*/, "", key); found = 0
            for (i = 1; i <= n; i++) {
                if (!keep[i]) continue
                k = tok[i]; sub(/=.*/, "", k)
                if (k == key) { if (!found) { tok[i] = $2; found = 1 } else keep[i] = 0 }
            }
            if (!found) { n++; tok[n] = $2; keep[n] = 1 }
            next }
        $1 == "add" {
            found = 0
            for (i = 1; i <= n; i++) if (keep[i] && tok[i] == $2) found = 1
            if (!found) { n++; tok[n] = $2; keep[n] = 1 }
            next }
        END { out = ""; for (i = 1; i <= n; i++) if (keep[i]) out = out (out == "" ? "" : " ") tok[i]; print out }'
}

# boot_cmdline_valid FILE [ORIGINAL] : exactly one non-empty line, root= present, < 500 bytes, printable ASCII only and (when
# ORIGINAL is given) every protected token of the original line still present.
boot_cmdline_valid() {
    local f="$1" orig="${2:-}" lines nonempty bytes tok tokens
    [[ -f "$f" ]] || { err "cmdline check: $f does not exist"; return 1; }
    lines=$(grep -c '' "$f" || true); nonempty=$(grep -c '[^[:space:]]' "$f" || true); bytes=$(wc -c < "$f")
    if [[ "$lines" -ne 1 || "$nonempty" -ne 1 ]]; then err "cmdline check: not exactly one line ($lines lines, $nonempty non-empty)"; return 1; fi
    if [[ "$bytes" -gt 500 ]]; then err "cmdline check: $bytes bytes is too long for the firmware (limit ~512)"; return 1; fi
    if LC_ALL=C grep -q '[^[:print:]]' "$f"; then err "cmdline check: contains non-printable characters"; return 1; fi
    tokens=$(tr -s '[:space:]' '\n' < "$f")
    if ! grep -q '^root=' <<< "$tokens"; then err "cmdline check: no root= token"; return 1; fi
    if [[ -n "$orig" ]]; then
        while IFS= read -r tok; do
            [[ -n "$tok" ]] || continue
            grep -qxF -- "$tok" <<< "$tokens" || { err "cmdline check: the protected token '$tok' would be lost"; return 1; }
        done < <(tr -s '[:space:]' '\n' < "$orig" | grep -E "$PROTECTED_ERE" || true)
    fi
    return 0
}

boot_cmdline() {
    local want_splash="$1" real cand spec before tokens
    real=$(rp "$CMDLINE_TXT")
    if [[ ! -f "$real" ]]; then warn "cmdline: $CMDLINE_TXT not found - nothing changed there"; return 0; fi
    tokens=$(tr -s '[:space:]' '\n' < "$real")
    if [[ $(grep -c '[^[:space:]]' "$real" || true) -ne 1 ]] || ! grep -q '^root=' <<< "$tokens"; then
        err "cmdline: $CMDLINE_TXT does not look like a normal one-line kernel command line with root= - NOT touching it"
        FAILED=1; return 1
    fi
    spec=""
    if [[ "$(hw_opt01 "${PERI_OPT_NO_SPLASH:-0}" 0)" != 1 ]]; then
        spec=$'replace\tconsole=tty1\tconsole=tty3\n'
        spec+=$'set\tquiet\nset\tloglevel=3\nset\tlogo.nologo\nset\tvt.global_cursor_default=0\nset\tconsoleblank=0\n'
        spec+=$'set\tplymouth.ignore-serial-consoles\n'
        [[ "$want_splash" == 1 ]] && spec+=$'set\tsplash\n'
    fi
    if [[ "$(hw_opt01 "${PERI_OPT_DISABLE_HDMI:-0}" 0)" == 1 ]]; then
        spec+=$'add\tvideo=HDMI-A-1:d\nadd\tvideo=HDMI-A-2:d\n'
        info "cmdline: PERI_OPT_DISABLE_HDMI=1 -> video=HDMI-A-1:d video=HDMI-A-2:d (both HDMI connectors disabled)"
    fi
    if [[ -z "$spec" ]]; then skip "cmdline: nothing to change ($CMDLINE_TXT is left alone)"; return 0; fi
    cand=$(mktemp)
    printf '%s' "$spec" | boot_cmdline_compose "$real" > "$cand"
    if ! boot_cmdline_valid "$cand" "$real"; then
        err "cmdline: the composed command line failed validation - nothing written: $(cat "$cand")"
        rm -f "$cand"; FAILED=1; return 1
    fi
    before=$(hw_changes)
    write_file "$CMDLINE_TXT" < "$cand"
    rm -f "$cand"
    if [[ $(hw_changes) -le $before ]]; then skip "cmdline: $CMDLINE_TXT already has the quiet-boot settings"; return 0; fi
    info "cmdline: $CMDLINE_TXT updated"
    if ! is_dry && ! boot_cmdline_valid "$real"; then
        err "cmdline: $CMDLINE_TXT failed the check AFTER writing - restoring the previous content"
        hw_restore "$SNAP_CMD" "$CMDLINE_TXT" || true
        FAILED=1; return 1
    fi
    return 0
}

main() {
    local before want_splash=0
    step "Boot: quiet boot and Peri splash"
    detect_all
    hw_require_pi "boot setup" || return 0
    SNAP_CFG=$(hw_snapshot "$CONFIG_TXT"); SNAP_CMD=$(hw_snapshot "$CMDLINE_TXT")
    before=$(hw_changes)

    if [[ "$(hw_opt01 "${PERI_OPT_NO_SPLASH:-0}" 0)" == 1 ]]; then
        skip "boot: PERI_OPT_NO_SPLASH=1 (--no-splash): no Plymouth theme and no quiet-boot changes to config.txt / cmdline.txt (an existing 'splash' token is left alone)"
    else
        boot_config || true
        if boot_plymouth; then want_splash=1; fi
    fi
    boot_cmdline "$want_splash" || true

    if [[ $(hw_changes) -gt $before && $FAILED -eq 0 ]]; then need_reboot "boot configuration changed (quiet boot / splash)"; fi
    if [[ $FAILED -ne 0 ]]; then err "boot step FAILED (see the messages above; the boot files were restored or left untouched)"; return 1; fi
    if [[ $want_splash -eq 1 ]]; then info "boot: the splash (theme '$THEME') shows from the next boot"; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi   # sourced by the tests: functions only
