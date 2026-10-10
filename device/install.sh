#!/usr/bin/env bash
# install.sh - Peri device installer (orchestrator).
#
#   sudo ./install.sh --yes                 full unattended install (Raspberry Pi OS Bullseye/Bookworm/Trixie, 64-bit)
#   sudo ./install.sh --yes --only app,services   update path: re-run from a fresh copy of this folder
#   ./install.sh --dry-run                  show everything that would happen, change nothing
#   ./install.sh --help                     all options
#
# It runs the steps in this order, each as its own script (so a step can also be run alone, e.g.
# `sudo scripts/setup-display.sh`): packages, app, serial, display, audio, kiosk, boot, services.
# Every step is idempotent: running the installer again changes nothing that is already right.
if [ -z "${BASH_VERSION:-}" ]; then echo "install.sh must be run with bash:  sudo bash ./install.sh --yes" >&2; exit 2; fi
set -Eeuo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
PERI_SRC=$(dirname "$SELF")
export LC_ALL=C
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"      # useradd, udevadm, visudo ... are not in the PATH of a plain `su`

STEP_NAMES=(packages app serial display audio kiosk boot services)
STEP_SCRIPTS=(setup-packages.sh install-app.sh setup-serial.sh setup-display.sh setup-audio.sh setup-kiosk.sh setup-boot.sh setup-services.sh)
STEP_DESCS=(
    "generic runtime packages (python3, aiohttp, pyserial, gpiozero, curl, rsync, sudo, alsa-utils ...)"
    "service user 'peri', /opt/peri, /etc/peri/peri.env, peri-config"
    "USB-serial head: udev rule, removes brltty"
    "Waveshare 4-inch round DSI panel (config.txt overlay) and touch"
    "WM8960 audio HAT: overlay, sound server, mixer levels"
    "Chromium kiosk (cage / X11 / labwc) and the display-manager hand-over"
    "quiet boot and splash screen (cosmetic)"
    "systemd units, sudoers, enable and start the services"
)

VERSION=$(cat "$PERI_SRC/VERSION" 2>/dev/null || echo unknown)

usage() {
    cat <<EOF
Peri device installer $VERSION

USAGE
  sudo ./install.sh [options]          (or: sudo bash ./install.sh [options], e.g. when the folder was copied without the
                                        execute bit or lives on a noexec mount)

BASIC OPTIONS
  -y, --yes                 do not ask for confirmation (required when there is no terminal)
      --dry-run             change NOTHING (not even the log file): print what each step would do, with diffs
      --only a,b            run only these steps         (names: ${STEP_NAMES[*]})
      --skip a,b            run everything except these steps
      --list-steps          list the steps in run order and exit
      --reboot              when a reboot is required at the end and no step failed, reboot automatically after 10 s
  -h, --help                this text
      --version             print the version and exit

CHOICES (all default to auto/detected; the value is passed to the steps as PERI_OPT_*)
      --kiosk auto|cage|x11|labwc            browser kiosk flavour (auto: cage on Bookworm/Trixie, X11 on Bullseye)
      --audio-server auto|pipewire|pulse|alsa
      --dsi-port 0|1                         which DSI connector on Pi 5 / CM4 (default 1; Pi 3/4 have one)
      --dsi-i2c 0|1                          1 = panel touch wired to GPIO2/3 with the jumper cable (overlay parameter i2c1)
      --disable-hdmi                         keep HDMI off so the UI cannot land on a monitor instead of the round panel
      --splash-rotate 0|90|180|270           rotate the boot splash (the UI itself rotates in CSS)
      --no-splash                            no boot splash / no quiet-boot changes
      --head auto|serial|gpio|sim|none       neck driver: written to PERI_HEAD_DRIVER when not auto
      --start-kiosk auto|0|1                 start the kiosk right after installing: auto = when no reboot is pending and no
                                             desktop session owns the display; 1 = even with a pending reboot; 0 = never
      --openai-key KEY                       store the OpenAI API key in /etc/peri/peri.env (never printed or logged by the
                                             installer; NOTE a command-line argument is visible in 'ps' and sudo writes it to
                                             its own log - prefer the next option, or set it afterwards:
                                             echo 'sk-...' | sudo peri-config set OPENAI_API_KEY -)
      --openai-key-from-env                  take the key from the environment variable OPENAI_API_KEY (it is NOT used
                                             otherwise); keep the variable through sudo: sudo -E ./install.sh ...
      --force                                go on although a preflight check fails (not a Raspberry Pi, low disk space)

COMMON RUNS
  sudo ./install.sh --yes                                  full unattended install
  ./install.sh --dry-run                                   preview: what would change, with diffs (nothing is changed)
  sudo ./install.sh --yes --only app,services              UPDATE the software from a fresh copy of this folder
  sudo ./install.sh --yes --only kiosk                     re-run a single step (also: sudo scripts/setup-kiosk.sh)
  sudo ./install.sh --yes --head none                      standard enclosure: no Pi-connected motor
  sudo ./uninstall.sh --yes                                undo everything (settings and API key are kept; see --help there)

WHAT HAPPENS
  1. preflight: OS, 64-bit, Raspberry Pi model, python >= 3.9, free disk (1.5 GB when packages are installed), network,
     clock; prints what it detected and the plan, asks for confirmation unless --yes.
  2. the steps, each timed; a failing step does not stop the others.
  3. a summary: per-step PASS/FAIL/SKIP, number of changes, warnings, and either *** REBOOT REQUIRED *** with the exact
     next commands or the command to verify now.
  Everything is logged to /var/log/peri-install.log. /etc/peri/peri.env is never overwritten. Everything the installer
  changed is recorded in /var/lib/peri-install/manifest; edited files keep a FILE.peri-bak copy: sudo ./uninstall.sh
  restores the machine.

EXIT CODES
  0  all selected steps succeeded (a reboot may still be required: see the banner)
  1  at least one step FAILED (listed at the end; re-run just that step with --only NAME after fixing the cause)
  2  usage error, refused by preflight, or not confirmed (nothing was changed)

ENVIRONMENT (for tests and special cases)
  PERI_ROOT=DIR   work on a scratch root instead of the live system (files really change under DIR, commands are only logged)
  DRY_RUN=1       same as --dry-run          ASSUME_YES=1   same as --yes
  PERI_MIN_FREE_MB=N / PERI_MIN_BOOT_FREE_MB=N   override the free-space thresholds of the preflight check

UNATTENDED USE OVER SSH
  A dropped SSH session kills a foreground install in the middle of apt. Run it detached and follow the log:
    nohup sudo ./install.sh --yes >/tmp/peri-install.out 2>&1 &     then:   tail -f /var/log/peri-install.log
  The installer can safely be run again after an interruption.
EOF
}

usage_error() { printf 'install.sh: %s\nTry: ./install.sh --help\n' "$1" >&2; exit 2; }

# ------------------------------------------------------------------------------------------ arguments

ORIG_ARGS=("$@")
SAFE_ARGS=()                     # the arguments as they may appear in the log: the key value is replaced
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
ONLY=""; SKIP=""; LIST_STEPS=0; DO_REBOOT=0; FORCE=0
OPT_KIOSK=auto; OPT_AUDIO_SERVER=auto; OPT_DSI_PORT=1; OPT_DSI_I2C=0; OPT_DISABLE_HDMI=0
OPT_SPLASH_ROTATE=0; OPT_NO_SPLASH=0; OPT_HEAD=auto; OPT_START_KIOSK=auto
OPENAI_KEY="${PERI_OPT_OPENAI_KEY:-}"          # honoured (documented internal contract); OPENAI_API_KEY is NOT read implicitly
KEY_FROM_ENV=0
unset PERI_OPT_OPENAI_KEY

while [[ $# -gt 0 ]]; do
    OPT="$1"; VAL=""; HAVE_VAL=0; shift
    if [[ "$OPT" == --*=* ]]; then VAL="${OPT#*=}"; OPT="${OPT%%=*}"; HAVE_VAL=1; fi
    case "$OPT" in
        --only|--skip|--kiosk|--audio-server|--dsi-port|--dsi-i2c|--splash-rotate|--head|--start-kiosk|--openai-key)
            if [[ $HAVE_VAL -eq 0 ]]; then
                [[ $# -gt 0 ]] || usage_error "option $OPT needs a value"
                VAL="$1"; shift
            fi ;;
        -y|--yes|--dry-run|--list-steps|--reboot|--force|--disable-hdmi|--no-splash|--openai-key-from-env|-h|--help|--version)
            [[ $HAVE_VAL -eq 0 ]] || usage_error "option $OPT does not take a value" ;;
        *) usage_error "unknown option: $OPT" ;;
    esac
    case "$OPT" in
        -h|--help) usage; exit 0 ;;
        --version) echo "peri-install $VERSION"; exit 0 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --list-steps) LIST_STEPS=1 ;;
        --reboot) DO_REBOOT=1 ;;
        --force) FORCE=1 ;;
        --disable-hdmi) OPT_DISABLE_HDMI=1 ;;
        --no-splash) OPT_NO_SPLASH=1 ;;
        --openai-key-from-env) KEY_FROM_ENV=1 ;;
        --only) ONLY="$VAL" ;;
        --skip) SKIP="$VAL" ;;
        --kiosk) OPT_KIOSK="$VAL" ;;
        --audio-server) OPT_AUDIO_SERVER="$VAL" ;;
        --dsi-port) OPT_DSI_PORT="$VAL" ;;
        --dsi-i2c) OPT_DSI_I2C="$VAL" ;;
        --splash-rotate) OPT_SPLASH_ROTATE="$VAL" ;;
        --head) OPT_HEAD="$VAL" ;;
        --start-kiosk) OPT_START_KIOSK="$VAL" ;;
        --openai-key) [[ -n "$VAL" ]] || usage_error "--openai-key needs a non-empty value"; OPENAI_KEY="$VAL" ;;
    esac
    if [[ "$OPT" == --openai-key ]]; then SAFE_ARGS+=("--openai-key" "***"); else SAFE_ARGS+=("$OPT"); [[ -n "$VAL" ]] && SAFE_ARGS+=("$VAL"); fi
done

# ----------------------------------------------------------------------------------- validate choices

is_one_of() { local v="$1"; shift; local x; for x in "$@"; do [[ "$v" == "$x" ]] && return 0; done; return 1; }
is_one_of "$OPT_KIOSK" auto cage x11 labwc              || usage_error "--kiosk must be auto, cage, x11 or labwc"
is_one_of "$OPT_AUDIO_SERVER" auto pipewire pulse alsa  || usage_error "--audio-server must be auto, pipewire, pulse or alsa"
is_one_of "$OPT_DSI_PORT" 0 1                           || usage_error "--dsi-port must be 0 or 1"
is_one_of "$OPT_DSI_I2C" 0 1                            || usage_error "--dsi-i2c must be 0 or 1"
is_one_of "$OPT_SPLASH_ROTATE" 0 90 180 270            || usage_error "--splash-rotate must be 0, 90, 180 or 270"
is_one_of "$OPT_HEAD" auto serial gpio sim none         || usage_error "--head must be auto, serial, gpio, sim or none"
is_one_of "$OPT_START_KIOSK" auto 0 1                   || usage_error "--start-kiosk must be auto, 0 or 1"
is_one_of "$ASSUME_YES" 0 1                             || usage_error "ASSUME_YES must be 0 or 1"
is_one_of "$DRY_RUN" 0 1                                || usage_error "DRY_RUN must be 0 or 1"

if [[ $KEY_FROM_ENV -eq 1 ]]; then
    [[ -n "${OPENAI_API_KEY:-}" ]] || usage_error "--openai-key-from-env given but the environment variable OPENAI_API_KEY is empty or not passed through sudo (use: sudo -E ./install.sh ...)"
    OPENAI_KEY="$OPENAI_API_KEY"
fi
unset OPENAI_API_KEY          # never leak it into the environment of the steps
if [[ -n "${OPENAI_KEY:-}" ]]; then
    # One line, no whitespace/quotes/backslash: it goes into an EnvironmentFile. The value is never echoed.
    if ! [[ "$OPENAI_KEY" =~ ^[[:graph:]]+$ && "$OPENAI_KEY" != *[\"\'\\]* ]]; then
        usage_error "the OpenAI key contains whitespace, quotes, a backslash or control characters (it is not shown here); paste it without them"
    fi
fi

# step selection
name_index() { local i; for i in "${!STEP_NAMES[@]}"; do [[ "${STEP_NAMES[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done; return 1; }
validate_list() {   # OPTIONNAME LIST
    local n; local IFS=,
    for n in $2; do n="${n// /}"; [[ -z "$n" ]] && continue
        name_index "$n" >/dev/null || usage_error "unknown step '$n' in $1 (steps: ${STEP_NAMES[*]})"
    done
}
[[ -z "$ONLY" ]] || validate_list --only "$ONLY"
[[ -z "$SKIP" ]] || validate_list --skip "$SKIP"
ONLY=",${ONLY// /},"; SKIP=",${SKIP// /},"; [[ "$ONLY" == ",," ]] && ONLY=""
[[ "$SKIP" == ",," ]] && SKIP=""
SELECTED=(); for n in "${STEP_NAMES[@]}"; do
    if [[ -n "$ONLY" && "$ONLY" != *",$n,"* ]]; then continue; fi
    if [[ -n "$SKIP" && "$SKIP" == *",$n,"* ]]; then continue; fi
    SELECTED+=("$n")
done

if [[ $LIST_STEPS -eq 1 ]]; then
    for i in "${!STEP_NAMES[@]}"; do
        note=""; [[ -f "$PERI_SRC/scripts/${STEP_SCRIPTS[$i]}" ]] || note="   [script missing in this source tree]"
        printf '%-10s %-18s %s%s\n' "${STEP_NAMES[$i]}" "${STEP_SCRIPTS[$i]}" "${STEP_DESCS[$i]}" "$note"
    done
    exit 0
fi
[[ ${#SELECTED[@]} -gt 0 ]] || usage_error "no steps left to run after applying --only/--skip"

# ------------------------------------------------------------------------------------- environment

PERI_ROOT="${PERI_ROOT:-}"; PERI_ROOT="${PERI_ROOT%/}"
if [[ -n "$PERI_ROOT" ]]; then
    [[ -d "$PERI_ROOT" ]] || usage_error "PERI_ROOT=$PERI_ROOT is not a directory"
    PERI_ROOT=$(cd "$PERI_ROOT" && pwd -P)      # absolute: the steps run from other directories
fi
[[ -f "$PERI_SRC/scripts/lib.sh" ]] || usage_error "scripts/lib.sh not found next to install.sh ($PERI_SRC): run it from the Peri folder"

# Re-exec through sudo when the live system is going to be changed by a normal user.
if [[ "$DRY_RUN" -ne 1 && -z "$PERI_ROOT" && "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { echo "install.sh: must run as root and sudo is not installed" >&2; exit 2; }
    echo "install.sh: not root - re-running through sudo ..." >&2
    if [[ $KEY_FROM_ENV -eq 1 ]] && sudo -n -E true 2>/dev/null; then exec sudo -E bash "$SELF" "${ORIG_ARGS[@]}"; fi
    exec sudo bash "$SELF" "${ORIG_ARGS[@]}"
fi

umask 022
# A dropped SSH session (SIGHUP) or a consumer that stops reading our output (SIGPIPE, e.g. `| head`) must not kill an install
# in the middle of apt: both are ignored (the signal dispositions are inherited by every step and command); output errors are
# harmless because everything is also written to the log file. Ctrl+C and SIGTERM still stop the installer.
trap '' HUP PIPE
cd "$PERI_SRC"
export PERI_ROOT DRY_RUN ASSUME_YES PERI_SRC
# A dry run must not touch anything, the log file included (lib.sh honours this too).
[[ "$DRY_RUN" -eq 1 && -z "${PERI_LOG_FILE:-}" ]] && export PERI_LOG_FILE=/dev/null
CHANGE_LOG_OWNED=0
if [[ -z "${PERI_CHANGE_LOG:-}" ]]; then
    PERI_CHANGE_LOG=$(mktemp "${TMPDIR:-/tmp}/peri-changes.XXXXXX"); CHANGE_LOG_OWNED=1
fi
export PERI_CHANGE_LOG
DRY_REBOOT_LOG=""
if [[ "$DRY_RUN" -eq 1 ]]; then DRY_REBOOT_LOG=$(mktemp "${TMPDIR:-/tmp}/peri-dry-reboot.XXXXXX"); export PERI_DRY_REBOOT_LOG="$DRY_REBOOT_LOG"; fi
LOCK_DIR=""                      # set by acquire_lock (see below)
release_lock() { [[ -n "$LOCK_DIR" ]] && rm -rf "$LOCK_DIR"; return 0; }
cleanup() { release_lock; [[ -n "$DRY_REBOOT_LOG" ]] && rm -f "$DRY_REBOOT_LOG"; [[ $CHANGE_LOG_OWNED -eq 1 ]] && rm -f "$PERI_CHANGE_LOG"; return 0; }
trap cleanup EXIT
trap 'echo >&2; echo "install.sh: interrupted. Nothing is left half-way that a re-run cannot repair: run the same command again." >&2; exit 130' INT
trap 'echo "install.sh: terminated. Run the same command again to continue." >&2; exit 143' TERM

# shellcheck source=scripts/lib.sh
. "$PERI_SRC/scripts/lib.sh"
# shellcheck source=scripts/detect.sh
. "$PERI_SRC/scripts/detect.sh"

export PERI_STEPS_RUN="${SELECTED[*]}"
export PERI_OPT_KIOSK="$OPT_KIOSK" PERI_OPT_AUDIO_SERVER="$OPT_AUDIO_SERVER" PERI_OPT_DSI_PORT="$OPT_DSI_PORT"
export PERI_OPT_DSI_I2C="$OPT_DSI_I2C" PERI_OPT_DISABLE_HDMI="$OPT_DISABLE_HDMI" PERI_OPT_SPLASH_ROTATE="$OPT_SPLASH_ROTATE"
export PERI_OPT_NO_SPLASH="$OPT_NO_SPLASH" PERI_OPT_HEAD="$OPT_HEAD" PERI_OPT_START_KIOSK="$OPT_START_KIOSK"
# Non-interactive package handling for every step (a question would hang an unattended run).
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

# ------------------------------------------------------------------------------------------- helpers

# out LINE... : summary output goes to stdout (stderr carries the live log) and, unless dry-run, into the log file too.
out() {
    printf '%s\n' "$*" || true
    if [[ "$DRY_RUN" != 1 && -n "${PERI_LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$PERI_LOG_FILE")" 2>/dev/null || true
        printf '%s\n' "$*" >> "$PERI_LOG_FILE" 2>/dev/null || true
    fi
}

mode_label() {
    if [[ "$DRY_RUN" == 1 ]]; then echo "DRY RUN (nothing is changed)"
    elif [[ -n "$PERI_ROOT" ]]; then echo "FAKE ROOT $PERI_ROOT (files change under it, system commands are only logged)"
    else echo "REAL RUN"; fi
}

step_selected() { [[ " ${SELECTED[*]} " == *" $1 "* ]]; }
free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}' || true; }      # empty when the directory does not exist

# clear_stale_reboot_flag : a reboot-required flag older than the current boot belongs to a reboot that already happened.
clear_stale_reboot_flag() {
    [[ -f "$PERI_REBOOT_FLAG" && "$DRY_RUN" != 1 ]] || return 0
    local up boot_epoch flag_epoch
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null) || return 0
    boot_epoch=$(( $(date +%s) - up )); flag_epoch=$(stat -c %Y "$PERI_REBOOT_FLAG" 2>/dev/null) || return 0
    if [[ "$flag_epoch" -lt "$boot_epoch" ]]; then
        info "removing a stale reboot-required flag: it was set before the last boot"
        rm -f "$PERI_REBOOT_FLAG"
    fi
    return 0
}

# ------------------------------------------------------------------------------------------ preflight

PREFLIGHT_BAD=0
pf_fail() {   # a hard blocker (unless --force)
    if [[ $FORCE -eq 1 ]]; then warn "preflight (ignored because of --force): $*"; else err "preflight: $*"; PREFLIGHT_BAD=1; fi
}

preflight() {
    step "Preflight"
    [[ "$(uname -s 2>/dev/null || echo unknown)" == Linux ]] || pf_fail "this installer only supports Linux (Raspberry Pi OS)"
    if [[ "$IS_PI" != 1 ]]; then
        if [[ -z "$PERI_ROOT" && "$DRY_RUN" != 1 ]]; then
            pf_fail "this is not a Raspberry Pi (model: '${PI_MODEL:-none}'). The installer edits boot files, display managers and services; refusing to run it on another machine. Use --force if you really mean it (--head sim for a demo without hardware)."
        else
            warn "not a Raspberry Pi (model: '${PI_MODEL:-none}'): hardware steps will skip or fail; this is only fine for tests"
        fi
    else
        ok "machine: $PI_MODEL"
    fi
    if [[ "$OS_SUPPORTED" == 1 ]]; then ok "OS: $OS_PRETTY"
    else warn "OS '${OS_PRETTY:-unknown}' is not Raspberry Pi OS Bullseye/Bookworm/Trixie: package names and file locations may differ; continuing"; fi
    if [[ "$BITS" != 64 ]]; then warn "userland is ${BITS}-bit; the Peri device image is 64-bit (Chromium/vc4 driver combinations are untested on 32-bit)"; fi
    if [[ "${MEM_MB:-0}" -gt 0 && "$MEM_MB" -lt 900 ]]; then warn "only ${MEM_MB} MB RAM: the Chromium kiosk will be sluggish (Pi 4 with 2 GB or more recommended)"; fi

    # python: needed by the server. The packages step installs it, otherwise it must already be there.
    if [[ "$PY_OK" != 1 ]]; then
        if step_selected packages; then info "python3 >= 3.9 is not present (found: ${PY_VERSION:-none}); the packages step installs it"
        elif step_selected app || step_selected services; then pf_fail "python3 >= 3.9 is required by the server (found: ${PY_VERSION:-none}) and the packages step is not selected"; fi
    else ok "python3 $PY_VERSION"; fi

    local need_apt=0 s
    for s in packages kiosk audio; do step_selected "$s" && need_apt=1; done
    if [[ $need_apt -eq 1 && -z "$PERI_ROOT" && "$DRY_RUN" != 1 ]] && ! command -v apt-get >/dev/null 2>&1; then
        pf_fail "apt-get not found: this installer needs a Debian-based system (Raspberry Pi OS)"
    fi

    # disk: the full install pulls Chromium and friends (about 700 MB); an update needs almost nothing.
    local need_root_mb="${PERI_MIN_FREE_MB:-}" need_boot_mb="${PERI_MIN_BOOT_FREE_MB:-64}" have_root_mb have_boot_mb
    if [[ -z "$need_root_mb" ]]; then
        need_root_mb=100
        for s in audio display; do step_selected "$s" && need_root_mb=300; done
        for s in packages kiosk; do step_selected "$s" && need_root_mb=1500; done
    fi
    have_root_mb=$(free_mb "$(rp /)")
    if [[ -n "$have_root_mb" ]]; then
        if [[ "$have_root_mb" -lt "$need_root_mb" ]]; then pf_fail "only ${have_root_mb} MB free on / (need ${need_root_mb} MB): free some space (sudo apt-get clean; remove unused files)"
        else ok "disk: ${have_root_mb} MB free on / (need ${need_root_mb} MB)"; fi
    fi
    if step_selected display || step_selected audio || step_selected boot; then
        have_boot_mb=$(free_mb "$(rp "$BOOT_DIR")")
        if [[ -n "$have_boot_mb" && "$have_boot_mb" -lt "$need_boot_mb" ]]; then
            pf_fail "only ${have_boot_mb} MB free on $BOOT_DIR (need ${need_boot_mb} MB for config.txt/cmdline.txt backups and the initramfs)"
        elif [[ -n "$have_boot_mb" ]]; then ok "disk: ${have_boot_mb} MB free on $BOOT_DIR"; fi
    fi

    if [[ "$HAVE_INTERNET" != 1 ]]; then
        if [[ $need_apt -eq 1 ]]; then warn "no internet connection detected (could not reach deb.debian.org): apt installs will fail unless everything is already installed"; else info "no internet connection detected (not needed for the selected steps)"; fi
    else ok "internet reachable"; fi
    if [[ "$DRY_RUN" == 1 && -z "$PERI_ROOT" && "$(id -u)" -ne 0 ]]; then
        warn "dry run as a normal user: files only root can read (sudoers, peri.env) cannot be compared and may be listed as changed; use 'sudo ./install.sh --dry-run' for an exact preview"
    fi
    if [[ -z "$PERI_ROOT" && "$DRY_RUN" != 1 ]]; then
        if command -v timedatectl >/dev/null 2>&1 && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == no ]]; then
            warn "the system clock is not NTP-synchronised: apt may reject repository metadata ('not valid yet'). Check: timedatectl"
        fi
        [[ -d /run/systemd/system ]] || warn "systemd is not the running init system: services can be installed but not started"
    fi
    local i
    for s in "${SELECTED[@]}"; do
        i=$(name_index "$s")
        [[ -f "$PERI_SRC/scripts/${STEP_SCRIPTS[$i]}" ]] || warn "step '$s': scripts/${STEP_SCRIPTS[$i]} is missing from this source tree: the step will be reported as FAILED (script missing)"
    done
    if step_selected services && ! step_selected app && [[ ! -d "$(rp /opt/peri/server)" ]]; then
        warn "the services step is selected without the app step and /opt/peri is not installed yet"
    fi
    if [[ $PREFLIGHT_BAD -ne 0 ]]; then
        err "preflight failed: nothing was changed. Fix the problem above (or use --force to override) and run again."
        exit 2
    fi
}

# ---------------------------------------------------------------------------------------------- lock

# One installer at a time. A directory is the lock (mkdir is atomic) holding our pid, so that no file descriptor is inherited
# by daemons that a package's maintainer script may start, and a crashed run (kill -9, power loss) leaves a stale lock that
# the next run recognises (its pid is gone) and replaces.
acquire_lock() {
    [[ "$DRY_RUN" != 1 ]] || return 0
    local dir="$PERI_STATE_INSTALL_DIR/lock.d" pid=""
    mkdir -p "$PERI_STATE_INSTALL_DIR" 2>/dev/null || return 0
    if ! mkdir "$dir" 2>/dev/null; then
        pid=$(cat "$dir/pid" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep 'install' >/dev/null; then
            err "another installer is already running on this system (pid $pid; lock: $dir)"; exit 2
        fi
        warn "removing a stale installer lock (its process ${pid:-?} is gone)"
        rm -rf "$dir"
        mkdir "$dir" 2>/dev/null || return 0
    fi
    printf '%s\n' "$$" > "$dir/pid"
    LOCK_DIR="$dir"
}

# ---------------------------------------------------------------------------------------------- run

RESULT=(); RTIME=(); RNOTE=()      # indexed like STEP_NAMES
run_step() {   # NAME
    local name="$1" i script rc t0 n
    i=$(name_index "$name"); script="$PERI_SRC/scripts/${STEP_SCRIPTS[$i]}"
    n=$((${#DONE_STEPS[@]} + 1))
    step "Step $n/${#SELECTED[@]}: $name - ${STEP_DESCS[$i]}"
    t0=$SECONDS
    if [[ ! -f "$script" ]]; then
        err "script missing: scripts/${STEP_SCRIPTS[$i]} (not part of this source tree)"
        RESULT[i]=FAIL; RNOTE[i]="script missing"; RTIME[i]=0; DONE_STEPS+=("$name"); return 0
    fi
    local stdin_src=/dev/stdin
    [[ "$ASSUME_YES" == 1 ]] && stdin_src=/dev/null     # an unexpected question must get EOF, not hang an unattended run
    if [[ "$name" == app && -n "$OPENAI_KEY" ]]; then
        if PERI_OPT_OPENAI_KEY="$OPENAI_KEY" PERI_STEP="$name" bash "$script" < "$stdin_src"; then rc=0; else rc=$?; fi
    else
        if PERI_STEP="$name" bash "$script" < "$stdin_src"; then rc=0; else rc=$?; fi
    fi
    RTIME[i]=$((SECONDS - t0))
    if [[ $rc -eq 0 ]]; then RESULT[i]=PASS; RNOTE[i]=""; ok "step $name finished in ${RTIME[i]}s"
    else RESULT[i]=FAIL; RNOTE[i]="exit $rc"; err "step $name FAILED with exit status $rc after ${RTIME[i]}s"; fi
    DONE_STEPS+=("$name")
}
DONE_STEPS=()

# ---------------------------------------------------------------------------------------------- main

LOG_START=0
if [[ "$DRY_RUN" != 1 && -f "$PERI_LOG_FILE" ]]; then LOG_START=$(stat -c %s "$PERI_LOG_FILE" 2>/dev/null || echo 0); fi
step "Peri installer $VERSION - $(mode_label)"
info "started $(now_iso); arguments: ${SAFE_ARGS[*]:-(none)}"

detect_all
print_detection
preflight

step "Plan"
info "mode:    $(mode_label)"
info "steps:   ${SELECTED[*]}"
skipped=(); for s in "${STEP_NAMES[@]}"; do step_selected "$s" || skipped+=("$s"); done
[[ ${#skipped[@]} -eq 0 ]] || info "skipped: ${skipped[*]} (--only/--skip)"
info "options: kiosk=$OPT_KIOSK audio-server=$OPT_AUDIO_SERVER dsi-port=$OPT_DSI_PORT dsi-i2c=$OPT_DSI_I2C disable-hdmi=$OPT_DISABLE_HDMI splash-rotate=$OPT_SPLASH_ROTATE no-splash=$OPT_NO_SPLASH head=$OPT_HEAD start-kiosk=$OPT_START_KIOSK reboot=$([[ $DO_REBOOT -eq 1 ]] && echo automatic || echo manual)"
if [[ -n "$OPENAI_KEY" ]]; then info "OpenAI key: given (value hidden); stored in /etc/peri/peri.env"
else info "OpenAI key: not given (an existing /etc/peri/peri.env is kept; a new one is seeded from config/peri.env if present, else the template)"; fi
info "log:     ${PERI_LOG_FILE}   manifest: ${PERI_MANIFEST}"
if [[ "$ASSUME_YES" != 1 && "$DRY_RUN" != 1 ]]; then
    confirm "Proceed with the installation?" || { err "not confirmed: nothing was changed (use --yes to run unattended)"; exit 2; }
fi

clear_stale_reboot_flag
acquire_lock
for s in "${SELECTED[@]}"; do run_step "$s"; done

# ------------------------------------------------------------------------------------------ summary

FAILED=(); for s in "${SELECTED[@]}"; do i=$(name_index "$s"); [[ "${RESULT[i]:-}" == FAIL ]] && FAILED+=("$s"); done
NCHANGES=$(changes_count write); NWOULD=$(changes_count would)
WARNS="n/a"; ERRS="n/a"
if [[ "$DRY_RUN" != 1 && -f "$PERI_LOG_FILE" ]]; then
    seg=$(tail -c "+$((LOG_START + 1))" "$PERI_LOG_FILE" 2>/dev/null || true)
    WARNS=$(printf '%s\n' "$seg" | grep -c ' WARN ' || true); ERRS=$(printf '%s\n' "$seg" | grep -c ' ERROR ' || true)
fi
[[ "$DRY_RUN" != 1 && -s "$PERI_CHANGE_LOG" ]] && { printf 'changes made in this run:\n'; cut -f2- "$PERI_CHANGE_LOG" | sed 's/^/  - /'; } >> "${PERI_LOG_FILE:-/dev/null}" 2>/dev/null || true

REBOOT_PENDING=0; [[ "$DRY_RUN" != 1 && -s "$PERI_REBOOT_FLAG" ]] && REBOOT_PENDING=1
BAR="========================================================================"
out ""
out "$BAR"
out " Peri installer $VERSION - summary ($(mode_label))"
out "$BAR"
out "$(printf ' %-10s %-7s %6s   %s' STEP RESULT TIME DETAIL)"
for i in "${!STEP_NAMES[@]}"; do
    s="${STEP_NAMES[$i]}"
    if step_selected "$s"; then
        out "$(printf ' %-10s %-7s %5ss   %s' "$s" "${RESULT[i]:-?}" "${RTIME[i]:-0}" "${RNOTE[i]:-}")"
    else
        out "$(printf ' %-10s %-7s %6s   %s' "$s" SKIP "-" "not selected (--only/--skip)")"
    fi
done
out "$BAR"
if [[ "$DRY_RUN" == 1 ]]; then out " Dry run: $NWOULD change(s) would be made. Nothing was changed."
else out " Changes made: $NCHANGES   Warnings logged: $WARNS   Errors logged: $ERRS"; fi
out " Log file: ${PERI_LOG_FILE}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    out ""
    out " FAILED steps: ${FAILED[*]}"
    for s in "${FAILED[@]}"; do
        out "   - $s: fix the cause shown in the log above, then re-run only this step:  sudo ./install.sh --yes --only $s"
    done
fi
if [[ $REBOOT_PENDING -eq 1 ]]; then
    out ""
    out "*** REBOOT REQUIRED ***"
    out "Why:"
    while IFS= read -r line; do [[ -n "$line" ]] && out "  - $line"; done < "$PERI_REBOOT_FLAG"
    out "Next:"
    out "  1. sudo reboot"
    out "  2. wait about 60 seconds, reconnect (ssh), then run:"
    out "     sudo /opt/peri/scripts/post-reboot-verify.sh"
elif [[ "$DRY_RUN" == 1 ]]; then
    if [[ -s "$DRY_REBOOT_LOG" ]]; then
        out ""
        out " A real run would require a reboot afterwards, because of:"
        while IFS= read -r line; do [[ -n "$line" ]] && out "  - $line"; done < <(sort -u "$DRY_REBOOT_LOG")
    fi
    out ""
    out " To apply for real:  sudo ./install.sh --yes"
elif [[ ${#FAILED[@]} -eq 0 ]]; then
    out ""
    out " Verify now:  sudo /opt/peri/scripts/verify.sh"
    out " Status/logs: sudo peri-config status ; sudo peri-config logs"
    if [[ -n "$OPENAI_KEY" ]] || grep -Eqs '^[[:space:]]*OPENAI_API_KEY=[^[:space:]]' "$(rp /etc/peri/peri.env)"; then :
    else out " No OpenAI key is configured yet:  echo 'sk-...' | sudo peri-config set OPENAI_API_KEY -"; fi
fi
out ""

if [[ $REBOOT_PENDING -eq 1 && $DO_REBOOT -eq 1 ]]; then
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        warn "--reboot: NOT rebooting automatically because some steps failed; fix them first (the SSH connection stays available)"
    elif [[ -n "$PERI_ROOT" ]]; then
        info "--reboot: would reboot now (fake root: not doing it)"
    else
        warn "--reboot: rebooting in 10 seconds (Ctrl+C cancels). The SSH connection will drop; reconnect after ~60 s and run: sudo /opt/peri/scripts/post-reboot-verify.sh"
        sleep 10; sync
        sysrun systemctl reboot || sysrun reboot
    fi
fi

[[ ${#FAILED[@]} -eq 0 ]] || exit 1
exit 0
