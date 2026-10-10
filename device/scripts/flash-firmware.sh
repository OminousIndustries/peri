#!/usr/bin/env bash
# flash-firmware.sh - compile and upload the Peri head firmware (firmware/peri_head) to the Arduino Nano.
#
# What it does, in order (every step logs what it decided and why; the last line on stdout is PASS or FAIL):
#   1. finds arduino-cli, or downloads the official release (checksum-verified, never piped into a shell)
#   2. installs the arduino:avr core if missing
#   3. compiles the sketch for the Nano (ATmega328P, new bootloader) and prints flash/RAM usage
#   4. finds the serial port, stops peri-server.service while it holds the port (restarted afterwards, even on failure)
#   5. uploads; if compile or upload fails it retries with the old-bootloader variant (57600 baud clones)
#   6. verifies: sends HELLO and expects a line starting "PERI-HEAD 1" (the Nano resets when the port is opened)
# Works as a normal user or as root, from any directory.
set -Eeuo pipefail

PROG="flash-firmware"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH_DIR="${PERI_SKETCH_DIR:-$SCRIPT_DIR/../firmware/peri_head}"
SKETCH_NAME="peri_head"

PINNED_CLI_VERSION="1.5.1"                                  # the version whose SHA-256 sums are embedded below
CLI_VERSION="${PERI_ARDUINO_CLI_VERSION:-$PINNED_CLI_VERSION}"
CORE_ID="arduino:avr"
FQBN_NEW="arduino:avr:nano:cpu=atmega328"                   # Nano, ATmega328P, new bootloader (115200 baud upload)
FQBN_OLD="arduino:avr:nano:cpu=atmega328old"                # Nano, ATmega328P, old bootloader (57600 baud upload)
SERVER_UNIT="peri-server.service"
DEV_DIR="${PERI_DEV_DIR:-/dev}"                             # where the serial devices live (a test hook)

OPT_PORT=""
OPT_FQBN=""
OPT_COMPILE_ONLY=0
OPT_NO_STOP=0
OPT_SKIP_VERIFY=0
OPT_DRY=0
OPT_YES=0

CLI=""                  # path of the arduino-cli in use
TOOLS_DIR=""            # where we install / keep arduino-cli and its data
PRIVATE_DIRS=1          # 1 = keep arduino-cli's data dirs under TOOLS_DIR, 0 = use the user's own arduino-cli setup
WORK=""                 # scratch directory (removed on exit)
SERVER_STOPPED=0

usage() {
    cat <<EOF
Usage: $PROG.sh [options]

Compile firmware/peri_head and upload it to the Arduino Nano of the Peri head, then check that it answers HELLO.

Options:
  --port DEV        serial port to use (default: auto-detect /dev/serial/by-id/*, /dev/ttyUSB*, /dev/ttyACM*;
                    with several candidates they are listed and the first one is used)
  --fqbn FQBN       use exactly this board instead of trying $FQBN_NEW and then $FQBN_OLD
  --compile-only    only compile and print flash/RAM usage (no serial port needed, nothing is uploaded)
  --no-stop-server  do not stop $SERVER_UNIT while flashing
  --skip-verify     do not send HELLO after the upload
  --dry-run         show what would be done; download, install, stop, compile and upload nothing
  --yes, -y         never ask questions (also the default when stdin is not a terminal)
  -h, --help        this text

Environment:
  PERI_TOOLS_DIR              where arduino-cli and its cores live (default /opt/peri/tools as root,
                              ~/.local/share/peri-tools otherwise)
  PERI_ARDUINO_CLI_VERSION    arduino-cli version to install (default $PINNED_CLI_VERSION)
  PERI_SKETCH_DIR             sketch directory (default: ../firmware/peri_head next to this script)
  PERI_ARDUINO_CLI_MIRRORS    space separated base URLs to download arduino-cli from (default: downloads.arduino.cc,
                              then the GitHub release); the SHA-256 of the archive is always checked

Exit status: 0 = PASS, 1 = FAIL (see the message and hint), 2 = usage error.
Examples:
  scripts/flash-firmware.sh --compile-only         # does the sketch build?
  sudo scripts/flash-firmware.sh --yes             # flash the connected Nano, unattended
  scripts/flash-firmware.sh --port /dev/ttyUSB0 --fqbn $FQBN_OLD
EOF
}

# ------------------------------------------------------------------------------------------------- output helpers
log()  { printf '[%s] %s\n' "$PROG" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "$PROG" "$*" >&2; }

# fail REASON [HINT]: print the FAIL line (stdout) and exit 1; the EXIT trap restarts the server.
fail() {
    printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2
    [[ -n "${2:-}" ]] && printf '[%s] HINT: %s\n' "$PROG" "$2" >&2
    printf 'FAIL: %s\n' "$1"
    exit 1
}

usage_error() {
    printf '%s: %s\n\n' "$PROG" "$1" >&2
    usage >&2
    exit 2
}

is_root() { ((EUID == 0)); }

# priv CMD...: run as root (directly when we are root, else through non-interactive sudo). Fails when neither works.
priv() {
    if is_root; then
        "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n "$@"
    else
        return 1
    fi
}

confirm() {    # confirm QUESTION: yes without asking when --yes or when there is no terminal
    ((OPT_YES)) && return 0
    [[ -t 0 && -t 2 ]] || return 0
    local answer
    read -r -p "[$PROG] $1 [Y/n] " answer || return 0
    [[ "$answer" != [nN]* ]]
}

cleanup() {
    local rc=$?
    trap - EXIT
    if ((SERVER_STOPPED)); then
        log "restarting $SERVER_UNIT"
        priv systemctl start "$SERVER_UNIT" || warn "could not restart $SERVER_UNIT - run: sudo systemctl start $SERVER_UNIT"
        SERVER_STOPPED=0
    fi
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
    exit "$rc"
}

# ------------------------------------------------------------------------------------------------- arduino-cli
# SHA-256 of the official release archives (from arduino-cli's published <version>-checksums.txt).
pinned_sha256() {    # pinned_sha256 ARCHIVE_SUFFIX
    case "$1" in
        Linux_32bit) echo "85ed48978e7553b16f187971f8202d380421b352696ab28327a36cc6d8f11c6a" ;;
        Linux_64bit) echo "28a8e119c498a25607821c36cb2dc49e8463941b261a0d99091baa7bc692dd2b" ;;
        Linux_ARM64) echo "1e69e077479f300614d4551334e0a33f08ee40b04315d83b8e7e0e94f0d0ee62" ;;
        Linux_ARMv6) echo "168aa0c632d7079fea0ccd30b3f1e928e89e2f59a339404f1d2f4a07ed6cc566" ;;
        Linux_ARMv7) echo "890af36e9873606e4dfa743534846186621b9f3a339175ea3ec481adecf07143" ;;
        *) return 1 ;;
    esac
}

# Archive names to try for this machine, best first (a 32 bit userland on a 64 bit ARM kernel reports aarch64 but
# cannot run the ARM64 binary; the run test in install_cli then falls through to the next candidate).
archive_candidates() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "Linux_64bit" ;;
        aarch64 | arm64) echo "Linux_ARM64 Linux_ARMv7" ;;
        armv7l | armv8l) echo "Linux_ARMv7 Linux_ARMv6" ;;
        armv6l) echo "Linux_ARMv6" ;;
        i386 | i486 | i586 | i686) echo "Linux_32bit" ;;
        *) return 1 ;;
    esac
}

download() {    # download URL DEST
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -t 3 -O "$2" "$1"
    else
        return 127
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        return 127
    fi
}

# expected_sha256 ARCHIVE_SUFFIX ARCHIVE_NAME: embedded sum for the pinned version, else the release's checksums file.
expected_sha256() {
    local suffix=$1 archive=$2 sums=""
    if [[ "$CLI_VERSION" == "$PINNED_CLI_VERSION" ]]; then
        pinned_sha256 "$suffix"
        return
    fi
    sums="$WORK/checksums.txt"
    download "https://github.com/arduino/arduino-cli/releases/download/v${CLI_VERSION}/${CLI_VERSION}-checksums.txt" "$sums" || return 1
    awk -v f="$archive" '$2 == f { print $1 }' "$sums"
}

install_cli() {
    local suffix archive want got base url
    local -a candidates mirrors
    local target="$TOOLS_DIR/bin/arduino-cli"
    read -r -a mirrors <<<"${PERI_ARDUINO_CLI_MIRRORS:-https://downloads.arduino.cc/arduino-cli https://github.com/arduino/arduino-cli/releases/download/v${CLI_VERSION}}"
    if ! read -r -a candidates < <(archive_candidates); then
        fail "no arduino-cli release for this CPU ($(uname -m))" "install arduino-cli by hand (https://arduino.github.io/arduino-cli/latest/installation/) and put it on PATH"
    fi
    log "arduino-cli not found - installing version $CLI_VERSION into $TOOLS_DIR/bin"
    if ((OPT_DRY)); then
        log "dry-run: would download arduino-cli_${CLI_VERSION}_${candidates[0]}.tar.gz from downloads.arduino.cc, verify its SHA-256 and install it"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        fail "neither curl nor wget is installed" "install one of them (sudo apt install curl) or put arduino-cli on PATH"
    fi
    confirm "Download arduino-cli $CLI_VERSION (about 17 MB) into $TOOLS_DIR?" || fail "cancelled by user"
    mkdir -p "$TOOLS_DIR/bin" || fail "cannot create $TOOLS_DIR/bin" "set PERI_TOOLS_DIR to a writable directory, or run as root"
    for suffix in "${candidates[@]}"; do
        archive="arduino-cli_${CLI_VERSION}_${suffix}.tar.gz"
        want="$(expected_sha256 "$suffix" "$archive")" || want=""
        [[ -n "$want" ]] || fail "no checksum known for $archive" "use the default arduino-cli version, or check network access to github.com"
        got=""
        for base in "${mirrors[@]}"; do
            url="$base/$archive"
            log "downloading $url"
            if download "$url" "$WORK/$archive"; then
                got="$(sha256_of "$WORK/$archive")" || fail "no sha256sum/shasum available to verify the download"
                [[ "$got" == "$want" ]] && break
                warn "checksum mismatch for $url (got $got, want $want)"
                got=""
            else
                warn "download failed: $url"
            fi
        done
        [[ -n "$got" ]] || fail "could not download a verified $archive" "check the network / proxy; downloads come from downloads.arduino.cc and github.com"
        tar -xzf "$WORK/$archive" -C "$WORK" arduino-cli || fail "cannot unpack $archive"
        install -m 0755 "$WORK/arduino-cli" "$target"
        if "$target" version >/dev/null 2>&1; then
            log "installed: $("$target" version 2>&1 | head -1)"
            return 0
        fi
        warn "$suffix build does not run on this machine, trying the next candidate"
        rm -f "$target"
    done
    fail "the downloaded arduino-cli does not run on this machine ($(uname -m))"
}

find_cli() {
    local dir
    if [[ -x "$TOOLS_DIR/bin/arduino-cli" ]]; then
        CLI="$TOOLS_DIR/bin/arduino-cli"
    elif [[ -z "${PERI_TOOLS_DIR:-}" ]]; then            # PERI_TOOLS_DIR given explicitly = keep everything inside it
        if command -v arduino-cli >/dev/null 2>&1; then
            CLI="$(command -v arduino-cli)"
            PRIVATE_DIRS=0                               # the user's own install and configuration: leave it alone
        else
            for dir in /opt/peri/tools "${HOME:-/nonexistent}/.local/share/peri-tools"; do
                if [[ -x "$dir/bin/arduino-cli" ]] && "$dir/bin/arduino-cli" version >/dev/null 2>&1; then
                    CLI="$dir/bin/arduino-cli"           # installed earlier by root or another user: reuse the binary
                    break
                fi
            done
        fi
    fi
    if [[ -z "$CLI" ]]; then
        install_cli
        CLI="$TOOLS_DIR/bin/arduino-cli"
    fi
    ((OPT_DRY)) && [[ ! -x "$CLI" ]] && return 0
    "$CLI" version >/dev/null 2>&1 || fail "$CLI does not run" "remove it and run this script again to download a fresh copy"
    log "using $CLI ($("$CLI" version 2>&1 | head -1))"
    if ((PRIVATE_DIRS)); then
        # Keep cores and downloads next to the tool so nothing depends on the caller's home directory.
        export ARDUINO_DIRECTORIES_DATA="$TOOLS_DIR/arduino15"
        export ARDUINO_DIRECTORIES_DOWNLOADS="$TOOLS_DIR/arduino15/staging"
        export ARDUINO_DIRECTORIES_USER="$TOOLS_DIR/arduino-user"
        log "arduino-cli data directory: $ARDUINO_DIRECTORIES_DATA"
    fi
    export ARDUINO_UPDATER_ENABLE_NOTIFICATION=false
}

ensure_core() {
    if ((OPT_DRY)) && [[ ! -x "$CLI" ]]; then
        log "dry-run: would run: arduino-cli core update-index && arduino-cli core install $CORE_ID"
        return 0
    fi
    local listed
    listed="$("$CLI" core list 2>/dev/null | grep "^${CORE_ID}[[:space:]]" | head -n 1 || true)"    # (no grep -q: SIGPIPE + pipefail)
    if [[ -n "$listed" ]]; then
        log "core $CORE_ID already installed: $listed"
        return 0
    fi
    if ((OPT_DRY)); then
        log "dry-run: would run: arduino-cli core update-index && arduino-cli core install $CORE_ID"
        return 0
    fi
    log "installing core $CORE_ID (compiler, avrdude and the Arduino AVR core; about 100 MB, once)"
    local try
    for try in 1 2 3; do
        if "$CLI" core update-index && "$CLI" core install "$CORE_ID"; then
            return 0
        fi
        warn "core installation failed (attempt $try of 3)"
        sleep 3
    done
    fail "could not install the $CORE_ID core" "check network access to downloads.arduino.cc"
}

# ------------------------------------------------------------------------------------------------- compile
BUILD_DIR=""
USAGE_SUMMARY=""
compile_sketch() {    # compile_sketch FQBN  ->  0 ok / 1 failed; sets BUILD_DIR and prints the memory usage
    local fqbn=$1 log_file
    BUILD_DIR="$WORK/build-${fqbn//[^A-Za-z0-9]/_}"
    log_file="$BUILD_DIR.log"
    log "compiling $SKETCH_NAME for $fqbn"
    if ((OPT_DRY)); then
        log "dry-run: would run: arduino-cli compile --fqbn $fqbn --build-path $BUILD_DIR $SKETCH_DIR"
        return 0
    fi
    if ! "$CLI" compile --fqbn "$fqbn" --build-path "$BUILD_DIR" --warnings default "$SKETCH_DIR" >"$log_file" 2>&1; then
        sed 's/^/    /' "$log_file" >&2
        warn "compile failed for $fqbn"
        return 1
    fi
    local flash ram
    flash="$(sed -n 's/^Sketch uses \([0-9]*\) bytes (\([0-9]*\)%) of program storage space. Maximum is \([0-9]*\) bytes.*/\1\/\3 bytes (\2%)/p' "$log_file" | head -1)"
    ram="$(sed -n 's/^Global variables use \([0-9]*\) bytes (\([0-9]*\)%) of dynamic memory.*Maximum is \([0-9]*\) bytes.*/\1\/\3 bytes (\2%)/p' "$log_file" | head -1)"
    grep -i 'warning' "$log_file" | head -5 | sed 's/^/    /' >&2 || true
    log "compiled OK: flash ${flash:-unknown}, RAM ${ram:-unknown}"
    USAGE_SUMMARY="flash ${flash:-?}, RAM ${ram:-?}"
    return 0
}

# ------------------------------------------------------------------------------------------------- port + server
PORT=""
detect_port() {
    local p real seen=" "
    local -a found=()
    if [[ -n "$OPT_PORT" ]]; then
        PORT="$OPT_PORT"
        [[ -e "$PORT" ]] || warn "$PORT does not exist (yet)"
        log "using the serial port given with --port: $PORT"
        return 0
    fi
    shopt -s nullglob
    for p in "$DEV_DIR"/serial/by-id/* "$DEV_DIR"/ttyUSB* "$DEV_DIR"/ttyACM*; do
        real="$(readlink -f "$p")"
        [[ "$seen" == *" $real "* ]] && continue         # the by-id link and /dev/ttyUSBn are the same device
        seen+="$real "
        found+=("$p")
    done
    shopt -u nullglob
    if ((${#found[@]} == 0)); then
        return 1
    fi
    PORT="${found[0]}"
    if ((${#found[@]} > 1)); then
        warn "several serial ports found: ${found[*]} - using $PORT (choose another with --port)"
    else
        log "serial port: $PORT"
    fi
    return 0
}

stop_server() {
    ((OPT_NO_STOP)) && { log "not stopping $SERVER_UNIT (--no-stop-server)"; return 0; }
    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemctl not available - nothing to stop"
        return 0
    fi
    if ! systemctl is-active --quiet "$SERVER_UNIT" 2>/dev/null; then
        log "$SERVER_UNIT is not running - nothing to stop"
        return 0
    fi
    if ((OPT_DRY)); then
        log "dry-run: would stop $SERVER_UNIT during the upload and start it again afterwards"
        return 0
    fi
    log "stopping $SERVER_UNIT (it holds the serial port); it is restarted when this script ends"
    if priv systemctl stop "$SERVER_UNIT"; then
        SERVER_STOPPED=1
    else
        warn "cannot stop $SERVER_UNIT (not root and no passwordless sudo). If the upload reports a busy port, run: sudo systemctl stop $SERVER_UNIT"
    fi
}

# ------------------------------------------------------------------------------------------------- upload + verify
UPLOAD_LOG=""
explain_upload_failure() {    # look at the avrdude output and say what it means
    local f=$1
    if grep -qiE 'not in sync|stk500_(getsync|recv)|programmer is not responding' "$f"; then
        warn "'not in sync': the bootloader did not answer at this baud rate - typically a Nano clone with the OLD bootloader ($FQBN_OLD, 57600 baud)"
    fi
    if grep -qiE 'permission denied' "$f"; then
        warn "permission denied on the serial port: add your user to the dialout group (sudo usermod -aG dialout \$USER, then log in again) or run with sudo"
    fi
    if grep -qiE 'resource busy|device or resource|in use' "$f"; then
        warn "the port is busy: stop peri-server (sudo systemctl stop $SERVER_UNIT) and any terminal program (screen, minicom, ModemManager probing)"
    fi
    if grep -qiE 'no such file|cannot open|can.t open device' "$f" && ! grep -qiE 'permission denied|resource busy' "$f"; then
        warn "the port disappeared or is not a serial device - is the Nano still connected? (dmesg | tail)"
    fi
}

upload_sketch() {    # upload_sketch FQBN PORT  ->  0 / 1
    local fqbn=$1 port=$2
    UPLOAD_LOG="$WORK/upload.log"
    log "uploading to $port ($fqbn)"
    if ((OPT_DRY)); then
        log "dry-run: would run: arduino-cli upload -p $port --fqbn $fqbn --input-dir $BUILD_DIR"
        return 0
    fi
    if "$CLI" upload -v -p "$port" --fqbn "$fqbn" --input-dir "$BUILD_DIR" >"$UPLOAD_LOG" 2>&1; then
        log "upload finished"
        return 0
    fi
    tail -n 25 "$UPLOAD_LOG" | sed 's/^/    /' >&2
    warn "upload failed for $fqbn"
    explain_upload_failure "$UPLOAD_LOG"
    return 1
}

VERIFY_REPLY=""
verify_python() {    # pyserial available: open, wait for the reset, ask HELLO
    python3 - "$1" <<'PY'
import sys, time
import serial
port = sys.argv[1]
try:
    ser = serial.Serial(port, 115200, timeout=0.3)      # opening the port resets the Nano (DTR)
except Exception as exc:
    print("cannot open %s: %s" % (port, exc))
    sys.exit(3)
t0 = time.monotonic()
last_hello = 0.0
buf = b""
while time.monotonic() - t0 < 8.0:
    now = time.monotonic()
    if now - t0 > 1.8 and now - last_hello > 0.7:       # the bootloader needs about 2 s; then HELLO is answered
        ser.write(b"HELLO\n")
        ser.flush()
        last_hello = now
    buf += ser.read(64)
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        text = line.decode("ascii", "replace").strip()
        if text.startswith("PERI-HEAD 1"):
            print(text)
            sys.exit(0)
sys.exit(1)
PY
}

verify_stty() {    # no pyserial: plain shell on the tty
    local port=$1 line start=$SECONDS sent=0
    exec 3<>"$port" || return 3
    stty -F "$port" 115200 raw -echo -echoe -echok -crtscts -ixon -ixoff cs8 -cstopb -parenb clocal cread 2>/dev/null \
        || warn "stty could not configure $port"
    while ((SECONDS - start < 8)); do
        if ((SECONDS - start >= 2 && sent < 5)); then
            printf 'HELLO\n' >&3
            sent=$((sent + 1))
        fi
        if IFS= read -r -t 1 line <&3; then
            line="${line%$'\r'}"
            if [[ "$line" == "PERI-HEAD 1"* ]]; then
                printf '%s\n' "$line"
                exec 3>&-
                return 0
            fi
        fi
    done
    exec 3>&-
    return 1
}

verify_firmware() {    # verify_firmware PORT  ->  0 when the device answers with its banner
    local port=$1
    log "verifying: waiting for the Nano to restart and answer HELLO on $port (about 2-6 s)"
    if ((OPT_DRY)); then
        log "dry-run: would send HELLO and expect a line starting with 'PERI-HEAD 1'"
        return 0
    fi
    local rc=0
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import serial' 2>/dev/null; then
        VERIFY_REPLY="$(verify_python "$port")" || rc=$?
    else
        log "python3 with pyserial not available - using stty"
        VERIFY_REPLY="$(verify_stty "$port")" || rc=$?
    fi
    if ((rc == 0)); then
        log "device answered: $VERIFY_REPLY"
        return 0
    fi
    [[ -n "$VERIFY_REPLY" ]] && warn "$VERIFY_REPLY"
    return 1
}

# ------------------------------------------------------------------------------------------------- main
parse_args() {
    while (($#)); do
        case "$1" in
            --port) [[ $# -ge 2 ]] || usage_error "--port needs a device"; OPT_PORT="$2"; shift ;;
            --port=*) OPT_PORT="${1#--port=}" ;;
            --fqbn) [[ $# -ge 2 ]] || usage_error "--fqbn needs a value"; OPT_FQBN="$2"; shift ;;
            --fqbn=*) OPT_FQBN="${1#--fqbn=}" ;;
            --compile-only) OPT_COMPILE_ONLY=1 ;;
            --no-stop-server) OPT_NO_STOP=1 ;;
            --skip-verify) OPT_SKIP_VERIFY=1 ;;
            --dry-run) OPT_DRY=1 ;;
            --yes | -y) OPT_YES=1 ;;
            -h | --help) usage; exit 0 ;;
            *) usage_error "unknown option: $1" ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ ! -f "$SKETCH_DIR/$SKETCH_NAME.ino" ]]; then
        fail "sketch not found: $SKETCH_DIR/$SKETCH_NAME.ino" "run this script from a complete checkout/installation (firmware/peri_head next to scripts/)"
    fi
    SKETCH_DIR="$(cd "$SKETCH_DIR" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/peri-flash.XXXXXX")"

    if [[ -n "${PERI_TOOLS_DIR:-}" ]]; then
        TOOLS_DIR="$PERI_TOOLS_DIR"
    elif is_root; then
        TOOLS_DIR="/opt/peri/tools"
    else
        TOOLS_DIR="${HOME:-/tmp}/.local/share/peri-tools"
    fi
    ((OPT_DRY)) && log "dry-run: nothing will be downloaded, installed, stopped, compiled or uploaded"
    log "sketch: $SKETCH_DIR; tools directory: $TOOLS_DIR; running as $(id -un)"

    find_cli
    ensure_core

    local -a fqbns=("$FQBN_NEW" "$FQBN_OLD")
    [[ -n "$OPT_FQBN" ]] && fqbns=("$OPT_FQBN")

    if ((OPT_COMPILE_ONLY)); then
        local fqbn
        for fqbn in "${fqbns[@]}"; do
            if compile_sketch "$fqbn"; then
                if ((OPT_DRY)); then
                    printf 'PASS (dry-run): nothing was changed; a real run would compile %s for %s\n' "$SKETCH_NAME" "$fqbn"
                else
                    printf 'PASS: %s compiles for %s (%s)\n' "$SKETCH_NAME" "$fqbn" "$USAGE_SUMMARY"
                fi
                return 0
            fi
        done
        fail "the sketch does not compile" "see the compiler output above"
    fi

    if ! detect_port; then
        if ((OPT_DRY)); then
            warn "no serial port found - a real run would stop here; the plan below assumes /dev/ttyUSB0"
            PORT="/dev/ttyUSB0"
        else
            fail "no Arduino Nano found: no $DEV_DIR/serial/by-id/*, $DEV_DIR/ttyUSB* or $DEV_DIR/ttyACM* device" \
                "connect the Nano with a USB DATA cable (not a charge-only one), then check 'dmesg | tail' and 'lsusb'; name the port with --port"
        fi
    fi

    stop_server

    local flashed="" fqbn
    for fqbn in "${fqbns[@]}"; do
        compile_sketch "$fqbn" || continue
        if upload_sketch "$fqbn" "$PORT"; then
            flashed="$fqbn"
            break
        fi
        if [[ "$fqbn" == "$FQBN_NEW" && ${#fqbns[@]} -gt 1 ]]; then
            log "retrying with the old-bootloader variant"
        fi
    done
    [[ -n "$flashed" ]] || fail "compile or upload failed for ${fqbns[*]}" \
        "read the messages above: 'not in sync' = wrong bootloader/baud, 'permission denied' = dialout group, 'busy' = stop peri-server, port missing = cable/board"

    if ((OPT_DRY)); then
        printf 'PASS (dry-run): nothing was changed; a real run would flash %s to %s\n' "$SKETCH_NAME" "$PORT"
        return 0
    fi
    if ((OPT_SKIP_VERIFY)); then
        printf 'PASS: flashed %s to %s with %s (verification skipped)\n' "$SKETCH_NAME" "$PORT" "$flashed"
        return 0
    fi
    if ! verify_firmware "$PORT"; then
        fail "uploaded, but the Nano did not answer HELLO with a PERI-HEAD banner on $PORT" \
            "check the wiring/port, try again (the board resets when the port opens), or open the port at 115200 baud and type HELLO"
    fi
    printf 'PASS: flashed %s to %s with %s; device says: %s\n' "$SKETCH_NAME" "$PORT" "$flashed" "${VERIFY_REPLY:-(dry run)}"
}

main "$@"
