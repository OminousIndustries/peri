# shellcheck shell=bash
# shellcheck disable=SC2034  # this file exists to set variables consumed by the scripts that source it
# detect.sh - OS / hardware / current-state detection for the Peri installer. SOURCE it after lib.sh.
#
#   detect_all            run every detect_* function below (cheap; steps may call it again after changing the system)
#   print_detection       log a summary table
#
# File probes go through rp() (fake-root aware); command probes use PATH (tests can shadow commands with
# $PERI_ROOT/mockbin/*). Every variable is always set (empty string / 0 when unknown) so callers may use `set -u`.
#
# Variables set (grouped):
#   OS_ID OS_VERSION_ID OS_CODENAME OS_PRETTY OS_LIKE OS_SUPPORTED(0/1: bullseye|bookworm|trixie)
#   ARCH DPKG_ARCH BITS KERNEL KERNEL_MAJMIN MEM_MB PI_MODEL IS_PI PI_GEN(3|4|5|zero|zero2|other|"")
#   BOOT_DIR CONFIG_TXT CMDLINE_TXT OVERLAYS_DIR (target paths, without PERI_ROOT)
#   IS_DESKTOP DM_ACTIVE DEFAULT_TARGET HAVE_CAGE HAVE_LABWC HAVE_WAYFIRE HAVE_XORG
#   AUDIO_SERVER(pipewire|pulse|alsa|none) WP_VERSION WM8960_PRESENT WM8960_CARD_ID WM8960_CARD_NUM WM8960_DRIVER
#   (upstream|seeed|waveshare|none) WM8960_CONFIG_OVERLAY CFG_I2C_ON CFG_I2S_ON
#   KMS_OVERLAY(vc4-kms-v3d|vc4-fkms-v3d|"") DSI_CONNECTOR DSI_CONNECTED DSI_MODE DSI_CONFIGURED(upstream|waveshare-legacy|"")
#   DSI_UPSTREAM_SUPPORTED TOUCH_PRESENT
#   PY_VERSION PY_OK PY_HAS_AIOHTTP PY_HAS_SERIAL PY_HAS_GPIOZERO
#   CHROMIUM_PKG CHROMIUM_CANDIDATE CHROMIUM_BIN HAVE_INTERNET

# ------------------------------------------------------------------------------------------- helpers

_first_line() { [[ -r "$1" ]] && head -n1 "$1" 2>/dev/null | tr -d '\0'; return 0; }

# cfg_active_lines : the non-comment, non-empty lines of config.txt (empty output when missing).
cfg_active_lines() {
    local f; f=$(rp "${CONFIG_TXT:-/boot/firmware/config.txt}")
    [[ -r "$f" ]] && grep -Ev '^[[:space:]]*(#|$)' "$f"
    return 0
}
# cfg_has REGEX : true when an active config.txt line matches the ERE (anchored at line start by the caller if wanted).
cfg_has() { cfg_active_lines | grep -Eq -- "$1"; }

# _component CMD PKG : is a component installed? On a real system: the command exists or the package is installed. In
# fake-root mode only PERI_FAKE_PKGS counts, so results do not depend on the machine running the tests.
_component() {
    if is_fakeroot; then pkg_installed "$2"; else have "$1" || pkg_installed "$2"; fi
}

# dtbo_has_param DTBO PARAM : does the (binary) overlay file mention the parameter name? (`grep -a` works on dtbo)
dtbo_has_param() { local f; f=$(rp "$1"); [[ -r "$f" ]] && grep -aq -- "$2" "$f"; }

# ------------------------------------------------------------------------------------------------- OS

detect_os() {
    OS_ID=""; OS_VERSION_ID=""; OS_CODENAME=""; OS_PRETTY=""; OS_LIKE=""; OS_SUPPORTED=0
    local f; f=$(rp /etc/os-release)
    if [[ -r "$f" ]]; then
        # shellcheck disable=SC1090
        eval "$( ( . "$f" 2>/dev/null; printf 'OS_ID=%q OS_VERSION_ID=%q OS_CODENAME=%q OS_PRETTY=%q OS_LIKE=%q\n' \
            "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" "${PRETTY_NAME:-}" "${ID_LIKE:-}" ) )"
        if [[ -z "$OS_CODENAME" ]]; then
            OS_CODENAME=$(sed -n 's/^VERSION="[^(]*(\([a-z]*\)).*/\1/p' "$f" | head -n1)
        fi
    fi
    case "$OS_CODENAME" in bullseye|bookworm|trixie) OS_SUPPORTED=1 ;; esac
}

detect_hw() {
    ARCH=$(uname -m 2>/dev/null || echo unknown)
    DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "$ARCH")
    BITS=$(getconf LONG_BIT 2>/dev/null || echo 0)
    KERNEL=$(uname -r 2>/dev/null || echo unknown)
    KERNEL_MAJMIN=$(printf '%s' "$KERNEL" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p')
    MEM_MB=0
    if [[ -r $(rp /proc/meminfo) ]]; then
        MEM_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' "$(rp /proc/meminfo)")
    fi
    PI_MODEL=$(_first_line "$(rp /proc/device-tree/model)")
    [[ -z "$PI_MODEL" ]] && PI_MODEL=$(_first_line "$(rp /sys/firmware/devicetree/base/model)")
    IS_PI=0; PI_GEN=""
    if [[ "$PI_MODEL" == "Raspberry Pi"* ]]; then
        IS_PI=1
        case "$PI_MODEL" in
            *"Pi 5"*|*"Compute Module 5"*) PI_GEN=5 ;;          # includes Pi 500
            *"Pi 4"*|*"Compute Module 4"*) PI_GEN=4 ;;          # includes Pi 400
            *"Pi 3"*|*"Compute Module 3"*) PI_GEN=3 ;;
            *"Zero 2"*) PI_GEN=zero2 ;;
            *"Zero"*) PI_GEN=zero ;;
            *) PI_GEN=other ;;
        esac
    fi
}

detect_boot() {
    if [[ -f $(rp /boot/firmware/config.txt) ]]; then BOOT_DIR=/boot/firmware; else BOOT_DIR=/boot; fi
    CONFIG_TXT="$BOOT_DIR/config.txt"; CMDLINE_TXT="$BOOT_DIR/cmdline.txt"; OVERLAYS_DIR="$BOOT_DIR/overlays"
}

# ---------------------------------------------------------------------------------- desktop / kiosk

detect_desktop() {
    IS_DESKTOP=0; DM_ACTIVE=""; DEFAULT_TARGET=""; HAVE_CAGE=0; HAVE_LABWC=0; HAVE_WAYFIRE=0; HAVE_XORG=0
    if pkg_installed raspberrypi-ui-mods || pkg_installed lightdm || pkg_installed task-desktop || pkg_installed gdm3; then
        IS_DESKTOP=1
    fi
    local dm; dm=$(rp /etc/systemd/system/display-manager.service)
    if [[ -L "$dm" ]]; then DM_ACTIVE=$(basename "$(readlink "$dm")" .service); fi
    if is_fakeroot; then
        local dt; dt=$(rp /etc/systemd/system/default.target)
        [[ -L "$dt" ]] && DEFAULT_TARGET=$(basename "$(readlink "$dt")")
    else
        DEFAULT_TARGET=$(systemctl get-default 2>/dev/null || true)
    fi
    _component cage cage && HAVE_CAGE=1
    _component labwc labwc && HAVE_LABWC=1
    _component wayfire wayfire && HAVE_WAYFIRE=1
    _component Xorg xserver-xorg && HAVE_XORG=1
    return 0
}

# ----------------------------------------------------------------------------------------- audio

# _parse_asound_cards : print "NUM ID DESCRIPTION" per ALSA card (from /proc/asound/cards, else `aplay -l`).
_parse_asound_cards() {
    local f; f=$(rp /proc/asound/cards)
    if [[ -r "$f" ]]; then
        sed -n 's/^[[:space:]]*\([0-9][0-9]*\) \[\([^]]*\)[[:space:]]*\]: \(.*\)$/\1 \2 \3/p' "$f"
    elif have aplay; then
        aplay -l 2>/dev/null | sed -n 's/^card \([0-9][0-9]*\): \([^ ]*\) \[\([^]]*\)\].*$/\1 \2 \3/p'
    fi
    return 0
}

detect_audio() {
    AUDIO_SERVER="none"; WP_VERSION=""; WM8960_PRESENT=0; WM8960_CARD_ID=""; WM8960_CARD_NUM=""
    WM8960_DRIVER="none"; WM8960_CONFIG_OVERLAY=""; CFG_I2C_ON=0; CFG_I2S_ON=0
    if _component pipewire pipewire && { _component wireplumber wireplumber || _component pipewire-media-session pipewire-media-session; }; then
        AUDIO_SERVER=pipewire
    elif _component pulseaudio pulseaudio; then
        AUDIO_SERVER=pulse
    elif _component aplay alsa-utils; then
        AUDIO_SERVER=alsa
    fi
    if is_fakeroot; then
        WP_VERSION="${PERI_FAKE_WP_VERSION:-}"
    elif have wireplumber; then
        WP_VERSION=$(wireplumber --version 2>/dev/null | sed -n 's/.*libwireplumber \([0-9][0-9.]*\).*/\1/p' | head -n1)
    fi
    local num id desc
    while read -r num id desc; do
        [[ -z "${num:-}" ]] && continue
        if [[ "$id $desc" =~ [Ww][Mm]8960|[Ss]eeed|[Vv]oicecard ]]; then
            WM8960_PRESENT=1; WM8960_CARD_ID="$id"; WM8960_CARD_NUM="$num"; break
        fi
    done < <(_parse_asound_cards)
    if cfg_has '^dtoverlay=seeed-[0-9]mic-voicecard'; then WM8960_CONFIG_OVERLAY=seeed
    elif cfg_has '^dtoverlay=wm8960-soundcard'; then WM8960_CONFIG_OVERLAY=wm8960-soundcard; fi
    cfg_has '^dtparam=i2c_arm=on' && CFG_I2C_ON=1
    cfg_has '^dtparam=i2s=on' && CFG_I2S_ON=1
    if [[ -d $(rp /etc/voicecard) || -e $(rp /usr/bin/seeed-voicecard) || "$WM8960_CARD_ID" == *[Ss]eeed* || "$WM8960_CONFIG_OVERLAY" == seeed ]]; then
        WM8960_DRIVER=seeed
    elif [[ -d $(rp /etc/wm8960-soundcard) || -e $(rp /usr/bin/wm8960-soundcard) ]]; then
        WM8960_DRIVER=waveshare
    elif [[ "$WM8960_CONFIG_OVERLAY" == wm8960-soundcard || $WM8960_PRESENT -eq 1 ]]; then
        WM8960_DRIVER=upstream
    fi
    return 0
}

# ---------------------------------------------------------------------------------------- display

detect_display() {
    KMS_OVERLAY=""; DSI_CONNECTOR=""; DSI_CONNECTED=0; DSI_MODE=""; DSI_CONFIGURED=""; DSI_UPSTREAM_SUPPORTED=0
    TOUCH_PRESENT=0
    if cfg_has '^dtoverlay=vc4-kms-v3d'; then KMS_OVERLAY=vc4-kms-v3d
    elif cfg_has '^dtoverlay=vc4-fkms-v3d'; then KMS_OVERLAY=vc4-fkms-v3d; fi
    if cfg_has '^dtoverlay=vc4-kms-dsi-waveshare-panel'; then DSI_CONFIGURED=upstream
    elif cfg_has '^dtoverlay=WS_xinchDSI_Screen'; then DSI_CONFIGURED=waveshare-legacy; fi
    if dtbo_has_param "${OVERLAYS_DIR:-/boot/firmware/overlays}/vc4-kms-dsi-waveshare-panel.dtbo" '4_0_inchC'; then
        DSI_UPSTREAM_SUPPORTED=1
    fi
    local d name st
    for d in "$(rp /sys/class/drm)"/card*-DSI-*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d"); name=${name#card*-}
        st=$(_first_line "$d/status")
        DSI_CONNECTOR="$name"
        if [[ "$st" == connected ]]; then
            DSI_CONNECTED=1; DSI_MODE=$(_first_line "$d/modes"); break
        fi
    done
    if [[ -r $(rp /proc/bus/input/devices) ]] && grep -qiE 'goodix|touchscreen|ft5406|waveshare' "$(rp /proc/bus/input/devices)"; then
        TOUCH_PRESENT=1
    fi
    return 0
}

# -------------------------------------------------------------------------------- software stack

detect_python() {
    PY_VERSION=""; PY_OK=0; PY_HAS_AIOHTTP=0; PY_HAS_SERIAL=0; PY_HAS_GPIOZERO=0
    have python3 || return 0
    PY_VERSION=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null && PY_OK=1
    python3 -c 'import aiohttp' 2>/dev/null && PY_HAS_AIOHTTP=1
    python3 -c 'import serial' 2>/dev/null && PY_HAS_SERIAL=1
    python3 -c 'import gpiozero' 2>/dev/null && PY_HAS_GPIOZERO=1
    return 0
}

detect_chromium() {
    CHROMIUM_PKG=""; CHROMIUM_CANDIDATE=""; CHROMIUM_BIN=""
    if pkg_installed chromium; then CHROMIUM_PKG=chromium
    elif pkg_installed chromium-browser; then CHROMIUM_PKG=chromium-browser; fi
    if pkg_available chromium; then CHROMIUM_CANDIDATE=chromium
    elif pkg_available chromium-browser; then CHROMIUM_CANDIDATE=chromium-browser; fi
    if is_fakeroot; then
        [[ -n "$CHROMIUM_PKG" ]] && CHROMIUM_BIN="/usr/bin/$CHROMIUM_PKG"
    elif have chromium; then CHROMIUM_BIN=$(command -v chromium)
    elif have chromium-browser; then CHROMIUM_BIN=$(command -v chromium-browser); fi
    return 0
}

detect_net() {
    HAVE_INTERNET=0
    if is_fakeroot || is_dry; then HAVE_INTERNET=1; return 0; fi
    if have curl && curl -fsS -m 6 -o /dev/null -I https://deb.debian.org 2>/dev/null; then HAVE_INTERNET=1
    elif have wget && wget -q -T 6 --spider https://deb.debian.org 2>/dev/null; then HAVE_INTERNET=1; fi
    return 0
}

detect_all() {
    detect_os; detect_hw; detect_boot; detect_desktop; detect_audio; detect_display
    detect_python; detect_chromium; detect_net
}

print_detection() {
    local kv
    step "Detected system"
    for kv in \
        "OS=${OS_PRETTY:-unknown} (codename ${OS_CODENAME:-?}, supported=$OS_SUPPORTED)" \
        "Machine=${PI_MODEL:-not a Raspberry Pi} / $ARCH userland ${BITS}-bit / kernel $KERNEL / ${MEM_MB} MB RAM" \
        "Boot files=$CONFIG_TXT , $CMDLINE_TXT" \
        "Image type=$([[ $IS_DESKTOP -eq 1 ]] && echo Desktop || echo Lite) (display manager: ${DM_ACTIVE:-none}, default target: ${DEFAULT_TARGET:-?})" \
        "Compositors=cage:$HAVE_CAGE labwc:$HAVE_LABWC wayfire:$HAVE_WAYFIRE xorg:$HAVE_XORG" \
        "Audio server=$AUDIO_SERVER ${WP_VERSION:+(wireplumber $WP_VERSION)}" \
        "WM8960 card=$([[ $WM8960_PRESENT -eq 1 ]] && echo "present: card $WM8960_CARD_NUM [$WM8960_CARD_ID]" || echo absent) driver=$WM8960_DRIVER config-overlay=${WM8960_CONFIG_OVERLAY:-none}" \
        "Display=KMS overlay:${KMS_OVERLAY:-none} dsi-configured:${DSI_CONFIGURED:-no} dsi-connected:$DSI_CONNECTED ${DSI_MODE:+mode $DSI_MODE} upstream-4_0_inchC:$DSI_UPSTREAM_SUPPORTED touch:$TOUCH_PRESENT" \
        "Python=${PY_VERSION:-none} ok:$PY_OK aiohttp:$PY_HAS_AIOHTTP pyserial:$PY_HAS_SERIAL gpiozero:$PY_HAS_GPIOZERO" \
        "Chromium=installed:${CHROMIUM_PKG:-no} candidate:${CHROMIUM_CANDIDATE:-none} bin:${CHROMIUM_BIN:-none}" \
        "Internet=$HAVE_INTERNET"; do
        info "$kv"
    done
}
