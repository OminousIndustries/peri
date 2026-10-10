# shellcheck shell=bash
# hw-common.sh - install-time helpers shared by setup-display.sh, setup-audio.sh, setup-boot.sh and setup-kiosk.sh.
#
# SOURCE it after lib.sh and detect.sh (it uses rp, skip, info ... and CONFIG_TXT / IS_PI from detect_all).
# Runtime scripts (hw-init.sh, launch-*.sh, x11-session.sh, verify.sh, audio-test.sh, peri-kiosk) never source it:
# they must keep working when only /opt/peri/scripts is present.
#
#   hw_env_get FILE KEY [DEFAULT]   read KEY from an env-style file WITHOUT sourcing it (peri.env also holds the API key)
#   hw_opt01 VALUE DEFAULT          normalise an option to 0/1
#   hw_require_pi WHAT              log a skip reason and return 1 when this is not a Raspberry Pi with a config.txt
#   hw_can_choose_dsi_port          true on Pi 5 / Compute Modules (two DSI connectors)
#   hw_hdmi_connected               true when a DRM HDMI connector reports "connected"
#   hw_changes                      number of file changes recorded so far (write, or would in a dry run): compare before/after
#   cfg_block_present ID            is the "# >>> peri:ID >>>" block in config.txt?
#   cfg_outside_block ID            print config.txt without that block (what "someone else" configured)
#   cfg_has_outside ID ERE          true when an ACTIVE config.txt line outside the block matches the ERE
#   hw_snapshot FILE / hw_config_intact SNAP FILE [IGNORE_ERE [BLOCK_ID]] / hw_config_guard_end SNAP FILE IGNORE_ERE BLOCK_ID /
#   hw_restore SNAP FILE            safety net for boot files: no active line may disappear by accident, else put it back
#   hw_resolve_link PATH            follow symlinks the way the target system would (fake-root aware)
#
# Why the "outside the block" helpers exist: detect.sh looks at the whole file, so once our own managed block contains
# `dtoverlay=vc4-kms-v3d` (added because it was missing) the next run would conclude "already configured by someone
# else", drop the line from the block and flip-flop. Deciding on the content OUTSIDE our block keeps every step
# idempotent.

# hw_env_get FILE KEY [DEFAULT] : last active `KEY=value` assignment; surrounding quotes stripped; DEFAULT when absent/empty.
hw_env_get() {
    local file="$1" real key="$2" def="${3:-}" val
    real=$(rp "$file")
    if [[ ! -r "$real" ]]; then printf '%s' "$def"; return 0; fi
    val=$(awk -v k="$key" '
        { line = $0; sub(/^[ \t]+/, "", line) }
        substr(line, 1, 1) == "#" { next }
        index(line, k "=") == 1 { v = substr(line, length(k) + 2); found = 1 }
        END { if (found) print v }' "$real" | tail -n 1)
    val=${val%$'\r'}
    val=${val%"${val##*[![:space:]]}"}          # trailing whitespace
    val=${val#"${val%%[![:space:]]*}"}          # leading whitespace
    case "$val" in
        \"*\") val=${val#\"}; val=${val%\"} ;;
        \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    if [[ -n "$val" ]]; then printf '%s' "$val"; else printf '%s' "$def"; fi
    return 0
}

# hw_opt01 VALUE DEFAULT : "1|true|yes|on" -> 1, "0|false|no|off" -> 0, anything else -> DEFAULT
hw_opt01() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) printf '1' ;;
        0|false|FALSE|no|NO|off|OFF) printf '0' ;;
        *) printf '%s' "${2:-0}" ;;
    esac
}

# hw_require_pi WHAT : the boot files only exist on a Pi; on any other machine every hardware step is a logged no-op.
hw_require_pi() {
    if [[ "${IS_PI:-0}" -ne 1 ]]; then
        skip "$1: this machine is not a Raspberry Pi (model: ${PI_MODEL:-unknown}); nothing to configure and nothing is changed"
        return 1
    fi
    if [[ ! -f "$(rp "$CONFIG_TXT")" ]]; then
        skip "$1: $CONFIG_TXT not found (unusual Raspberry Pi image); nothing is changed"
        return 1
    fi
    return 0
}

hw_can_choose_dsi_port() {
    [[ "${PI_GEN:-}" == 5 || "${PI_MODEL:-}" == *"Compute Module"* ]]
}

hw_hdmi_connected() {
    local d
    for d in "$(rp /sys/class/drm)"/card*-HDMI-A-*; do
        [[ -d "$d" ]] || continue
        [[ "$(head -n1 "$d/status" 2>/dev/null || true)" == connected ]] && return 0
    done
    return 1
}

cfg_block_present() {
    local f; f=$(rp "$CONFIG_TXT")
    [[ -f "$f" ]] && grep -qxF "# >>> peri:$1 >>>" "$f"
}

cfg_outside_block() {
    local f; f=$(rp "$CONFIG_TXT")
    [[ -f "$f" ]] || return 0
    awk -v s="# >>> peri:$1 >>>" -v e="# <<< peri:$1 <<<" '
        $0 == s { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }' "$f"
}

# cfg_has_outside ID ERE : (a here-string instead of a pipe so `grep -q` cannot SIGPIPE the producer under pipefail)
cfg_has_outside() {
    local content
    content=$(cfg_outside_block "$1" | grep -Ev '^[[:space:]]*(#|$)' || true)
    grep -Eq -- "$2" <<< "$content"
}

# hw_changes : number of file changes recorded so far (real, or "would" in dry-run) - compare before/after to decide
# whether a step really changed something (need_reboot only then).
hw_changes() { if is_dry; then changes_count would; else changes_count write; fi; }

# ------------------------------------------------------------------------------------- safety net for boot files
# hw_snapshot TARGET : copy the current file to a temp file and print its path (empty when the file does not exist).
hw_snapshot() {
    local real tmp; real=$(rp "$1")
    [[ -f "$real" ]] || return 0
    tmp=$(mktemp); cp -p "$real" "$tmp"; printf '%s' "$tmp"
}

# hw_config_intact SNAPSHOT TARGET [IGNORE_ERE [BLOCK_ID]] : every ACTIVE line of the snapshot (except lines matching
# IGNORE_ERE, and except the lines inside the Peri block BLOCK_ID - the step rewrites those on purpose) must still be an
# active line of TARGET. A cheap guard against a helper bug leaving config.txt without a line it had (the display overlay,
# say): the Pi would boot without a picture.
hw_config_intact() {
    local snap="$1" real ignore="${3:-^\$}" block="${4:-}" line missing=0
    real=$(rp "$2")
    [[ -n "$snap" && -f "$snap" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ $ignore ]] && continue
        if ! grep -qxF -- "$line" "$real"; then err "$2 integrity check: the line '$line' was lost"; missing=1; fi
    done < <(awk -v id="$block" '
            id != "" && $0 == "# >>> peri:" id " >>>" { skip = 1; next }
            id != "" && $0 == "# <<< peri:" id " <<<" { skip = 0; next }
            !skip { print }' "$snap" | grep -Ev '^[[:space:]]*(#|$)' || true)
    return "$missing"
}

# hw_config_guard_end SNAPSHOT TARGET IGNORE_ERE BLOCK_ID : run the integrity check; on failure put the snapshot back and
# return 1. Always removes the snapshot file.
hw_config_guard_end() {
    local snap="$1" rc=0
    hw_config_intact "$snap" "$2" "$3" "${4:-}" || rc=1
    if [[ $rc -ne 0 ]]; then
        hw_restore "$snap" "$2" || true
        err "$2 failed the integrity check after the edit: restored to its previous content"
    fi
    rm -f "$snap"
    return "$rc"
}

# hw_restore SNAPSHOT TARGET : put the pre-run content back (byte for byte, same mode).
hw_restore() {
    local snap="$1" real; real=$(rp "$2")
    [[ -n "$snap" && -f "$snap" ]] || { err "no snapshot of $2 to restore from (see $2.peri-bak)"; return 1; }
    cp -p "$snap" "$real" && warn "restored $2 to its state before this step (the original is also in $2.peri-bak)"
}

# hw_resolve_link REALPATH : follow symlinks the way the TARGET system would (an absolute link target is taken relative to
# PERI_ROOT, so this also works in a fake root), at most 10 hops. Prints the final path (still under PERI_ROOT).
hw_resolve_link() {
    local cur="$1" t n=0
    while [[ -L "$cur" && $n -lt 10 ]]; do
        t=$(readlink "$cur")
        case "$t" in /*) cur=$(rp "$t") ;; *) cur="$(dirname "$cur")/$t" ;; esac
        n=$((n + 1))
    done
    printf '%s' "$cur"
}
