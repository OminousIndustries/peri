#!/usr/bin/env bash
# setup-kiosk.sh - installer step "kiosk": the Chromium UI on the built-in display, started at boot on tty1.
#
#   compositor  PERI_OPT_KIOSK=auto (default): cage on Bookworm/Trixie when cage is installed or installable, X11 (xinit +
#               openbox) on Bullseye or when cage is unavailable; labwc only when asked for. An explicit PERI_KIOSK already in
#               /etc/peri/peri.env is kept by `auto` (it is what `peri-kiosk mode` writes). The choice is recorded as
#               PERI_KIOSK=<mode> in /etc/peri/peri.env (when that file exists) and read by scripts/launch-kiosk.sh.
#   packages    per mode (cage | x11 | labwc) + chromium (or chromium-browser on Bullseye) + libpam-systemd; names are checked
#               with pkg_available so the right chromium/unclutter variant is picked per suite.
#   chromium    managed policy /etc/chromium/policies/managed/peri.json AND /etc/chromium-browser/policies/managed/peri.json
#               (mic without a prompt for the UI origin, navigation restricted to it, no sync/translate/password prompts ...)
#   x11         /etc/X11/Xwrapper.config (allowed_users=anybody, needs_root_rights=yes: X is started by a systemd unit, not a login)
#   labwc       /etc/peri/labwc/{rc.xml,environment,autostart}: no decorations, no key/mouse bindings
#   CLI         /usr/local/bin/peri-kiosk (start|stop|restart|status|logs|reload|mode|enable|disable|desktop|console)
#   Desktop     on Desktop images the display manager (lightdm ...) is disabled and the default target becomes multi-user.target
#               (both recorded in the manifest, undone by uninstall.sh or `peri-kiosk disable`), then a reboot is requested:
#               Peri owns tty1 and the display. Never applied on a machine that is not a Raspberry Pi.
# The units peri-kiosk.service / peri-hwinit.service are rendered and enabled by setup-services.sh; this step never STARTS the kiosk.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: setup-kiosk.sh [-h|--help]          (environment driven; run as root; DRY_RUN=1 shows a diff and changes nothing)

Environment:
  PERI_ROOT              fake-root prefix for tests (empty on a device)
  DRY_RUN=0|1            1 = print what would change, change nothing
  PERI_OPT_KIOSK=auto    auto | cage | x11 | labwc
  PERI_OPT_DISABLE_HDMI  only used here for a warning (the boot step edits cmdline.txt)
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
PERI_STEP=kiosk

ENV_FILE=/etc/peri/peri.env
MODE=""
FAILED=0

# ------------------------------------------------------------------------------------------------- mode
kiosk_resolve_mode() {
    local want="${PERI_OPT_KIOSK:-auto}" modern=0 cage_ok=0 labwc_ok=0 existing
    case "$want" in auto|cage|x11|labwc) ;; *) warn "unknown PERI_OPT_KIOSK='$want' - using auto"; want=auto ;; esac
    case "$OS_CODENAME" in bullseye|"") ;; *) modern=1 ;; esac
    if [[ $HAVE_CAGE -eq 1 ]] || pkg_available cage; then cage_ok=1; fi
    if [[ $HAVE_LABWC -eq 1 ]] || pkg_available labwc; then labwc_ok=1; fi
    case "$want" in
        cage)
            if [[ $cage_ok -eq 1 ]]; then MODE=cage
            else warn "kiosk: cage requested but it is not installed and not available on ${OS_CODENAME:-this OS}: using X11"; MODE=x11; fi ;;
        labwc)
            if [[ $labwc_ok -eq 1 ]]; then MODE=labwc
            else warn "kiosk: labwc requested but it is not installed and not available on ${OS_CODENAME:-this OS}: using X11"; MODE=x11; fi ;;
        x11) MODE=x11 ;;
        auto)
            existing=$(hw_env_get "$ENV_FILE" PERI_KIOSK "")
            if [[ "$existing" == x11 || ( "$existing" == cage && $cage_ok -eq 1 ) || ( "$existing" == labwc && $labwc_ok -eq 1 ) ]]; then
                MODE=$existing; info "kiosk: keeping PERI_KIOSK=$MODE from $ENV_FILE (use --kiosk to change it)"
            elif [[ $modern -eq 1 && $cage_ok -eq 1 ]]; then
                MODE=cage; info "kiosk: auto -> cage (Wayland kiosk compositor; ${OS_CODENAME} has it)"
            elif [[ $modern -eq 1 ]]; then
                MODE=x11; info "kiosk: auto -> X11 (cage is neither installed nor available)"
            else
                MODE=x11; info "kiosk: auto -> X11 (${OS_CODENAME:-this OS} has no cage package)"
            fi ;;
    esac
    info "kiosk: compositor = $MODE"
}

# ---------------------------------------------------------------------------------------------- packages
# kiosk_pick_packages : fills REQUIRED and OPTIONAL for the chosen mode
kiosk_pick_packages() {
    local chromium=""
    REQUIRED=(); OPTIONAL=()
    if [[ -n "$CHROMIUM_PKG" ]]; then chromium="$CHROMIUM_PKG"
    elif [[ -n "$CHROMIUM_CANDIDATE" ]]; then chromium="$CHROMIUM_CANDIDATE"
    elif [[ "$OS_CODENAME" == bullseye ]]; then chromium='chromium-browser'
    else chromium='chromium'; fi
    REQUIRED+=("$chromium" libpam-systemd)
    case "$MODE" in
        cage) REQUIRED+=(cage) ;;
        x11)
            REQUIRED+=(xserver-xorg xserver-xorg-input-libinput xserver-xorg-legacy xinit x11-xserver-utils openbox)
            OPTIONAL+=(xinput x11-utils)
            if pkg_installed unclutter-xfixes || pkg_installed unclutter; then :
            elif pkg_available unclutter-xfixes; then OPTIONAL+=(unclutter-xfixes)
            else OPTIONAL+=(unclutter); fi ;;
        labwc) REQUIRED+=(labwc); OPTIONAL+=(wlr-randr) ;;
    esac
}

kiosk_packages() {
    local p install=()
    apt_update_once
    detect_chromium                                  # the package index may have been refreshed just now
    kiosk_pick_packages
    for p in "${REQUIRED[@]}"; do
        if pkg_installed "$p"; then continue
        elif pkg_available "$p" || is_dry; then install+=("$p")
        else err "kiosk: required package '$p' is not installed and not available (offline, or no package index: sudo apt update)"; FAILED=1; fi
    done
    for p in "${OPTIONAL[@]}"; do
        if pkg_installed "$p"; then continue
        elif pkg_available "$p" || is_dry; then install+=("$p")
        else warn "kiosk: optional package '$p' is not available: skipped"; fi
    done
    [[ $FAILED -eq 0 ]] || return 1
    if [[ ${#install[@]} -eq 0 ]]; then skip "kiosk: all packages for mode $MODE are already installed"; return 0; fi
    if ! apt_install "${install[@]}"; then err "kiosk: installing ${install[*]} failed"; FAILED=1; return 1; fi
    if mutating_ok; then
        local need=()
        case "$MODE" in cage) need=(cage) ;; x11) need=(xinit) ;; labwc) need=(labwc) ;; esac
        for p in "${need[@]}"; do have "$p" || { err "kiosk: '$p' is still missing after the package installation"; FAILED=1; }; done
        have chromium || have chromium-browser || { err "kiosk: neither chromium nor chromium-browser is available after the installation"; FAILED=1; }
    fi
    [[ $FAILED -eq 0 ]]
}

# ------------------------------------------------------------------------------------------ peri.env / policy
kiosk_env() {
    local current
    if [[ ! -f "$(rp "$ENV_FILE")" ]]; then
        info "kiosk: $ENV_FILE does not exist yet (the app step creates it): PERI_KIOSK=$MODE not recorded; the launcher then picks the first installed of cage, x11, labwc"
        return 0
    fi
    current=$(hw_env_get "$ENV_FILE" PERI_KIOSK "")
    if [[ "$current" == "$MODE" ]]; then skip "kiosk: PERI_KIOSK=$MODE already set in $ENV_FILE"; return 0; fi
    if is_dry; then
        # never let a dry-run diff of this file scroll by: it also holds the API key
        info "would set PERI_KIOSK=$MODE in $ENV_FILE (was: ${current:-not set})"; _note_would "$ENV_FILE"; return 0
    fi
    info "kiosk: recording PERI_KIOSK=$MODE in $ENV_FILE (was: ${current:-not set})"
    if [[ -z "$current" ]] && grep -qE '^#[[:space:]]*PERI_KIOSK=' "$(rp "$ENV_FILE")"; then
        # like `peri-config set`: switch the commented template line on instead of appending a second one
        awk -v m="$MODE" '!done && /^#[[:space:]]*PERI_KIOSK=/ { print "PERI_KIOSK=" m; done = 1; next } { print }' "$(rp "$ENV_FILE")" | write_file "$ENV_FILE"
    else
        kv_set "$ENV_FILE" PERI_KIOSK "$MODE"
    fi
}

kiosk_policy() {
    local port url origin origins d
    port=$(hw_env_get "$ENV_FILE" PERI_PORT "${PERI_PORT:-8420}")
    [[ "$port" =~ ^[0-9]{2,5}$ ]] || { warn "kiosk: PERI_PORT='$port' is not a port number - policy uses 8420"; port=8420; }
    url=$(hw_env_get "$ENV_FILE" PERI_URL "http://127.0.0.1:$port/")
    origin=$(printf '%s' "$url" | sed -E 's|^(https?://[^/]+).*$|\1|')
    # the URL goes into a JSON string (and through render_to): keep it to plain characters (no quotes, backslashes, spaces, &)
    if ! [[ "$origin" =~ ^https?://[A-Za-z0-9._:-]+$ && "$url" =~ ^https?://[A-Za-z0-9._:/?=%+~#@-]+$ ]]; then
        warn "kiosk: PERI_URL='$url' is not a plain http(s) URL - the policy uses the default"; url="http://127.0.0.1:$port/"; origin="http://127.0.0.1:$port"
    fi
    origins="\"http://127.0.0.1:$port\", \"http://localhost:$port\""
    case "$origins" in *"\"$origin\""*) ;; *) origins+=", \"$origin\"" ;; esac
    for d in /etc/chromium/policies/managed /etc/chromium-browser/policies/managed; do
        render_to "$PERI_SRC/scripts/data/chromium-policy.json.in" "$d/peri.json" 0644 root:root "PERI_ORIGINS_JSON=$origins" "PERI_URL=$url"
    done
}

# ------------------------------------------------------------------------------------- per-mode config files
kiosk_xwrapper() {
    write_file /etc/X11/Xwrapper.config 0644 <<'EOF'
# Peri kiosk (installer): the X server is started by a systemd unit as user peri, not from a console login, so any user may
# start it; the Xorg wrapper (xserver-xorg-legacy) raises the privileges it needs (VT + DRM access).
allowed_users=anybody
needs_root_rights=yes
EOF
}

kiosk_labwc() {
    install_file "$PERI_SRC/scripts/data/labwc/rc.xml" /etc/peri/labwc/rc.xml 0644
    install_file "$PERI_SRC/scripts/data/labwc/environment" /etc/peri/labwc/environment 0644
    install_file "$PERI_SRC/scripts/data/labwc/autostart" /etc/peri/labwc/autostart 0755
}

kiosk_cli() {
    install_file "$PERI_SRC/scripts/peri-kiosk" /usr/local/bin/peri-kiosk 0755
}

# ------------------------------------------------------------------------------------------ desktop images
kiosk_desktop() {
    local dm="" d unit reboot=0 before
    if [[ $IS_DESKTOP -ne 1 && -z "$DM_ACTIVE" ]]; then
        info "kiosk: no display manager on this image (Lite): nothing to switch off; the kiosk unit takes tty1 from getty"
        return 0
    fi
    before=$(hw_changes)
    dm="$DM_ACTIVE"
    [[ -z "$DM_ACTIVE" ]] || reboot=1                       # a display manager is enabled right now: switching it off needs a reboot
    if [[ -z "$dm" ]]; then for d in lightdm gdm3 sddm lxdm slim; do pkg_installed "$d" && { dm="$d"; break; }; done; fi
    if [[ -n "$dm" ]]; then
        unit="${dm%.service}.service"
        info "kiosk: Desktop image: disabling the display manager $unit so that Peri owns tty1 and the display (undo: peri-kiosk disable)"
        service_disable "$unit"
    fi
    if [[ "$DEFAULT_TARGET" == graphical.target ]]; then
        info "kiosk: default target graphical.target -> multi-user.target (recorded in the manifest)"
        is_dry || manifest_add default-target graphical.target
        sysrun systemctl set-default multi-user.target
        reboot=1
    fi
    # a re-run on an already converted machine changes nothing and must not ask for a reboot again
    if [[ $reboot -eq 1 || $(hw_changes) -gt $before ]]; then
        need_reboot "display manager ${dm:-} disabled / default target changed: reboot to hand the display to the Peri kiosk"
    fi
}

kiosk_output_hint() {
    if [[ "$MODE" == cage && $DSI_CONNECTED -eq 1 ]] && hw_hdmi_connected && [[ "$(hw_opt01 "${PERI_OPT_DISABLE_HDMI:-0}" 0)" != 1 ]]; then
        warn "kiosk: an HDMI screen is connected together with the DSI panel: cage may show the UI on the HDMI screen. Re-run with --disable-hdmi (video=HDMI-A-1:d ...) to keep the UI on the panel"
    fi
}

main() {
    step "Kiosk: Chromium UI on the built-in display"
    detect_all
    if [[ $IS_PI -ne 1 ]]; then
        skip "kiosk setup: this machine is not a Raspberry Pi (model: ${PI_MODEL:-unknown}): refusing to install a kiosk or to switch off its display manager; nothing is changed"
        return 0
    fi
    kiosk_resolve_mode
    kiosk_packages || true
    kiosk_env
    kiosk_policy
    case "$MODE" in x11) kiosk_xwrapper ;; labwc) kiosk_labwc ;; esac
    kiosk_cli
    kiosk_desktop
    kiosk_output_hint
    info "kiosk: units peri-kiosk.service / peri-hwinit.service are installed by the services step; control the UI with  sudo peri-kiosk status|restart|logs|desktop"
    if [[ $FAILED -ne 0 ]]; then err "kiosk step FAILED (see the messages above)"; return 1; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi   # sourced by the tests: functions only
