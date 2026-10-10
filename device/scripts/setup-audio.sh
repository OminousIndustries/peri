#!/usr/bin/env bash
# setup-audio.sh - installer step "audio": Waveshare WM8960 audio HAT (2 MEMS mics, 2 speakers) + the audio server.
#
# Card (decided from what is actually present, see RESEARCH.md section 2):
#   * a WM8960 card is already registered (seeed-voicecard, Waveshare or the upstream overlay)  -> drivers, overlays and
#     config.txt are NOT touched (log only); mixer levels are applied by scripts/hw-init.sh (now, and at every boot)
#   * no card, the kernel ships overlays/wm8960-soundcard.dtbo (Bookworm/Trixie, updated Bullseye) -> managed block "peri:audio"
#     in config.txt: dtparam=i2c_arm=on, dtparam=i2s=on, dtoverlay=wm8960-soundcard (+ reboot)
#   * no card and no overlay/driver (old Bullseye kernel)                                       -> warn with the exact manual
#     instruction and exit 0. Deliberate: cloning/compiling kernel drivers (HinTak/seeed-voicecard, dkms) is kernel-specific,
#     slow and can leave a machine without sound after every kernel update, so it is never done automatically; audio may be
#     fixed later and this step is safe to re-run.
# dtparam=audio=off is deliberately NOT set: the WM8960 is chosen by NAME (asound.conf) or by priority + explicit default
# (WirePlumber drop-in, hw-init.sh), so the bcm2835 jack card does no harm, and editing a user's working line has no upside.
#
# Audio server (PERI_OPT_AUDIO_SERVER auto|pipewire|pulse|alsa):
#   auto     Bookworm/Trixie -> PipeWire (installed when missing); Bullseye -> keep what exists (PulseAudio, else plain ALSA)
#   pipewire refused on Bullseye (0.3.19 is too old) unless a newer PipeWire is already installed
#   pulse    keep/install PulseAudio (PipeWire's pipewire-pulse counts as a Pulse server)
#   alsa     no sound server: /etc/asound.conf (dmix/dsnoop on the card, addressed by name) - only when the file is absent or
#            was written by us; a symlink / vendor file (seeed-voicecard, wm8960-soundcard service) is NEVER replaced
# PipeWire: user units enabled globally (the linger user peri gets its own session), WirePlumber priority drop-in
# (0.4 Lua or 0.5 conf, chosen by the installed version, else by codename: bookworm=0.4, trixie=0.5).
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: setup-audio.sh [-h|--help]          (environment driven; run as root; DRY_RUN=1 shows a diff and changes nothing)

Environment:
  PERI_ROOT                fake-root prefix for tests (empty on a device)
  DRY_RUN=0|1              1 = print what would change, change nothing
  PERI_OPT_AUDIO_SERVER    auto (default) | pipewire | pulse | alsa
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
PERI_STEP=audio

ASOUND_MARK='Managed by the Peri installer (asound.conf for the WM8960 audio HAT)'
DEFAULT_CARD_ID=wm8960soundcard          # ALSA card id of the upstream overlay (simple-audio-card "wm8960-soundcard")
PW_PKGS=(pipewire pipewire-pulse wireplumber pipewire-alsa dbus-user-session)
AUDIO_MODE=""

# ------------------------------------------------------------------------------------------------ the card
audio_card() {
    local before body snap
    if [[ $WM8960_PRESENT -eq 1 ]]; then
        info "audio card: WM8960 present as card $WM8960_CARD_NUM [$WM8960_CARD_ID] (driver: $WM8960_DRIVER) - not touching drivers, overlays or config.txt"
        return 0
    fi
    if cfg_has_outside audio '^dtoverlay=(wm8960-soundcard|seeed-[0-9]mic-voicecard)'; then
        skip "audio card: a WM8960 overlay is configured in $CONFIG_TXT (not by Peri) but no card is registered yet: reboot pending, HAT not seated or I2C off"
        warn "  check: aplay -l ; dmesg | grep -i -E 'wm8960|seeed|i2s' ; i2cdetect -y 1   (the codec answers at 0x1a, or shows UU when bound)"
        return 0
    fi
    if [[ "$WM8960_DRIVER" == seeed || "$WM8960_DRIVER" == waveshare ]]; then
        warn "audio card: a vendor driver ($WM8960_DRIVER) is installed but no WM8960 card is registered - NOT reinstalling it"
        warn "  check: sudo systemctl status seeed-voicecard ; dkms status ; dmesg | grep -i -E 'wm8960|seeed' (a kernel update may need the driver rebuilt)"
        return 0
    fi
    if [[ ! -f "$(rp "$OVERLAYS_DIR/wm8960-soundcard.dtbo")" ]]; then
        warn "audio card: no WM8960 card and kernel $KERNEL has no wm8960-soundcard overlay ($OVERLAYS_DIR). The installer does NOT download or compile kernel drivers."
        warn "  install one yourself, then re-run this installer (it will find the card and leave the driver alone):"
        warn "   - recommended: re-flash Raspberry Pi OS Bookworm/Trixie (upstream overlay, nothing to install), or"
        warn "   - this kernel: git clone -b v6.1 https://github.com/HinTak/seeed-voicecard && cd seeed-voicecard && sudo ./install.sh && sudo reboot"
        return 0
    fi
    info "audio card: no card registered; the kernel ships the wm8960-soundcard overlay: configuring it in a managed block"
    before=$(hw_changes)
    snap=$(hw_snapshot "$CONFIG_TXT")
    body="[all]"$'\n'"# WM8960 Audio HAT (Waveshare): the kernel's own overlay, no driver install needed."$'\n'
    cfg_has_outside audio '^dtparam=(i2c_arm|i2c|i2c1)=on' || body+="dtparam=i2c_arm=on"$'\n'
    cfg_has_outside audio '^dtparam=i2s=on' || body+="dtparam=i2s=on"$'\n'
    body+="dtoverlay=wm8960-soundcard"
    set_managed_block "$CONFIG_TXT" audio <<< "$body"
    hw_config_guard_end "$snap" "$CONFIG_TXT" '^$' audio || return 1
    if [[ $(hw_changes) -gt $before ]]; then
        need_reboot "WM8960 audio overlay (dtoverlay=wm8960-soundcard) added to $CONFIG_TXT"
    else
        skip "audio block in $CONFIG_TXT already up to date"
    fi
}

# ----------------------------------------------------------------------------------------- audio server
audio_resolve_mode() {
    local want="${PERI_OPT_AUDIO_SERVER:-auto}" modern=0
    case "$want" in auto|pipewire|pulse|alsa) ;; *) warn "unknown PERI_OPT_AUDIO_SERVER='$want' - using auto"; want=auto ;; esac
    case "$OS_CODENAME" in bullseye|"") ;; *) modern=1 ;; esac      # bookworm, trixie and anything newer
    case "$want" in
        auto)
            if [[ "$AUDIO_SERVER" == pipewire || "$AUDIO_SERVER" == pulse ]]; then
                # never swap a working server: installing pipewire-pulse would silently REMOVE an installed pulseaudio
                AUDIO_MODE=$AUDIO_SERVER; info "audio server: auto -> keeping the installed $AUDIO_SERVER server$([[ $modern -eq 1 && "$AUDIO_SERVER" == pulse ]] && printf ' (use --audio-server pipewire to switch)')"
            elif [[ $modern -eq 1 ]]; then AUDIO_MODE=pipewire; info "audio server: auto -> PipeWire (the platform's audio server on ${OS_CODENAME}; none installed)"
            else AUDIO_MODE=alsa; info "audio server: auto -> plain ALSA (Bullseye has no usable PipeWire; none installed)"; fi ;;
        pipewire)
            if [[ $modern -eq 1 || "$AUDIO_SERVER" == pipewire ]]; then
                AUDIO_MODE=pipewire
                [[ "$AUDIO_SERVER" != pulse ]] || warn "audio server: pipewire-pulse replaces the installed pulseaudio (apt removes it)"
            else
                warn "audio server: PipeWire requested, but PipeWire in ${OS_CODENAME:-this OS} is too old (0.3.19): not installing it"
                if [[ "$AUDIO_SERVER" == pulse ]]; then AUDIO_MODE=pulse; else AUDIO_MODE=alsa; fi
            fi ;;
        pulse)
            if [[ "$AUDIO_SERVER" == pipewire ]]; then AUDIO_MODE=pipewire; info "audio server: pulse requested; PipeWire's pipewire-pulse already provides the PulseAudio protocol - using it"
            else AUDIO_MODE=pulse; fi ;;
        alsa) AUDIO_MODE=alsa ;;
    esac
    info "audio server: mode = $AUDIO_MODE (installed now: $AUDIO_SERVER${WP_VERSION:+, WirePlumber $WP_VERSION})"
}

# audio_wp_dropin : WirePlumber priority rule, syntax by version (0.4 Lua, 0.5+ conf); deleting the file is the recovery.
audio_wp_dropin() {
    local ver="${WP_VERSION:-}" flavour=""
    case "$ver" in 0.4*) flavour=lua ;; 0.[5-9]*|[1-9]*) flavour=conf ;; esac
    if [[ -z "$flavour" ]]; then
        case "$OS_CODENAME" in
            bookworm) flavour=lua; ver="unknown (assuming 0.4 for bookworm)" ;;
            trixie) flavour=conf; ver="unknown (assuming 0.5 for trixie)" ;;
            *) warn "audio: WirePlumber version unknown on '${OS_CODENAME:-?}': no priority drop-in written (hw-init.sh still sets the defaults at boot)"; return 0 ;;
        esac
    fi
    info "audio: WirePlumber $ver -> $flavour drop-in giving the WM8960 nodes priority 2500"
    if [[ "$flavour" == lua ]]; then
        install_file "$PERI_SRC/scripts/data/wireplumber/51-peri-wm8960.lua" /etc/wireplumber/main.lua.d/51-peri-wm8960.lua 0644
    else
        install_file "$PERI_SRC/scripts/data/wireplumber/51-peri-wm8960.conf" /etc/wireplumber/wireplumber.conf.d/51-peri-wm8960.conf 0644
    fi
    [[ $LAST_CHANGED -eq 0 ]] || info "audio: the drop-in is read when WirePlumber starts (next boot); recovery = delete the file"
}

audio_pipewire() {
    if [[ "$AUDIO_SERVER" != pipewire ]]; then
        info "audio server: PipeWire is not installed: installing ${PW_PKGS[*]}"
        if apt_install "${PW_PKGS[@]}"; then detect_audio; else warn "audio server: the PipeWire packages could not be installed (offline?): re-run later; plain ALSA is used until then"; fi
    else
        info "audio server: PipeWire is already installed - not reinstalling"
    fi
    # user units for every user, so the linger user 'peri' gets PipeWire/WirePlumber/pipewire-pulse without any login (harmless when already enabled)
    sysrun_soft systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
    audio_wp_dropin
}

audio_pulse() {
    if [[ "$AUDIO_SERVER" == pulse ]]; then info "audio server: PulseAudio is already installed - not reinstalling"
    else
        info "audio server: installing pulseaudio"
        apt_install pulseaudio || warn "audio server: pulseaudio could not be installed (offline?)"
    fi
    info "audio server: hw-init.sh makes the WM8960 the default PulseAudio sink/source at boot"
}

# asound_analyse FILE : read-only look at an ALSA config (comments ignored). Sets
#   ASOUND_EMPTY   1 when there is nothing but comments/blank lines
#   ASOUND_DMIX    1 when it defines a dmix device (playback can be shared: the browser needs several streams at once)
#   ASOUND_BYNUM   1 when the DEFAULT pcm is defined by card NUMBER (type hw/plug + `card 3`, or "hw:3,0" / "plughw:3")
#   ASOUND_HARDNUM 1 when a card number is hard-coded anywhere
# Card numbers move when HDMI/headphone cards come and go, so a by-number default silently breaks.
asound_analyse() {
    local f="$1" text block
    text=$(sed 's/#.*$//' "$f" | tr '[:upper:]' '[:lower:]')
    ASOUND_EMPTY=0; ASOUND_DMIX=0; ASOUND_BYNUM=0; ASOUND_HARDNUM=0
    [[ -n "${text//[[:space:]]/}" ]] || ASOUND_EMPTY=1
    if grep -Eq 'type[[:space:]]+dmix' <<< "$text"; then ASOUND_DMIX=1; fi
    if grep -Eq '(^|[^a-z0-9_])card[[:space:]]+[0-9]+|hw:[0-9]' <<< "$text"; then ASOUND_HARDNUM=1; fi
    block=$(awk '
        { s = s $0 "\n" }
        END {
            if (!match(s, /pcm\.!?default/)) exit
            i = RSTART + RLENGTH
            while (substr(s, i, 1) ~ /[ \t\n]/) i++
            if (substr(s, i, 1) == "{") {
                depth = 0
                for (j = i; j <= length(s); j++) {
                    ch = substr(s, j, 1)
                    if (ch == "{") depth++
                    else if (ch == "}") { depth--; if (depth == 0) break }
                }
                print substr(s, i, j - i + 1)
            } else {
                e = index(substr(s, i), "\n"); print substr(s, i, e ? e - 1 : length(s) - i + 1)
            }
        }' <<< "$text")
    if grep -Eq 'card[[:space:]]+[0-9]+|hw:[0-9]' <<< "$block"; then ASOUND_BYNUM=1; fi
    return 0
}

# audio_asound : ALSA-only defaults (no sound server). What may be written:
#   * /etc/asound.conf absent, or one WE wrote (first line = our marker)            -> (re)written from the template
#   * /etc/asound.conf is a symlink (vendor: seeed-voicecard / wm8960-soundcard re-link it at every boot)
#       - the file it points to already has dmix and a by-NAME default              -> left alone (the vendor default is fine)
#       - it has no dmix, or its default is a card NUMBER (the kit's software guide told users to put `type hw card 3` there)
#         -> the CONTENT of that target file (under /etc only) is rewritten with our by-name dmix/dsnoop config; the symlink
#            stays, the original is kept as FILE.peri-bak, uninstall restores it
#   * a plain file that is not ours: replaced only when it lacks dmix AND hard-codes a card number; any other custom file stays
# An empty/comment-only file is never judged (nothing to learn from it).
audio_asound() {
    local real target dest card why="" vendor=0
    real=$(rp /etc/asound.conf)
    [[ "$WM8960_DRIVER" == seeed || "$WM8960_DRIVER" == waveshare ]] && vendor=1
    card="${WM8960_CARD_ID:-}"
    if [[ -L "$real" ]]; then
        target=$(hw_resolve_link "$real"); dest=${target#"$PERI_ROOT"}
        if [[ ! -f "$target" ]]; then skip "asound.conf: /etc/asound.conf is a symlink to $dest which does not exist: leaving it (vendor service)"; return 0; fi
        if [[ "$dest" != /etc/* ]]; then skip "asound.conf: /etc/asound.conf -> $dest is outside /etc (package-owned?): never rewritten"; return 0; fi
        asound_analyse "$target"
        if [[ $ASOUND_EMPTY -eq 1 ]]; then skip "asound.conf: the vendor file $dest is empty: nothing to judge, leaving it"; return 0; fi
        if [[ $ASOUND_DMIX -eq 1 && $ASOUND_BYNUM -eq 0 ]]; then
            skip "asound.conf: /etc/asound.conf -> $dest already shares the card through dmix by name: relying on the vendor configuration"
            return 0
        fi
        [[ $ASOUND_DMIX -eq 0 ]] && why="has no dmix/dsnoop (the browser cannot play two streams at once: 'Device or resource busy')"
        [[ $ASOUND_BYNUM -eq 1 ]] && why="${why:+$why and }defaults to a card NUMBER (numbers move when HDMI/headphone cards change)"
        if [[ -z "$card" ]]; then skip "asound.conf: $dest $why, but the WM8960 card is not registered yet so its id is unknown: re-run after the reboot"; return 0; fi
        warn "asound.conf: /etc/asound.conf -> $dest $why: rewriting the CONTENT of $dest with the by-name dmix/dsnoop config for card '$card' (symlink kept, original saved as $dest.peri-bak)"
        render_to "$PERI_SRC/scripts/data/asound-wm8960.conf.in" "$dest" 0644 root:root "PERI_CARD_ID=$card"
        return 0
    fi
    if [[ $vendor -eq 1 ]]; then
        skip "asound.conf: the $WM8960_DRIVER driver manages /etc/asound.conf itself (its service re-links it at every boot) - relying on the vendor configuration"
        return 0
    fi
    card="${card:-$DEFAULT_CARD_ID}"
    if [[ -e "$real" ]] && ! grep -qF "$ASOUND_MARK" "$real"; then
        asound_analyse "$real"
        if [[ $ASOUND_EMPTY -eq 0 && $ASOUND_DMIX -eq 0 && $ASOUND_HARDNUM -eq 1 ]]; then
            warn "asound.conf: /etc/asound.conf has no dmix/dsnoop and hard-codes a card number: replacing it with the by-name config for card '$card' (original saved as /etc/asound.conf.peri-bak)"
        else
            skip "asound.conf: /etc/asound.conf exists, was not written by the Peri installer and is not a plain by-number config: leaving it alone"
            return 0
        fi
    fi
    info "asound.conf: writing the ALSA defaults for card '$card' (by name; dmix/dsnoop so the browser can play and record at once)"
    render_to "$PERI_SRC/scripts/data/asound-wm8960.conf.in" /etc/asound.conf 0644 root:root "PERI_CARD_ID=$card"
}

# audio_asound_cleanup : a Peri-generated ALSA-only config must not fight a sound server that is now in charge.
audio_asound_cleanup() {
    local real; real=$(rp /etc/asound.conf)
    [[ -f "$real" && ! -L "$real" ]] && grep -qF "$ASOUND_MARK" "$real" || return 0
    info "asound.conf: removing the Peri-generated ALSA-only /etc/asound.conf: the audio server is now $AUDIO_MODE"
    if is_dry; then _note_would /etc/asound.conf; else _note_change "removed /etc/asound.conf"; fi
    remove_created /etc/asound.conf
}

main() {
    step "Audio: WM8960 audio HAT and audio server"
    detect_all
    hw_require_pi "audio setup" || return 0
    info "audio state: WM8960 present=$WM8960_PRESENT card=${WM8960_CARD_ID:-none} driver=$WM8960_DRIVER config-overlay=${WM8960_CONFIG_OVERLAY:-none} i2c=$CFG_I2C_ON i2s=$CFG_I2S_ON server=$AUDIO_SERVER"

    apt_update_once
    apt_install alsa-utils || warn "alsa-utils (aplay/amixer) could not be installed: mixer setup and audio tests need it"

    audio_card
    audio_resolve_mode
    case "$AUDIO_MODE" in
        pipewire) audio_pipewire; audio_asound_cleanup ;;
        pulse)    audio_pulse; audio_asound_cleanup ;;
        alsa)     audio_asound ;;
    esac

    if [[ $WM8960_PRESENT -eq 1 ]]; then
        info "audio: applying the mixer levels now (peri-hwinit.service re-applies them at every boot)"
        sysrun_soft bash "$SCRIPT_DIR/hw-init.sh" --no-wait --no-defaults
    else
        info "audio: mixer levels are applied by peri-hwinit.service once the card exists (after the reboot)"
    fi
    info "audio: test with  sudo /opt/peri/scripts/audio-test.sh   (plays a tone, records 3 s, prints the microphone level)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi   # sourced by the tests: functions only
