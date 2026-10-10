#!/usr/bin/env bash
# install-app.sh - installer step "app": the service account, the directories, the application files and its configuration.
#
#   sudo scripts/install-app.sh          (normally run by install.sh; safe to re-run: this is also the UPDATE step)
#   DRY_RUN=1 scripts/install-app.sh     (rsync -n + diffs, changes nothing)
#
# What it does
#   1. user "peri": normal account (UID >= 1000), home /var/lib/peri, shell /bin/bash, password locked, member of
#      audio video input render gpio dialout plugdev (only groups that exist); an existing user only gets groups/home fixed.
#      `loginctl enable-linger peri` keeps its user manager (PipeWire) alive without a login.
#   2. directories: /opt/peri root:root 0755, /etc/peri root:root 0755, /var/lib/peri peri:peri 0750 (settings, calibration).
#   3. copies server web config scripts firmware assets systemd docs VERSION install.sh uninstall.sh from the source tree
#      into /opt/peri with rsync --delete (stale files disappear; __pycache__ *.pyc .venv tests .git node_modules
#      *.peri-bak and config/peri.env are NEVER copied). Skipped when the source tree already is /opt/peri.
#      Files end up root-owned, world-readable, never group/world-writable; scripts executable. The server is byte-compiled.
#   4. /etc/peri/peri.env (root:peri 0640): created from $PERI_SRC/config/peri.env if that exists, else from
#      config/peri.env.example. NEVER overwritten afterwards. Options that were given explicitly are applied even to an
#      existing file, and only on their own line: PERI_OPT_OPENAI_KEY -> OPENAI_API_KEY, PERI_OPT_HEAD (not auto) ->
#      PERI_HEAD_DRIVER. Optional variables are appended as commented, documented lines when missing.
#      The key is never printed or logged (not even in dry-run diffs).
#   5. /usr/local/bin/peri-config (from scripts/peri-config).
#
# Environment: the PERI_OPT_* variables from install.sh (PERI_OPT_OPENAI_KEY, PERI_OPT_HEAD), PERI_SRC, PERI_ROOT, DRY_RUN.
# Test hook: PERI_FORCE_NO_RSYNC=1 exercises the tar/diff fallback used when rsync is not installed.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=detect.sh
. "$HERE/detect.sh"
PERI_STEP="${PERI_STEP:-app}"
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"      # sbin tools are not in the PATH of a plain `su`
umask 022                          # predictable modes whoever calls us (a 077/002 umask would leak into /opt/peri)

PERI_USER=peri
PERI_HOME=/var/lib/peri
PERI_INSTALL=/opt/peri
PERI_ETC=/etc/peri
ENV_FILE=/etc/peri/peri.env
WANTED_GROUPS=(audio video input render gpio dialout plugdev)
APP_SUBDIRS=(server web config scripts firmware assets systemd docs)
APP_FILES=(VERSION install.sh uninstall.sh)
# Never copied into /opt/peri (rsync patterns; anchored patterns are relative to the directory being synced).
EXCLUDES=('--exclude=__pycache__/' '--exclude=*.pyc' '--exclude=.venv/' '--exclude=tests/' '--exclude=.git/'
          '--exclude=node_modules/' '--exclude=*.peri-bak' '--exclude=.pytest_cache/' '--exclude=.DS_Store')

TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}"; return 0; }
trap cleanup EXIT

usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }
join_csv() { local IFS=,; printf '%s' "$*"; }

# ------------------------------------------------------------------------------------------ source check

check_source() {
    [[ -d "$PERI_SRC/scripts" ]] || die "source tree $PERI_SRC has no scripts/ directory: run install.sh from the Peri folder"
    if [[ ! -f "$PERI_SRC/server/peri_server/__main__.py" ]]; then
        die "source tree $PERI_SRC has no server/peri_server/__main__.py: the Peri server is missing from this copy of the folder (incomplete download/copy?)"
    fi
    local d
    for d in web config systemd; do
        [[ -d "$PERI_SRC/$d" ]] || warn "source tree has no $d/ directory: the installed app will lack it"
    done
    return 0
}

# ------------------------------------------------------------------------------------------ user + linger

ensure_user() {
    local g want=() missing=() cur cur_home cur_shell
    for g in "${WANTED_GROUPS[@]}"; do
        if group_exists "$g"; then want+=("$g"); else skip "group '$g' does not exist on this system: $PERI_USER will not be added to it"; fi
    done

    if user_exists "$PERI_USER"; then
        info "user $PERI_USER already exists (uid $(id -u "$PERI_USER" 2>/dev/null || echo '?')): only checking home, shell and groups"
        cur=" $(id -nG "$PERI_USER" 2>/dev/null || true) "
        for g in "${want[@]}"; do [[ "$cur" == *" $g "* ]] || missing+=("$g"); done
        if [[ ${#missing[@]} -gt 0 ]]; then
            info "adding $PERI_USER to groups: ${missing[*]}"
            sysrun usermod -aG "$(join_csv "${missing[@]}")" "$PERI_USER" || die "usermod failed"
            mutating_ok && _note_change "usermod -aG ${missing[*]} $PERI_USER"
        else
            skip "$PERI_USER is already a member of: ${want[*]:-(none)}"
        fi
        cur_home=$(getent passwd "$PERI_USER" | cut -d: -f6)
        if [[ "$cur_home" != "$PERI_HOME" ]]; then
            warn "existing user $PERI_USER has home '$cur_home', expected $PERI_HOME: changing it (files are not moved)"
            sysrun usermod -d "$PERI_HOME" "$PERI_USER" || die "usermod -d failed"
            mutating_ok && _note_change "usermod -d $PERI_HOME $PERI_USER"
        fi
        cur_shell=$(getent passwd "$PERI_USER" | cut -d: -f7)
        case "$cur_shell" in
            */nologin|*/false|"")
                info "user $PERI_USER has shell '$cur_shell': switching to /bin/bash (needed for su/runuser based helpers)"
                sysrun usermod -s /bin/bash "$PERI_USER" || warn "could not change the shell of $PERI_USER"
                mutating_ok && _note_change "usermod -s /bin/bash $PERI_USER" ;;
        esac
        return 0
    fi

    local args=(-M -d "$PERI_HOME" -s /bin/bash -c "Peri device service account")
    if group_exists "$PERI_USER"; then args+=(-g "$PERI_USER"); else args+=(-U); fi
    [[ ${#want[@]} -gt 0 ]] && args+=(-G "$(join_csv "${want[@]}")")
    info "creating user $PERI_USER (normal account, home $PERI_HOME, locked password, groups: ${want[*]:-none})"
    sysrun useradd "${args[@]}" "$PERI_USER" || die "useradd failed: cannot create the service account $PERI_USER"
    if mutating_ok; then
        user_exists "$PERI_USER" || die "user $PERI_USER does not exist after useradd"
        manifest_add user "$PERI_USER"; _note_change "created user $PERI_USER"
    fi
}

ensure_linger() {
    local marker; marker=$(rp "/var/lib/systemd/linger/$PERI_USER")
    if ! is_fakeroot && [[ ! -d "${PERI_SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]; then
        skip "systemd is not the running init system: not enabling lingering for $PERI_USER"; return 0
    fi
    if [[ -e "$marker" ]]; then skip "lingering already enabled for $PERI_USER"; return 0; fi
    if ! is_fakeroot && ! have loginctl; then warn "loginctl not found: cannot enable lingering (the user manager will start with the first login/kiosk session)"; return 0; fi
    info "enabling lingering for $PERI_USER (its user manager and PipeWire then run without a login)"
    if sysrun loginctl enable-linger "$PERI_USER"; then
        mutating_ok && { manifest_add linger "$PERI_USER"; _note_change "enable-linger $PERI_USER"; }
    else
        warn "loginctl enable-linger $PERI_USER failed: the user manager will start with the first login/kiosk session instead"
    fi
    return 0
}

# ---------------------------------------------------------------------------------------------- directories

# _ensure_dir DIR MODE OWNER KIND : create/normalise a directory and remember in the manifest that we created it.
_ensure_dir() {
    local dir="$1" mode="$2" owner="$3" kind="$4" existed=1
    [[ -d "$(rp "$dir")" ]] || existed=0
    mkdir_p "$dir" "$mode" "$owner"
    if [[ $existed -eq 0 ]] && ! is_dry; then manifest_add "$kind" "$dir"; fi
    return 0
}

ensure_dirs() {
    _ensure_dir "$PERI_INSTALL" 0755 root:root tree
    _ensure_dir "$PERI_ETC" 0755 root:root datadir
    _ensure_dir "$PERI_HOME" 0750 "$PERI_USER:$PERI_USER" datadir
}

# fix_state_ownership : a root-run command (a manual chromium/verify run) may have left root-owned files in the state dir,
# after which the service user cannot write them. Self-heal on the real system.
fix_state_ownership() {
    mutating_ok || return 0
    local real; real=$(rp "$PERI_HOME")
    [[ -d "$real" ]] || return 0
    if [[ -n "$(find "$real" \( ! -user "$PERI_USER" -o ! -group "$PERI_USER" \) -print -quit 2>/dev/null)" ]]; then
        warn "files in $PERI_HOME are not owned by $PERI_USER (created by a root-run command?): fixing ownership"
        chown -R "$PERI_USER:$PERI_USER" "$real" && _note_change "chown -R $PERI_USER $PERI_HOME"
    fi
    return 0
}

# ------------------------------------------------------------------------------------------------ app copy

# _rsync_excludes_for SUB : the exclude list for one synced directory (config/ also never ships the real env file).
_rsync_excludes_for() {
    local sub="$1"; printf '%s\n' "${EXCLUDES[@]}"
    [[ "$sub" == config ]] && printf '%s\n' '--exclude=/peri.env' '--exclude=/.env'
    return 0
}

# _sync_rsync SUB SRC/ DEST/ : mirror one directory. Counts real changes (files/dirs created or changed, deletions), not
# directory mtimes. Prints the itemised list (first 30 lines) in dry-run.
_sync_rsync() {
    local sub="$1" src="$2" dest="$3" out n
    local -a args=(-rlt -c -O --delete --itemize-changes)      # -c: compare content, not mtimes (a copied folder has arbitrary mtimes)
    local x; while IFS= read -r x; do args+=("$x"); done < <(_rsync_excludes_for "$sub")
    is_dry && args+=(-n)
    out=$(rsync "${args[@]}" "$src" "$dest") || die "rsync failed for $sub/"
    n=$(printf '%s\n' "$out" | grep -Ec '^(>|<|c|\*deleting)' || true)
    if [[ "$n" -eq 0 ]]; then skip "$sub/ is up to date in $PERI_INSTALL"; return 0; fi
    if is_dry; then
        _note_would "app files: $sub/ ($n item(s))"
        info "would sync $sub/ -> $PERI_INSTALL/$sub/ ($n item(s)):"
        printf '%s\n' "$out" | grep -E '^(>|<|c|\*deleting)' | sed -n '1,30s/^/        /p' >&2
    else
        _note_change "app files: $sub/ ($n item(s)) -> $PERI_INSTALL/$sub/"
        ok "synced $sub/ -> $PERI_INSTALL/$sub/ ($n item(s))"
    fi
}

# _sync_fallback SUB SRC DEST : same job without rsync (tar + diff). Rewrites the directory when it differs at all.
_sync_fallback() {
    local sub="$1" src="$2" dest="$3"
    local -a dx=(-x __pycache__ -x '*.pyc' -x .venv -x tests -x .git -x node_modules -x '*.peri-bak' -x .pytest_cache -x .DS_Store)
    local -a tx=(--exclude=__pycache__ '--exclude=*.pyc' --exclude=.venv --exclude=tests --exclude=.git --exclude=node_modules
                 '--exclude=*.peri-bak' --exclude=.pytest_cache --exclude=.DS_Store)
    if [[ "$sub" == config ]]; then dx+=(-x peri.env -x .env); tx+=(--exclude=./peri.env --exclude=./.env); fi
    if [[ -d "$dest" ]] && diff -rq "${dx[@]}" "$src" "$dest" >/dev/null 2>&1; then skip "$sub/ is up to date in $PERI_INSTALL"; return 0; fi
    if is_dry; then
        _note_would "app files: $sub/ (tar fallback)"
        info "would replace $PERI_INSTALL/$sub/ with the source copy; differences:"
        diff -rq "${dx[@]}" "$src" "$dest" 2>&1 | sed -n '1,30s/^/        /p' >&2 || true
        return 0
    fi
    rm -rf "$dest"
    mkdir -p "$dest" || die "cannot recreate $dest"
    tar -C "$src" "${tx[@]}" -cf - . | tar -C "$dest" --no-same-owner -xf - || die "tar copy failed for $sub/"
    _note_change "app files: $sub/ (tar fallback) -> $PERI_INSTALL/$sub/"
    ok "copied $sub/ -> $PERI_INSTALL/$sub/ (rsync not available: tar fallback)"
}

# _sync_file NAME : one top-level file (VERSION, install.sh, uninstall.sh).
_sync_file() {
    local name="$1" src="$PERI_SRC/$1" dest; dest=$(rp "$PERI_INSTALL/$1")
    if [[ ! -f "$src" ]]; then skip "$name is not in the source tree: not copied"; return 0; fi
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then skip "$name is up to date in $PERI_INSTALL"; return 0; fi
    if is_dry; then _note_would "app file: $name"; info "would copy $name -> $PERI_INSTALL/$name"; return 0; fi
    mkdir -p "$(dirname "$dest")"
    cp -f "$src" "$dest.peri-tmp.$$" || die "cannot copy $name to $PERI_INSTALL (disk full?)"
    mv -f "$dest.peri-tmp.$$" "$dest" || die "cannot install $dest"
    _note_change "app file: $name -> $PERI_INSTALL/$name"
    ok "copied $name -> $PERI_INSTALL/$name"
}

sync_app() {
    local src_real dst_real sub use_rsync=1
    src_real=$(readlink -f "$PERI_SRC")
    dst_real=$(readlink -f "$(rp "$PERI_INSTALL")")
    if [[ "$src_real" == "$dst_real" ]]; then
        skip "the source tree already is $PERI_INSTALL (running from the installed copy): nothing to copy"
        return 0
    fi
    info "copying the application from $PERI_SRC to $PERI_INSTALL"
    if [[ "${PERI_FORCE_NO_RSYNC:-0}" == 1 ]] || ! have rsync; then
        use_rsync=0
        if [[ "${PERI_FORCE_NO_RSYNC:-0}" != 1 ]] && mutating_ok; then
            info "rsync is not installed: trying to install it"
            apt_update_once
            apt_install rsync && have rsync && use_rsync=1
        fi
        [[ $use_rsync -eq 1 ]] || warn "rsync is not available: using the tar/diff fallback"
    fi
    for sub in "${APP_SUBDIRS[@]}"; do
        if [[ ! -d "$PERI_SRC/$sub" ]]; then skip "source directory $sub/ does not exist: not copied"; continue; fi
        if ! is_dry; then mkdir -p "$(rp "$PERI_INSTALL/$sub")"; fi
        if [[ $use_rsync -eq 1 ]]; then _sync_rsync "$sub" "$PERI_SRC/$sub/" "$(rp "$PERI_INSTALL/$sub")/"
        else _sync_fallback "$sub" "$PERI_SRC/$sub" "$(rp "$PERI_INSTALL/$sub")"; fi
    done
    local f; for f in "${APP_FILES[@]}"; do _sync_file "$f"; done

    # The real env file must never be world-readable in /opt/peri (it holds the API key): belt and braces.
    local stray; stray=$(rp "$PERI_INSTALL/config/peri.env")
    if [[ -e "$stray" ]] && ! is_dry; then
        warn "removing $PERI_INSTALL/config/peri.env (a copy of the env file with secrets must not live in the app tree)"
        rm -f "$stray"; _note_change "removed stray $PERI_INSTALL/config/peri.env"
    fi
}

# fix_modes : root-owned, world-readable, nothing group/world-writable, scripts executable. rsync runs without -p so that
# existing modes are never fought over (which would make every re-run "change" something); this pass is idempotent.
fix_modes() {
    is_dry && return 0
    local root; root=$(rp "$PERI_INSTALL")
    [[ -d "$root" ]] || return 0
    local n changed=0 f mode want
    n=$(find "$root" -type d ! -perm 0755 -print | wc -l)
    if [[ "$n" -gt 0 ]]; then find "$root" -type d ! -perm 0755 -exec chmod 0755 {} +; changed=$((changed + n)); fi
    n=$(find "$root" -type f ! -perm 0644 ! -perm 0755 -print | wc -l)
    if [[ "$n" -gt 0 ]]; then find "$root" -type f ! -perm 0644 ! -perm 0755 -exec chmod 0644 {} +; changed=$((changed + n)); fi
    for f in "$root"/scripts/* "$root/install.sh" "$root/uninstall.sh"; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        want=0
        case "$f" in *.sh) want=1 ;; *) [[ "$(head -c2 "$f" 2>/dev/null || true)" == '#!' ]] && want=1 ;; esac
        [[ $want -eq 1 ]] || continue
        mode=$(stat -c %a "$f")
        if [[ "$mode" != 755 ]]; then chmod 0755 "$f"; changed=$((changed + 1)); fi
    done
    if [[ $changed -gt 0 ]]; then _note_change "permissions normalised under $PERI_INSTALL ($changed item(s))"; ok "normalised $changed file mode(s) under $PERI_INSTALL"
    else skip "file modes under $PERI_INSTALL are already correct"; fi
    if mutating_ok && [[ -n "$(find "$root" \( ! -user root -o ! -group root \) -print -quit)" ]]; then
        chown -R root:root "$root" && _note_change "chown -R root:root $PERI_INSTALL"
    fi
    return 0
}

# compile_server : byte-compile so the first start is fast and a syntax error is reported now, not at boot.
compile_server() {
    if is_dry; then skip "byte-compiling the server skipped (dry run)"; return 0; fi
    local dir out; dir=$(rp "$PERI_INSTALL/server")
    [[ -d "$dir" ]] || return 0
    if ! have python3; then warn "python3 not found: cannot byte-compile the server (the packages step installs it)"; return 0; fi
    if out=$(env -u PYTHONDONTWRITEBYTECODE python3 -m compileall -q "$dir" 2>&1); then
        debug "server byte-compiled"
    else
        warn "byte-compiling the server reported errors (the service will probably not start):"
        printf '%s\n' "$out" | sed -n '1,20s/^/        /p' >&2
    fi
    return 0
}

# --------------------------------------------------------------------------------------------- env file

# Array helpers over the lines of an env file. Values are never put into a command line or an expression: only into
# bash variables and printf '%s'.
_envl_matches_active()   { [[ "$1" =~ ^[[:space:]]*"$2"= ]]; }
_envl_matches_template() { [[ "$1" =~ ^[[:space:]]*#[[:space:]]*"$2"= ]]; }
_envl_mentions()         { [[ "$1" =~ ^[[:space:]]*#?[[:space:]]*"$2"= ]]; }

# _envl_set ARRAY KEY VALUE : replace the first active line (dropping later duplicates), else turn the first commented
# template line into an active one, else append.
_envl_set() {
    local -n _arr="$1"; local key="$2" value="$3"
    local i n=${#_arr[@]} act=-1 tmpl=-1 line
    local -a out=()
    for ((i = 0; i < n; i++)); do
        line="${_arr[$i]}"
        if _envl_matches_active "$line" "$key"; then [[ $act -lt 0 ]] && act=$i
        elif [[ $tmpl -lt 0 ]] && _envl_matches_template "$line" "$key"; then tmpl=$i; fi
    done
    for ((i = 0; i < n; i++)); do
        line="${_arr[$i]}"
        if [[ $act -ge 0 ]]; then
            if _envl_matches_active "$line" "$key"; then
                [[ $i -eq $act ]] && out+=("$key=$value")
                continue
            fi
        elif [[ $i -eq $tmpl ]]; then
            out+=("$key=$value"); continue
        fi
        out+=("$line")
    done
    if [[ $act -lt 0 && $tmpl -lt 0 ]]; then out+=("$key=$value"); fi
    _arr=("${out[@]}")
}

_envl_has_var() {  # ARRAY KEY : mentioned anywhere (active or commented)
    local -n _a="$1"; local line
    for line in "${_a[@]}"; do _envl_mentions "$line" "$2" && return 0; done
    return 1
}

# The documented optional variables (SPEC.md). Descriptions sit on their own line ABOVE the commented default because a
# trailing "# ..." on an active line would become part of the value for systemd's EnvironmentFile.
OPTIONAL_VARS=(
    'PERI_KIOSK|cage|Kiosk flavour: cage | x11 | labwc (written by the installer kiosk step)'
    'PERI_URL|http://127.0.0.1:8420/|Page the kiosk browser shows'
    'PERI_CHROMIUM_DEBUG_PORT|9222|Chromium remote-debugging port on 127.0.0.1 (empty value disables it)'
    'PERI_KIOSK_OUTPUT||Force the kiosk onto one output, e.g. DSI-1 (empty: automatic)'
    'PERI_UI_WATCHDOG|1|1 = restart the kiosk when no UI is connected to a healthy server (peri-ui-watchdog.timer), 0 = off'
    'PERI_MIXER_CAPTURE|39|WM8960 capture PGA gain, 0-63 (39 = +12 dB)'
    'PERI_MIXER_BOOST|3|Microphone boost, 0-3 (3 = +29 dB)'
    'PERI_MIXER_ADC|195|ADC digital volume, 0-255 (195 = 0 dB)'
    'PERI_MIXER_SPEAKER|121|Speaker volume, 0-127 (121 = 0 dB)'
    'PERI_MIXER_SPK_GAIN|4|Class-D speaker gain, 0-5'
)
OPTIONAL_HEADER='# ---- Optional settings (documented defaults). Uncomment/edit with: sudo peri-config set NAME VALUE ----'

_envl_append_optional() {
    local -n _lines="$1"; local spec key def desc added=0 hdr=0 line
    for line in "${_lines[@]}"; do [[ "$line" == "$OPTIONAL_HEADER" ]] && hdr=1; done
    for spec in "${OPTIONAL_VARS[@]}"; do
        key=${spec%%|*}; spec=${spec#*|}; def=${spec%%|*}; desc=${spec#*|}
        _envl_has_var _lines "$key" && continue
        if [[ $added -eq 0 ]]; then
            _lines+=("")
            [[ $hdr -eq 0 ]] && _lines+=("$OPTIONAL_HEADER")
        fi
        _lines+=("# $desc" "#$key=$def")
        added=$((added + 1))
    done
    return 0
}

# valid_secret_value VALUE : must be one line without whitespace, quotes or backslashes (systemd parses those specially).
valid_secret_value() {
    local v="$1"
    [[ -n "$v" ]] || return 1
    (export LC_ALL=C; [[ "$v" =~ ^[[:graph:]]+$ && "$v" != *[\"\'\\]* ]])
}

setup_env() {
    local real base_desc base_file lines=() newenv had_file=0
    real=$(rp "$ENV_FILE")
    if [[ -f "$real" ]]; then
        had_file=1; base_file="$real"; base_desc="existing $ENV_FILE (never overwritten)"
    elif [[ -f "$PERI_SRC/config/peri.env" ]]; then
        base_file="$PERI_SRC/config/peri.env"; base_desc="$PERI_SRC/config/peri.env"
    elif [[ -f "$PERI_SRC/config/peri.env.example" ]]; then
        base_file="$PERI_SRC/config/peri.env.example"; base_desc="$PERI_SRC/config/peri.env.example"
    else
        die "no environment template found: neither $PERI_SRC/config/peri.env nor config/peri.env.example exists"
    fi
    if [[ ! -r "$base_file" ]]; then
        if is_dry; then skip "cannot read $base_file as $(id -un): run the dry run with sudo to preview the env file handling"; return 0; fi
        die "cannot read $base_file"
    fi
    info "environment file: base is $base_desc"
    mapfile -t lines < "$base_file"

    if [[ -n "${PERI_OPT_OPENAI_KEY:-}" ]]; then
        valid_secret_value "$PERI_OPT_OPENAI_KEY" || die "the OpenAI key given with --openai-key contains whitespace, quotes, a backslash or control characters and cannot be stored in peri.env (the key is not shown here)"
        _envl_set lines OPENAI_API_KEY "$PERI_OPT_OPENAI_KEY"
        info "OPENAI_API_KEY taken from --openai-key (value not shown)"
    fi
    local head="${PERI_OPT_HEAD:-auto}"
    case "$head" in
        auto) ;;
        serial|gpio|sim|none) _envl_set lines PERI_HEAD_DRIVER "$head"; info "PERI_HEAD_DRIVER=$head (from --head)" ;;
        *) die "invalid head driver '$head' (expected auto|serial|gpio|sim|none)" ;;
    esac
    _envl_append_optional lines

    newenv=$(umask 077; mktemp); TMP_FILES+=("$newenv")
    [[ ${#lines[@]} -gt 0 ]] && printf '%s\n' "${lines[@]}" > "$newenv"

    if is_dry; then
        if [[ $had_file -eq 1 ]] && cmp -s "$newenv" "$real"; then skip "unchanged: $ENV_FILE"
        elif [[ $had_file -eq 1 ]]; then _note_would "$ENV_FILE"; info "would update $ENV_FILE (contents are not shown: they hold secrets)"
        else _note_would "$ENV_FILE"; info "would create $ENV_FILE (root:$PERI_USER 0640, contents are not shown: they hold secrets)"; fi
    else
        # umask 077 so the temporary copy is never readable by others while it is being written; final mode is 0640.
        ( umask 077; write_file "$ENV_FILE" 0640 "root:$PERI_USER" < "$newenv" )
    fi

    if ! grep -Eq '^[[:space:]]*OPENAI_API_KEY=[^[:space:]]' "$newenv"; then
        warn "NO OpenAI API key is configured in $ENV_FILE: the assistant cannot talk until one is set."
        warn "  set it with:  sudo peri-config set OPENAI_API_KEY sk-...    (or: echo 'sk-...' | sudo peri-config set OPENAI_API_KEY -)"
    else
        ok "an OpenAI API key is configured in $ENV_FILE (value not shown)"
    fi
}

install_cli() {
    if [[ -f "$PERI_SRC/scripts/peri-config" ]]; then
        install_file "$PERI_SRC/scripts/peri-config" /usr/local/bin/peri-config 0755 root:root
    else
        warn "scripts/peri-config is missing from the source tree: /usr/local/bin/peri-config not installed"
    fi
}

main() {
    case "${1:-}" in -h|--help) usage; return 0 ;; esac
    require_root
    detect_os; detect_hw
    check_source
    info "installing Peri $(cat "$PERI_SRC/VERSION" 2>/dev/null || echo '?') from $PERI_SRC (target: ${OS_PRETTY:-unknown OS})"
    ensure_user
    ensure_linger
    ensure_dirs
    sync_app
    compile_server
    fix_modes                     # after compiling: the new .pyc files/directories get normalised in the same run
    fix_state_ownership
    setup_env
    install_cli
    ok "app step finished: $PERI_INSTALL, $ENV_FILE, /usr/local/bin/peri-config"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi     # sourced (by tests) it only defines functions
