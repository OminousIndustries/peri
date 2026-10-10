# shellcheck shell=bash
# shellcheck disable=SC2034  # LAST_CHANGED etc. are public API read by the scripts that source this file
# lib.sh - shared helpers for the Peri installer. SOURCE this file; never execute it.
#
# Conventions
#   * Every path argument is the path on the *target* system (e.g. /etc/asound.conf). Helpers map it under
#     $PERI_ROOT, so the whole installer can be exercised against a scratch directory:
#         PERI_ROOT=/tmp/fakeroot ./install.sh --yes --only display,audio,boot
#   * PERI_ROOT set  => "fake root": files are really edited under the prefix, but commands that would change the
#     live system (apt, systemctl, useradd, ...) are only logged (see sysrun).
#   * DRY_RUN=1      => nothing is changed anywhere; file edits print a unified diff instead.
#   * Everything edited gets a one-time backup FILE.peri-bak (the *original* is never overwritten by later runs) and an
#     entry in the manifest, so uninstall.sh can restore/remove precisely what the installer touched.
#   * Idempotent by construction: helpers compare before writing and report "unchanged"; changes_count tells how many writes happened.
#   * All human-readable logging goes to stderr (and $PERI_LOG_FILE); stdout is left for machine-readable output.
#
# Public API (see the definitions below for details):
#   logging   : info warn err ok skip step debug die
#   guards    : have is_fakeroot is_dry mutating_ok require_root rp pkg_installed pkg_available user_exists group_exists
#   commands  : sysrun sysrun_soft apt_update_once apt_install service_enable service_disable daemon_reload as_user
#   files     : write_file install_file render_to backup_file ensure_line remove_line_matching comment_out_matching
#               set_managed_block kv_set cmdline_set cmdline_replace_token cmdline_remove_token
#               mkdir_p symlink_force remove_created
#   manifest  : manifest_add manifest_has manifest_list
#   misc      : need_reboot confirm now_iso summarize_changes

if [[ -n "${_PERI_LIB_LOADED:-}" ]]; then
    return 0
fi
_PERI_LIB_LOADED=1

: "${PERI_ROOT:=}"
PERI_ROOT="${PERI_ROOT%/}"
: "${DRY_RUN:=0}"
: "${ASSUME_YES:=0}"
: "${PERI_DEBUG:=0}"
: "${PERI_STEP:=}"
: "${PERI_SRC:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${PERI_LOG_FILE:=${PERI_ROOT}/var/log/peri-install.log}"
: "${PERI_STATE_INSTALL_DIR:=${PERI_ROOT}/var/lib/peri-install}"
: "${PERI_MANIFEST:=${PERI_STATE_INSTALL_DIR}/manifest}"
: "${PERI_REBOOT_FLAG:=${PERI_STATE_INSTALL_DIR}/reboot-required}"

# Change accounting must survive subshells (`printf ... | write_file`) and child scripts, so it lives in a file
# (one line per change) whose path is exported; install.sh creates it once for all steps.
if [[ -z "${PERI_CHANGE_LOG:-}" ]]; then
    PERI_CHANGE_LOG=$(mktemp "${TMPDIR:-/tmp}/peri-changes.XXXXXX")
    export PERI_CHANGE_LOG
fi
LAST_CHANGED=0                 # 1 when the most recent write_file/edit helper changed something (same shell only)

# _note_change DESC : a real change was made.   _note_would DESC : a dry run would have changed something.
_note_change() { printf 'write\t%s\n' "$1" >> "$PERI_CHANGE_LOG"; }
_note_would()  { printf 'would\t%s\n' "$1" >> "$PERI_CHANGE_LOG"; }
# changes_count [write|would] : number of changes recorded so far by this installer run (all steps).
changes_count() { awk -F'\t' -v k="${1:-write}" '$1==k {n++} END {print n+0}' "$PERI_CHANGE_LOG" 2>/dev/null; }

# In fake-root mode, tests may drop mock executables (aplay, amixer, apt-cache, ...) into $PERI_ROOT/mockbin.
if [[ -n "$PERI_ROOT" && -d "$PERI_ROOT/mockbin" ]]; then
    case ":$PATH:" in *":$PERI_ROOT/mockbin:"*) ;; *) PATH="$PERI_ROOT/mockbin:$PATH" ;; esac
    export PATH
fi

# ----------------------------------------------------------------------------------------------- logging

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'; _C_CYN=$'\033[36m'; _C_DIM=$'\033[2m'; _C_BLD=$'\033[1m'; _C_OFF=$'\033[0m'
else
    _C_RED=""; _C_YEL=""; _C_GRN=""; _C_CYN=""; _C_DIM=""; _C_BLD=""; _C_OFF=""
fi

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# _log LEVEL COLOR MESSAGE... : print to stderr and append (uncoloured) to the log file.
_log() {
    local level="$1" color="$2"; shift 2
    local msg="$*" prefix=""
    [[ -n "$PERI_STEP" ]] && prefix="[${PERI_STEP}] "
    printf '%s%-5s%s %s%s\n' "$color" "$level" "$_C_OFF" "$prefix" "$msg" >&2 || true   # a vanished terminal/pipe must not abort an install
    # A dry run must not touch anything (not even the log file, which lives under $PERI_ROOT in fake-root mode).
    if [[ -n "${PERI_LOG_FILE:-}" && "$DRY_RUN" != 1 ]]; then
        mkdir -p "$(dirname "$PERI_LOG_FILE")" 2>/dev/null || true
        printf '%s %-5s %s%s\n' "$(now_iso)" "$level" "$prefix" "$msg" >> "$PERI_LOG_FILE" 2>/dev/null || true
    fi
    return 0
}
info()  { _log "INFO"  "$_C_CYN" "$*"; }
warn()  { _log "WARN"  "$_C_YEL" "$*"; }
err()   { _log "ERROR" "$_C_RED" "$*"; }
ok()    { _log "OK"    "$_C_GRN" "$*"; }
skip()  { _log "SKIP"  "$_C_DIM" "$*"; }          # "not doing X because Y" - always say why
debug() { [[ "$PERI_DEBUG" == 1 ]] && _log "DEBUG" "$_C_DIM" "$*"; return 0; }
step()  { _log "STEP"  "$_C_BLD" "==== $* ===="; }
die()   { err "$1"; exit "${2:-1}"; }

# ---------------------------------------------------------------------------------------------- guards

have()         { command -v "$1" >/dev/null 2>&1; }
is_fakeroot()  { [[ -n "$PERI_ROOT" ]]; }
is_dry()       { [[ "$DRY_RUN" == 1 ]]; }
mutating_ok()  { ! is_dry && ! is_fakeroot; }   # true only when we may change the live system
rp()           { printf '%s%s' "$PERI_ROOT" "$1"; }   # map a target path under PERI_ROOT

require_root() {
    if mutating_ok && [[ "$(id -u)" -ne 0 ]]; then
        die "This step must run as root (use sudo)." 2
    fi
}

# pkg_installed PKG : is the Debian package installed? (PERI_FAKE_PKGS="a b c" overrides in fake-root mode)
pkg_installed() {
    if is_fakeroot; then
        [[ " ${PERI_FAKE_PKGS:-} " == *" $1 "* ]]
        return
    fi
    have dpkg && dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'
}

# pkg_available PKG : does apt know an installable candidate? (PERI_FAKE_AVAILABLE_PKGS overrides in fake-root mode)
pkg_available() {
    if is_fakeroot; then
        [[ " ${PERI_FAKE_AVAILABLE_PKGS:-} ${PERI_FAKE_PKGS:-} " == *" $1 "* ]]
        return
    fi
    have apt-cache || return 1
    local cand
    cand=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
    [[ -n "$cand" && "$cand" != "(none)" ]]
}

# user_exists NAME / group_exists NAME : account lookups. In fake-root mode the machine running the tests must not matter:
# no user exists (PERI_FAKE_USERS="a b" adds some) and the usual Raspberry Pi OS groups exist (PERI_FAKE_GROUPS overrides).
user_exists() {
    if is_fakeroot; then [[ " ${PERI_FAKE_USERS:-} " == *" $1 "* ]]; return; fi
    getent passwd "$1" >/dev/null 2>&1
}
group_exists() {
    if is_fakeroot; then [[ " ${PERI_FAKE_GROUPS-audio video input render gpio dialout plugdev} " == *" $1 "* ]]; return; fi
    getent group "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------------- command running

# sysrun CMD... : run a command that changes the live system. Skipped (but logged) in dry-run and fake-root mode.
# Output is shown and appended to the log. Returns the command's exit status.
sysrun() {
    if ! mutating_ok; then
        if is_dry; then _log "DRY" "$_C_DIM" "would run: $*"; else _log "FAKE" "$_C_DIM" "skipped (fake root): $*"; fi
        return 0
    fi
    _log "RUN" "$_C_DIM" "+ $*"
    local rc
    if [[ -n "${PERI_LOG_FILE:-}" && -w "$(dirname "$PERI_LOG_FILE")" ]]; then
        "$@" 2>&1 | tee --output-error=warn -a "$PERI_LOG_FILE" >&2
        rc=${PIPESTATUS[0]}
    else
        "$@" >&2
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then _log "WARN" "$_C_YEL" "command exited with status $rc: $*"; fi
    return "$rc"
}

# sysrun_soft CMD... : like sysrun but a failure is only a warning (always returns 0).
sysrun_soft() { sysrun "$@" || true; }

# apt_update_once : `apt-get update` at most once per 30 minutes (marker file); logged only in dry-run / fake-root mode.
apt_update_once() {
    local marker="${PERI_STATE_INSTALL_DIR}/apt-updated"
    if ! mutating_ok; then _log "DRY" "$_C_DIM" "would run: apt-get update"; return 0; fi
    if [[ -f "$marker" && $(( $(date +%s) - $(stat -c %Y "$marker") )) -lt 1800 ]]; then
        skip "apt package index refreshed less than 30 minutes ago"; return 0
    fi
    # --allow-releaseinfo-change: an older image whose cached Release says "stable" would otherwise refuse to update once
    # the suite became "oldstable" (unattended installs cannot answer that question); Acquire::Retries helps flaky Wi-Fi.
    if sysrun apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update --allow-releaseinfo-change; then
        mkdir -p "$(dirname "$marker")"; touch "$marker"
    else
        warn "apt-get update failed (offline?); continuing with the existing package index"
    fi
    return 0
}

# apt_install PKG... : install packages non-interactively; records them in the manifest (only those newly installed).
apt_install() {
    local p missing=()
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    if [[ ${#missing[@]} -eq 0 ]]; then skip "packages already installed: $*"; return 0; fi
    info "installing packages: ${missing[*]}"
    if ! mutating_ok; then _log "DRY" "$_C_DIM" "would run: apt-get install -y ${missing[*]}"; return 0; fi
    # --force-confdef/--force-confold: never stop at a dpkg configuration-file question (EOF there would fail the package).
    sysrun env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        install -y --no-install-recommends "${missing[@]}" || return $?
    for p in "${missing[@]}"; do manifest_add pkg "$p"; done
    _note_change "packages: ${missing[*]}"
}

# service_enable UNIT [--now] / service_disable UNIT [--now] : systemctl wrappers that remember the previous state.
service_enable() {
    local unit="$1" now="${2:-}" state="unknown"
    have systemctl && state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    if mutating_ok; then
        if [[ "$state" == enabled && -z "$now" ]]; then skip "$unit already enabled"; return 0; fi
        [[ "$state" != enabled ]] && manifest_add svc-was-disabled "$unit"
        sysrun systemctl enable ${now:+--now} "$unit"
        _note_change "enabled $unit"
    else
        sysrun systemctl enable ${now:+--now} "$unit"
    fi
}
service_disable() {
    local unit="$1" now="${2:-}" state="unknown"
    have systemctl && state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    if mutating_ok; then
        if [[ "$state" != enabled && "$state" != static && -z "$now" ]]; then skip "$unit not enabled (state: $state)"; return 0; fi
        [[ "$state" == enabled ]] && manifest_add svc-was-enabled "$unit"
        sysrun systemctl disable ${now:+--now} "$unit"
        _note_change "disabled $unit"
    else
        sysrun systemctl disable ${now:+--now} "$unit"
    fi
}
daemon_reload() { sysrun systemctl daemon-reload; }

# as_user USER CMD... : run CMD as USER with XDG_RUNTIME_DIR set (for wpctl/pactl/amixer/chromium checks).
as_user() {
    local user="$1"; shift
    local uid; uid=$(id -u "$user" 2>/dev/null) || { warn "as_user: no such user: $user"; return 1; }
    if [[ "$(id -u)" -eq "$uid" ]]; then "$@"; return; fi
    if have runuser; then
        runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/$uid" "$@"
    else
        sudo -n -u "$user" env "XDG_RUNTIME_DIR=/run/user/$uid" "$@"
    fi
}

# confirm "Question?" : true when --yes was given; otherwise asks on the terminal (default: no; false when not a tty).
confirm() {
    [[ "$ASSUME_YES" == 1 ]] && return 0
    if [[ ! -t 0 ]]; then warn "Not interactive and --yes not given: assuming 'no' for: $1"; return 1; fi
    local reply; read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}

# ------------------------------------------------------------------------------------------- manifest

# manifest_add KIND VALUE : remember something the installer did (deduplicated). Kinds used:
#   created <path>          file created by us (uninstall removes it)
#   modified <path>         pre-existing file we edited (uninstall restores <path>.peri-bak)
#   pkg <name>              package we installed (uninstall --purge-packages removes it)
#   svc-was-enabled <unit>  unit that was enabled before we disabled it (uninstall re-enables it)
#   svc-was-disabled <unit> unit that was disabled before we enabled it
#   default-target <name>   systemd default target before we changed it
#   user <name>             account we created
manifest_add() {
    is_dry && return 0
    manifest_has "$1" "$2" && return 0
    mkdir -p "$(dirname "$PERI_MANIFEST")" 2>/dev/null || return 0
    printf '%s\t%s\n' "$1" "$2" >> "$PERI_MANIFEST"
}
manifest_has()  { [[ -f "$PERI_MANIFEST" ]] && grep -qxF "$(printf '%s\t%s' "$1" "$2")" "$PERI_MANIFEST"; }
manifest_list() { [[ -f "$PERI_MANIFEST" ]] && awk -F'\t' -v k="$1" '$1==k {print $2}' "$PERI_MANIFEST"; return 0; }

# ---------------------------------------------------------------------------------------------- files

# backup_file PATH : one-time copy of the original to PATH.peri-bak (never overwritten) unless we created PATH ourselves.
backup_file() {
    local dest="$1" real; real=$(rp "$dest")
    [[ -e "$real" || -L "$real" ]] || return 0
    manifest_has created "$dest" && return 0
    if [[ -e "$real.peri-bak" || -L "$real.peri-bak" ]]; then return 0; fi
    if is_dry; then _log "DRY" "$_C_DIM" "would back up $dest -> $dest.peri-bak"; return 0; fi
    cp -a "$real" "$real.peri-bak" && manifest_add modified "$dest"
    debug "backed up $dest"
}

# _commit_file DEST NEWCONTENT_FILE [MODE] [OWNER:GROUP]
#   Replace DEST with NEWCONTENT_FILE if different (atomic rename, backup, manifest). Sets LAST_CHANGED.
#   MODE defaults to the existing file's mode, or 0644 for a new file. OWNER defaults to unchanged/current.
_commit_file() {
    local dest="$1" newfile="$2" mode="${3:-}" owner="${4:-}" real existed=0
    real=$(rp "$dest"); LAST_CHANGED=0
    [[ -e "$real" || -L "$real" ]] && existed=1
    if [[ $existed -eq 1 && ! -L "$real" && -f "$real" ]] && cmp -s "$newfile" "$real"; then
        _fix_perms "$dest" "$mode" "$owner"
        skip "unchanged: $dest"
        return 0
    fi
    if is_dry; then
        _note_would "$dest"; LAST_CHANGED=1
        if [[ $existed -eq 1 ]]; then
            _log "DRY" "$_C_DIM" "would modify $dest:"
            diff -u --label "a$dest" --label "b$dest" "$real" "$newfile" >&2 || true
        else
            _log "DRY" "$_C_DIM" "would create $dest ($(wc -l < "$newfile") lines)"
        fi
        return 0
    fi
    [[ $existed -eq 1 ]] && backup_file "$dest"
    mkdir -p "$(dirname "$real")"
    local tmp="$real.peri-tmp.$$"
    if [[ $existed -eq 1 && -f "$real" && ! -L "$real" ]]; then cp -p "$real" "$tmp"; else : > "$tmp"; fi
    cat "$newfile" > "$tmp"
    [[ -z "$mode" && $existed -eq 0 ]] && mode=0644
    [[ -n "$mode" ]] && chmod "$mode" "$tmp"
    if [[ -n "$owner" ]] && ! is_fakeroot; then chown "$owner" "$tmp"; fi
    mv -f "$tmp" "$real"
    [[ $existed -eq 0 ]] && manifest_add created "$dest"
    _note_change "$dest"; LAST_CHANGED=1
    ok "wrote $dest"
}

# _fix_perms DEST MODE OWNER : bring mode/owner of an unchanged file in line (only when explicitly requested).
_fix_perms() {
    local dest="$1" mode="$2" owner="$3" real cur
    real=$(rp "$dest")
    if [[ -n "$mode" ]]; then
        cur=$(stat -c '%a' "$real" 2>/dev/null || true)
        if [[ -n "$cur" && $((8#$cur)) -ne $((8#${mode#0})) ]]; then
            if is_dry; then _log "DRY" "$_C_DIM" "would chmod $mode $dest"; else chmod "$mode" "$real"; _note_change "chmod $dest"; LAST_CHANGED=1; fi
        fi
    fi
    if [[ -n "$owner" ]] && ! is_fakeroot; then
        cur=$(stat -c '%U:%G' "$real" 2>/dev/null || true)
        if [[ -n "$cur" && "$cur" != "$owner" ]]; then
            if is_dry; then _log "DRY" "$_C_DIM" "would chown $owner $dest"; else chown "$owner" "$real" && { _note_change "chown $dest"; LAST_CHANGED=1; }; fi
        fi
    fi
    return 0
}

# write_file DEST [MODE] [OWNER:GROUP] < content : create/replace a whole file from stdin.
write_file() {
    local dest="$1" mode="${2:-}" owner="${3:-}" tmp
    tmp=$(mktemp); cat > "$tmp"
    _commit_file "$dest" "$tmp" "$mode" "$owner"
    rm -f "$tmp"
}

# install_file SRC DEST [MODE] [OWNER:GROUP] : like write_file with content from a file in the source tree.
install_file() {
    [[ -f "$1" ]] || { err "install_file: missing source $1"; return 1; }
    write_file "$2" "${3:-}" "${4:-}" < "$1"
}

# render_to SRC DEST MODE OWNER:GROUP KEY=VALUE... : copy a template replacing @KEY@ with VALUE (used for unit files).
render_to() {
    local src="$1" dest="$2" mode="$3" owner="$4"; shift 4
    local content kv
    [[ -f "$src" ]] || { err "render_to: missing template $src"; return 1; }
    content=$(cat "$src"; printf x); content=${content%x}
    # the replacement is quoted: bash 5.2 (patsub_replacement) would otherwise expand every unquoted & in it to the matched text
    for kv in "$@"; do content=${content//"@${kv%%=*}@"/"${kv#*=}"}; done
    if [[ "$content" == *@[A-Z_]*@* ]]; then
        local left; left=$(printf '%s' "$content" | grep -o '@[A-Z_]\+@' | sort -u | tr '\n' ' ') || true   # grep exits 1 on no match
        [[ -n "$left" ]] && warn "render_to: unresolved placeholders in $dest: $left"
    fi
    local tmp; tmp=$(mktemp); printf '%s' "$content" > "$tmp"
    _commit_file "$dest" "$tmp" "$mode" "$owner"; rm -f "$tmp"
}

# ensure_line DEST LINE : make sure the exact line exists in DEST (appended if missing; file created if absent).
ensure_line() {
    local dest="$1" line="$2" real tmp; real=$(rp "$dest"); tmp=$(mktemp)
    if [[ -f "$real" ]]; then
        if grep -qxF -- "$line" "$real"; then rm -f "$tmp"; skip "line already present in $dest: $line"; LAST_CHANGED=0; return 0; fi
        cat "$real" > "$tmp"
        [[ -s "$tmp" && "$(tail -c1 "$tmp" | xxd -p)" != "0a" ]] && printf '\n' >> "$tmp"
    fi
    printf '%s\n' "$line" >> "$tmp"
    _commit_file "$dest" "$tmp"
    rm -f "$tmp"
}

# remove_line_matching DEST ERE : delete lines matching the extended regex (backed up first).
remove_line_matching() {
    local dest="$1" re="$2" real tmp; real=$(rp "$dest")
    [[ -f "$real" ]] || { LAST_CHANGED=0; return 0; }
    grep -Eq -- "$re" "$real" || { LAST_CHANGED=0; return 0; }
    tmp=$(mktemp); grep -Ev -- "$re" "$real" > "$tmp" || true
    _commit_file "$dest" "$tmp"; rm -f "$tmp"
}

# comment_out_matching DEST ERE [TAG] : prefix matching *active* lines with "#TAG: " (default TAG=peri-disabled).
# Already-commented lines never match ^ anchored patterns, so this is idempotent. Lines inside a peri managed block
# are left alone.
comment_out_matching() {
    local dest="$1" re="$2" tag="${3:-peri-disabled}" real tmp; real=$(rp "$dest")
    [[ -f "$real" ]] || { LAST_CHANGED=0; return 0; }
    tmp=$(mktemp)
    awk -v re="$re" -v tag="$tag" '
        /^# >>> peri:/ {inblk=1}
        { if (!inblk && $0 ~ re) print "#" tag ": " $0; else print }
        /^# <<< peri:/ {inblk=0}' "$real" > "$tmp"
    _commit_file "$dest" "$tmp"; rm -f "$tmp"
}

# set_managed_block DEST ID < body : keep a block delimited by "# >>> peri:ID >>>" / "# <<< peri:ID <<<" in DEST.
# Replaced in place when it exists, appended when not; an empty body removes the block. Works for any '#'-comment file
# (config.txt, sysctl, ...).
set_managed_block() {
    local dest="$1" id="$2" real tmp body start end
    real=$(rp "$dest"); body=$(cat); tmp=$(mktemp)
    start="# >>> peri:${id} >>>"; end="# <<< peri:${id} <<<"
    if [[ -f "$real" ]] && grep -qxF "$start" "$real"; then
        BODY="$body" awk -v s="$start" -v e="$end" '
            $0==s { if (ENVIRON["BODY"] != "") { print s; print ENVIRON["BODY"]; print e }; skip=1; next }
            $0==e { skip=0; next }
            !skip { print }' "$real" > "$tmp"
    else
        [[ -f "$real" ]] && cat "$real" > "$tmp"
        if [[ -n "$body" ]]; then
            [[ -s "$tmp" && "$(tail -c1 "$tmp" | xxd -p)" != "0a" ]] && printf '\n' >> "$tmp"
            printf '%s\n%s\n%s\n' "$start" "$body" "$end" >> "$tmp"
        elif [[ ! -f "$real" ]]; then
            rm -f "$tmp"; LAST_CHANGED=0; return 0
        fi
    fi
    _commit_file "$dest" "$tmp"; rm -f "$tmp"
}

# kv_set DEST KEY VALUE : in a KEY=VALUE file (KEY may itself contain '=', e.g. dtparam=audio) set the first *active*
# line to KEY=VALUE, drop later duplicates, or append when missing.
kv_set() {
    local dest="$1" key="$2" val="$3" real tmp; real=$(rp "$dest"); tmp=$(mktemp)
    if [[ -f "$real" ]]; then
        awk -v key="$key" -v val="$val" '
            BEGIN { pre = key "="; n = length(pre); done = 0 }
            { line = $0; sub(/^[ \t]+/, "", line) }
            substr(line, 1, n) == pre { if (!done) { print pre val; done = 1 } ; next }
            { print }
            END { if (!done) print pre val }' "$real" > "$tmp"
        # awk's END append does not guarantee a newline before it when the file lacked one; awk print always ends lines.
    else
        printf '%s=%s\n' "$key" "$val" > "$tmp"
    fi
    _commit_file "$dest" "$tmp"; rm -f "$tmp"
}

# cmdline_set DEST TOKEN : kernel command line (single line). TOKEN is "flag" or "key=value"; an existing token with the
# same key is replaced, otherwise TOKEN is appended.
cmdline_set() {
    local dest="$1" token="$2" real tmp; real=$(rp "$dest"); tmp=$(mktemp)
    [[ -f "$real" ]] || { warn "cmdline_set: $dest does not exist"; rm -f "$tmp"; LAST_CHANGED=0; return 1; }
    TOKEN="$token" awk '
        BEGIN { tok = ENVIRON["TOKEN"]; key = tok; sub(/=.*/, "", key) }
        NR == 1 {
            out = ""; found = 0
            for (i = 1; i <= NF; i++) {
                k = $i; sub(/=.*/, "", k)
                if (k == key) { if (!found) { out = out (out == "" ? "" : " ") tok; found = 1 } }
                else out = out (out == "" ? "" : " ") $i
            }
            if (!found) out = out (out == "" ? "" : " ") tok
            print out; next }
        { print }' "$real" > "$tmp"
    _commit_file "$dest" "$tmp"; rm -f "$tmp"
}
# cmdline_replace_token DEST OLD NEW : replace an exact token (e.g. console=tty1 -> console=tty3); no-op when absent.
cmdline_replace_token() {
    local dest="$1" old="$2" replacement="$3" real tmp; real=$(rp "$dest"); tmp=$(mktemp)
    [[ -f "$real" ]] || { rm -f "$tmp"; LAST_CHANGED=0; return 1; }
    OLD="$old" NEW="$replacement" awk '
        NR == 1 { out = ""; for (i = 1; i <= NF; i++) { t = ($i == ENVIRON["OLD"]) ? ENVIRON["NEW"] : $i
                  if (t == "") continue; out = out (out == "" ? "" : " ") t } print out; next }
        { print }' "$real" > "$tmp"
    _commit_file "$dest" "$tmp"; rm -f "$tmp"
}
# cmdline_remove_token DEST TOKEN_OR_KEY : remove tokens equal to TOKEN, or starting with "KEY=" when TOKEN ends with '='.
cmdline_remove_token() {
    local dest="$1" tok="$2" real tmp; real=$(rp "$dest"); tmp=$(mktemp)
    [[ -f "$real" ]] || { rm -f "$tmp"; LAST_CHANGED=0; return 1; }
    TOK="$tok" awk '
        NR == 1 { t = ENVIRON["TOK"]; out = ""
                  for (i = 1; i <= NF; i++) {
                      drop = ($i == t) || (substr(t, length(t)) == "=" && index($i, t) == 1)
                      if (!drop) out = out (out == "" ? "" : " ") $i }
                  print out; next }
        { print }' "$real" > "$tmp"
    _commit_file "$dest" "$tmp"; rm -f "$tmp"
}

# mkdir_p DIR [MODE] [OWNER:GROUP]
mkdir_p() {
    local dir="$1" mode="${2:-}" owner="${3:-}" real; real=$(rp "$dir")
    if [[ ! -d "$real" ]]; then
        if is_dry; then _log "DRY" "$_C_DIM" "would create directory $dir"; return 0; fi
        mkdir -p "$real"; _note_change "mkdir $dir"
    fi
    if ! is_dry; then
        [[ -n "$mode" ]] && chmod "$mode" "$real"
        [[ -n "$owner" ]] && ! is_fakeroot && chown "$owner" "$real"
    fi
    return 0
}

# symlink_force TARGET LINK
symlink_force() {
    local target="$1" link="$2" real; real=$(rp "$link")
    if [[ -L "$real" && "$(readlink "$real")" == "$target" ]]; then skip "symlink already correct: $link"; return 0; fi
    if is_dry; then _log "DRY" "$_C_DIM" "would symlink $link -> $target"; return 0; fi
    [[ -e "$real" || -L "$real" ]] && backup_file "$link"
    mkdir -p "$(dirname "$real")"; ln -sfn "$target" "$real"
    manifest_add created "$link"; _note_change "symlink $link"
}

# remove_created PATH : delete a path (used by uninstall for files listed as "created").
remove_created() {
    local real; real=$(rp "$1")
    [[ -e "$real" || -L "$real" ]] || return 0
    if is_dry; then _log "DRY" "$_C_DIM" "would remove $1"; return 0; fi
    rm -rf -- "$real"; ok "removed $1"
}

# ---------------------------------------------------------------------------------------------- misc

# need_reboot REASON : remember (and announce) that the change only takes effect after a reboot.
need_reboot() {
    warn "reboot required: $1"
    if is_dry; then    # nothing is written in a dry run; install.sh may collect the reasons to tell the user what a real run needs
        if [[ -n "${PERI_DRY_REBOOT_LOG:-}" ]]; then printf '%s\n' "$1" >> "$PERI_DRY_REBOOT_LOG"; fi
        return 0
    fi
    mkdir -p "$(dirname "$PERI_REBOOT_FLAG")" 2>/dev/null || return 0
    grep -qxF "$1" "$PERI_REBOOT_FLAG" 2>/dev/null || printf '%s\n' "$1" >> "$PERI_REBOOT_FLAG"
}

summarize_changes() {
    if is_dry; then info "dry run: $(changes_count would) change(s) would be made"; else info "$(changes_count write) change(s) made"; fi
}
