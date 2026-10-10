#!/usr/bin/env bash
# uninstall.sh - undo what install.sh did, using the manifest /var/lib/peri-install/manifest.
#
#   sudo ./uninstall.sh --yes            (or: sudo /opt/peri/uninstall.sh --yes)
#   ./uninstall.sh --dry-run             show what would be undone, change nothing
#
# In this order: stop + disable the peri-* units (kiosk first); restore every file the installer MODIFIED from its
# FILE.peri-bak (and delete the backup); remove every file it CREATED (never a directory that still holds foreign files;
# directories left empty by that are removed); remove /opt/peri; re-enable services the installer had disabled (display
# manager ...) and restore the default systemd target; drop the lingering flag of user peri.
# Kept unless you ask: the settings/calibration in /var/lib/peri and /etc/peri/peri.env (--purge-data), installed packages
# (--purge-packages: only packages the installer itself installed), the account (--remove-user: only when the installer
# created it). Boot files that were restored need a reboot: the script says so.
# Safe to run twice: the second run finds nothing to do. Failed items stay in the manifest so a re-run retries them.
#
# Options: -y/--yes  --dry-run  --keep-app (keep /opt/peri)  --purge-data  --purge-packages  --remove-user  -h/--help
if [ -z "${BASH_VERSION:-}" ]; then echo "uninstall.sh must be run with bash:  sudo bash ./uninstall.sh --yes" >&2; exit 2; fi
set -Eeuo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
PERI_SRC=$(dirname "$SELF")
export LC_ALL=C
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"      # userdel, udevadm ... are not in the PATH of a plain `su`

ASSUME_YES="${ASSUME_YES:-0}"; DRY_RUN="${DRY_RUN:-0}"
KEEP_APP=0; PURGE_DATA=0; PURGE_PACKAGES=0; REMOVE_USER=0
ORIG_ARGS=("$@")
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$SELF"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --keep-app) KEEP_APP=1 ;;
        --purge-data) PURGE_DATA=1 ;;
        --purge-packages) PURGE_PACKAGES=1 ;;
        --remove-user) REMOVE_USER=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'uninstall.sh: unknown option %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

PERI_ROOT="${PERI_ROOT:-}"; PERI_ROOT="${PERI_ROOT%/}"
if [[ -n "$PERI_ROOT" ]]; then
    [[ -d "$PERI_ROOT" ]] || { echo "uninstall.sh: PERI_ROOT=$PERI_ROOT is not a directory" >&2; exit 2; }
    PERI_ROOT=$(cd "$PERI_ROOT" && pwd -P)
fi
[[ -f "$PERI_SRC/scripts/lib.sh" ]] || { echo "uninstall.sh: scripts/lib.sh not found next to uninstall.sh" >&2; exit 2; }
if [[ "$DRY_RUN" != 1 && -z "$PERI_ROOT" && "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { echo "uninstall.sh: must run as root and sudo is not installed" >&2; exit 2; }
    exec sudo bash "$SELF" "${ORIG_ARGS[@]}"
fi
export PERI_ROOT DRY_RUN ASSUME_YES PERI_SRC
[[ "$DRY_RUN" == 1 && -z "${PERI_LOG_FILE:-}" ]] && export PERI_LOG_FILE=/dev/null
CHANGE_LOG_OWNED=0
if [[ -z "${PERI_CHANGE_LOG:-}" ]]; then PERI_CHANGE_LOG=$(mktemp "${TMPDIR:-/tmp}/peri-uninstall.XXXXXX"); CHANGE_LOG_OWNED=1; fi
export PERI_CHANGE_LOG
cleanup() { [[ $CHANGE_LOG_OWNED -eq 1 ]] && rm -f "$PERI_CHANGE_LOG"; return 0; }
trap cleanup EXIT
trap '' HUP PIPE          # a dropped ssh session or a closed output pipe must not stop an uninstall half-way
umask 022
# shellcheck source=scripts/lib.sh
. "$PERI_SRC/scripts/lib.sh"
# shellcheck source=scripts/detect.sh
. "$PERI_SRC/scripts/detect.sh"
PERI_STEP=uninstall

UNIT_DIR=/etc/systemd/system
PERI_UNITS=(peri-kiosk.service peri-ui-watchdog.timer peri-ui-watchdog.service peri-server.service peri-hwinit.service)
ENV_FILE=/etc/peri/peri.env
FAILED_LINES=()            # manifest lines (kind<TAB>value) whose undo failed: they stay in the manifest
REBOOT_NEEDED=0
RESTORED=0; REMOVED=0

# Directories that must never be removed even when empty (they belong to the OS).
PROTECTED_DIRS=(/ /bin /boot /boot/firmware /dev /etc /etc/X11 /etc/alsa /etc/apt /etc/apt/apt.conf.d /etc/apt/sources.list.d
    /etc/chromium /etc/chromium-browser /etc/chromium.d /etc/default /etc/modprobe.d /etc/modules-load.d /etc/profile.d
    /etc/sudoers.d /etc/systemd /etc/systemd/system /etc/udev /etc/udev/rules.d /etc/xdg /etc/wireplumber /etc/pipewire
    /home /lib /opt /root /run /sbin /srv /tmp /usr /usr/bin /usr/lib /usr/local /usr/local/bin /usr/local/lib
    /usr/local/share /usr/sbin /usr/share /usr/share/plymouth /usr/share/plymouth/themes /var /var/lib /var/log /var/cache)
is_protected() { local d="$1" p; for p in "${PROTECTED_DIRS[@]}"; do [[ "$d" == "$p" ]] && return 0; done; return 1; }

# sane_path PATH : an absolute path without .. that is not a protected directory.
sane_path() {
    local p="$1"
    [[ "$p" == /* && "$p" != *"/../"* && "$p" != */.. && "$p" != *$'\n'* ]] || return 1
    is_protected "${p%/}" && return 1
    return 0
}

manifest_lines() {   # KIND : values in manifest order
    [[ -f "$PERI_MANIFEST" ]] || return 0
    awk -F'\t' -v k="$1" '$1==k {print $2}' "$PERI_MANIFEST"
}
reverse_lines() { local -a a=(); local l; while IFS= read -r l; do a+=("$l"); done; local i; for ((i = ${#a[@]} - 1; i >= 0; i--)); do printf '%s\n' "${a[$i]}"; done; }

under_boot() { case "$1" in /boot|/boot/*) return 0 ;; esac; return 1; }
under_any() {   # PATH ROOT... : is PATH equal to or below one of the roots?
    local p="$1" r; shift
    for r in "$@"; do [[ "$p" == "$r" || "$p" == "$r"/* ]] && return 0; done
    return 1
}

# soft_cmd CMD ARGS... : a system command whose failure is not an error; not even attempted (and not warned about) when the tool
# does not exist on this machine (a chroot/container without systemd).
soft_cmd() {
    if mutating_ok && ! have "$1"; then skip "$1 is not installed: not running '$*'"; return 0; fi
    sysrun_soft "$@"
}

# ------------------------------------------------------------------------------------------------ actions

stop_units() {
    local u real any=0
    for u in "${PERI_UNITS[@]}"; do
        real=$(rp "$UNIT_DIR/$u")
        [[ -e "$real" || -L "$real" ]] || continue
        any=1
        info "stopping and disabling $u"
        soft_cmd systemctl disable --now "$u"
    done
    [[ $any -eq 1 ]] || skip "no peri-* unit files are installed"
    # The kiosk unit conflicts with getty@tty1: bring the login prompt of the local console back.
    if [[ -e "$(rp "$UNIT_DIR/peri-kiosk.service")" ]]; then soft_cmd systemctl start getty@tty1.service; fi
    return 0
}

restore_modified() {
    local path real bak
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ "$path" == "$ENV_FILE" && $PURGE_DATA -eq 0 ]]; then skip "keeping $path (settings and API key; --purge-data removes it)"; continue; fi
        sane_path "$path" || { warn "manifest entry not restored (unsafe path): $path"; FAILED_LINES+=("$(printf 'modified\t%s' "$path")"); continue; }
        real=$(rp "$path"); bak="$real.peri-bak"
        if [[ -e "$bak" || -L "$bak" ]]; then
            if is_dry; then _log "DRY" "$_C_DIM" "would restore $path from $path.peri-bak"; RESTORED=$((RESTORED + 1))
            elif mv -f "$bak" "$real"; then ok "restored $path from its .peri-bak"; RESTORED=$((RESTORED + 1)); _note_change "restored $path"
            else err "could not restore $path from $path.peri-bak"; FAILED_LINES+=("$(printf 'modified\t%s' "$path")"); continue; fi
            under_boot "$path" && REBOOT_NEEDED=1
        else
            warn "no backup $path.peri-bak: $path is left as it is (the installer's edit stays)"
        fi
    done < <(manifest_lines modified | reverse_lines)
    return 0
}

# prune_empty_parents PATH : rmdir the parents of a removed path while they are empty and not OS directories.
prune_empty_parents() {
    local d; d=$(dirname "$1")
    while [[ "$d" != / && -n "$d" ]]; do
        is_protected "$d" && return 0
        [[ -d "$(rp "$d")" ]] || { d=$(dirname "$d"); continue; }
        if is_dry; then return 0; fi
        rmdir "$(rp "$d")" 2>/dev/null || return 0
        info "removed empty directory $d"
        d=$(dirname "$d")
    done
}

remove_created_files() {
    local path real
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ "$path" == "$ENV_FILE" && $PURGE_DATA -eq 0 ]]; then skip "keeping $path (settings and API key; --purge-data removes it)"; continue; fi
        if under_any "$path" /var/lib/peri /etc/peri && [[ $PURGE_DATA -eq 0 ]]; then skip "keeping $path (data; --purge-data removes it)"; continue; fi
        if [[ $KEEP_APP -eq 1 ]] && under_any "$path" /opt/peri; then skip "keeping $path (--keep-app)"; continue; fi
        sane_path "$path" || { warn "manifest entry not removed (unsafe path): $path"; FAILED_LINES+=("$(printf 'created\t%s' "$path")"); continue; }
        real=$(rp "$path")
        if [[ -L "$real" || -f "$real" ]]; then
            if is_dry; then _log "DRY" "$_C_DIM" "would remove $path"; REMOVED=$((REMOVED + 1))
            elif rm -f -- "$real"; then ok "removed $path"; REMOVED=$((REMOVED + 1)); _note_change "removed $path"
            else err "could not remove $path"; FAILED_LINES+=("$(printf 'created\t%s' "$path")"); continue; fi
            under_boot "$path" && REBOOT_NEEDED=1
            prune_empty_parents "$path"
        elif [[ -d "$real" ]]; then
            if is_dry; then _log "DRY" "$_C_DIM" "would remove directory $path if it is empty"
            elif rmdir "$real" 2>/dev/null; then ok "removed empty directory $path"; REMOVED=$((REMOVED + 1))
            else warn "$path is a directory that still has content: left in place"; fi
        else
            debug "already gone: $path"
        fi
    done < <(manifest_lines created | reverse_lines)
    return 0
}

remove_trees_and_data() {
    local path real
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if [[ $KEEP_APP -eq 1 ]]; then skip "keeping $path (--keep-app)"; continue; fi
        if [[ "$path" != /opt/?* ]] || ! sane_path "$path"; then warn "manifest tree not removed (only directories below /opt are removed): $path"; continue; fi
        real=$(rp "$path")
        [[ -d "$real" ]] || { debug "already gone: $path"; continue; }
        if is_dry; then _log "DRY" "$_C_DIM" "would remove the application tree $path"
        else rm -rf -- "$real"; ok "removed the application tree $path"; REMOVED=$((REMOVED + 1)); _note_change "removed tree $path"; fi
    done < <(manifest_lines tree)
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        sane_path "$path" || { warn "manifest data directory not touched (unsafe path): $path"; continue; }
        real=$(rp "$path")
        [[ -d "$real" ]] || { debug "already gone: $path"; continue; }
        if [[ $PURGE_DATA -eq 1 ]]; then
            case "$path" in
                /etc/peri|/var/lib/peri)
                    if is_dry; then _log "DRY" "$_C_DIM" "would remove $path including its content (--purge-data)"
                    else rm -rf -- "$real"; ok "removed $path including its content (--purge-data)"; REMOVED=$((REMOVED + 1)); _note_change "purged $path"; fi ;;
                *) warn "unexpected data directory in the manifest, not purged: $path" ;;
            esac
        else
            if is_dry; then _log "DRY" "$_C_DIM" "would keep $path (data) unless it is empty"
            elif rmdir "$real" 2>/dev/null; then ok "removed empty directory $path"
            else info "keeping $path: it holds your settings/calibration (--purge-data removes it)"; fi
        fi
    done < <(manifest_lines datadir)
    # Backup left next to a kept/purged env file.
    if [[ $PURGE_DATA -eq 1 && ( -e "$(rp "$ENV_FILE.peri-bak")" ) ]] && ! is_dry; then rm -f "$(rp "$ENV_FILE.peri-bak")"; fi
    return 0
}

restore_services() {
    local unit target cur
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        case "$unit" in peri-*) continue ;; esac
        info "re-enabling $unit (it was enabled before the installer disabled it)"
        if sysrun systemctl enable "$unit"; then
            case "$unit" in *lightdm*|*gdm*|*sddm*|*display-manager*) REBOOT_NEEDED=1 ;; esac
        else FAILED_LINES+=("$(printf 'svc-was-enabled\t%s' "$unit")"); fi
    done < <(manifest_lines svc-was-enabled)
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        case "$unit" in peri-*) continue ;; esac
        info "disabling $unit again (it was disabled before the installer enabled it)"
        soft_cmd systemctl disable "$unit"
    done < <(manifest_lines svc-was-disabled)
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        info "unmasking $unit (the installer had masked it)"
        soft_cmd systemctl unmask "$unit"
    done < <(manifest_lines svc-masked)
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        cur=""
        mutating_ok && have systemctl && cur=$(systemctl get-default 2>/dev/null || true)
        if [[ "$cur" == "$target" ]]; then skip "default target is already $target"; continue; fi
        info "restoring the default systemd target: $target"
        if sysrun systemctl set-default "$target"; then REBOOT_NEEDED=1; else FAILED_LINES+=("$(printf 'default-target\t%s' "$target")"); fi
    done < <(manifest_lines default-target)
    return 0
}

purge_packages() {
    local -a pkgs=(); local p removed extra
    while IFS= read -r p; do [[ -n "$p" ]] && pkgs+=("$p"); done < <(manifest_lines pkg)
    if [[ ${#pkgs[@]} -eq 0 ]]; then skip "the manifest lists no packages installed by the installer"; return 0; fi
    info "packages installed by the installer: ${pkgs[*]}"
    if mutating_ok && have apt-get; then
        removed=$(apt-get -s purge "${pkgs[@]}" 2>/dev/null | awk '/^Remv /{print $2}') || removed=""
        extra=""
        for p in $removed; do [[ " ${pkgs[*]} " == *" $p "* ]] || extra+=" $p"; done
        if [[ -n "$extra" ]]; then
            warn "not purging: apt would also remove packages the installer did not install:$extra"
            for p in "${pkgs[@]}"; do FAILED_LINES+=("$(printf 'pkg\t%s' "$p")"); done
            return 0
        fi
    fi
    if sysrun env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 purge -y "${pkgs[@]}"; then
        info "run 'sudo apt-get autoremove' if you also want dependencies of these packages removed"
    else
        for p in "${pkgs[@]}"; do FAILED_LINES+=("$(printf 'pkg\t%s' "$p")"); done
    fi
    return 0
}

remove_user() {
    local u
    u=$(manifest_lines user | sed -n '1p')
    if [[ -z "$u" ]]; then warn "--remove-user: the manifest has no 'user' entry, so the account was not created by the installer: not removing it"; return 0; fi
    if ! user_exists "$u"; then skip "user $u does not exist"; return 0; fi
    info "removing user $u"
    soft_cmd loginctl disable-linger "$u"
    soft_cmd loginctl terminate-user "$u"
    if ! sysrun userdel "$u"; then FAILED_LINES+=("$(printf 'user\t%s' "$u")"); fi
    return 0
}

drop_linger() {
    local u
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        info "disabling lingering for $u"
        soft_cmd loginctl disable-linger "$u"
    done < <(manifest_lines linger)
    return 0
}

report_pkg_removed() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && info "note: the installer removed package '$p'; it is not reinstalled (sudo apt-get install $p if you need it)"
    done < <(manifest_lines pkg-removed)
    return 0
}

finish_manifest() {
    is_dry && return 0
    if [[ ${#FAILED_LINES[@]} -gt 0 ]]; then
        printf '%s\n' "${FAILED_LINES[@]}" > "$PERI_MANIFEST.new" && mv -f "$PERI_MANIFEST.new" "$PERI_MANIFEST"
        warn "${#FAILED_LINES[@]} item(s) could not be undone and stay in $PERI_MANIFEST: fix the cause and run uninstall.sh again"
        return 0
    fi
    rm -f "$PERI_MANIFEST" "$PERI_REBOOT_FLAG" "$PERI_STATE_INSTALL_DIR/apt-updated"; rm -rf "$PERI_STATE_INSTALL_DIR/lock.d"
    rmdir "$PERI_STATE_INSTALL_DIR" 2>/dev/null || true
}

main() {
    local mode="REAL RUN"
    if [[ "$DRY_RUN" == 1 ]]; then mode="DRY RUN (nothing is changed)"; elif [[ -n "$PERI_ROOT" ]]; then mode="FAKE ROOT $PERI_ROOT"; fi
    step "Peri uninstall - $mode"
    if [[ ! -s "$PERI_MANIFEST" ]]; then
        info "nothing to do: there is no install manifest ($PERI_MANIFEST); the installer either never ran here or was already uninstalled"
        local u
        for u in "${PERI_UNITS[@]}"; do
            [[ -e "$(rp "$UNIT_DIR/$u")" ]] && warn "$UNIT_DIR/$u exists although there is no manifest: it was not installed by this installer version; remove it by hand if unwanted"
        done
        return 0
    fi
    detect_boot
    info "manifest: $PERI_MANIFEST ($(wc -l < "$PERI_MANIFEST") entries)"
    info "plan: stop/disable peri units; restore $(manifest_lines modified | wc -l) modified file(s); remove $(manifest_lines created | wc -l) created file(s)$([[ $KEEP_APP -eq 1 ]] && echo '; keep /opt/peri'); data $([[ $PURGE_DATA -eq 1 ]] && echo 'REMOVED (--purge-data)' || echo 'kept'); packages $([[ $PURGE_PACKAGES -eq 1 ]] && echo purged || echo kept); user $([[ $REMOVE_USER -eq 1 ]] && echo removed || echo kept)"
    if [[ "$ASSUME_YES" != 1 && "$DRY_RUN" != 1 ]]; then
        confirm "Uninstall Peri as described?" || die "not confirmed: nothing was changed (use --yes to run unattended)" 2
    fi
    stop_units
    drop_linger
    restore_modified
    remove_created_files
    remove_trees_and_data
    restore_services
    [[ $PURGE_PACKAGES -eq 1 ]] && purge_packages
    [[ $REMOVE_USER -eq 1 ]] && remove_user
    report_pkg_removed
    if [[ $REMOVED -gt 0 || $RESTORED -gt 0 ]]; then
        soft_cmd systemctl daemon-reload
        soft_cmd udevadm control --reload-rules
    fi
    finish_manifest

    local rc=0; [[ ${#FAILED_LINES[@]} -eq 0 ]] || rc=1
    {
        printf '\n'
        if is_dry; then printf 'Dry run: %d file(s) would be restored, %d removed. Nothing was changed.\n' "$RESTORED" "$REMOVED"
        else printf 'Uninstall %s: %d file(s) restored, %d removed. Log: %s\n' "$([[ $rc -eq 0 ]] && echo finished || echo 'finished with errors')" "$RESTORED" "$REMOVED" "$PERI_LOG_FILE"; fi
        if [[ $REBOOT_NEEDED -eq 1 ]]; then
            printf '\n*** REBOOT REQUIRED ***\n'
            printf 'Boot configuration (or the display manager / default target) was restored.\n'
            printf 'Next:  sudo reboot\n'
        fi
    } || true                                    # output may have gone away: the work is done, the exit status must not change
    return "$rc"
}

main
