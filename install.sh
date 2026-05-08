#!/bin/zsh
# shellcheck shell=bash
# shellcheck disable=SC1090,SC1091,SC2059,SC2086,SC2088
# Interactive installer for rclone-bisync-launchd-macos.
# Renders templates with context-safe escaping (shell vs XML), runs initial resync,
# loads LaunchAgents.
#
# Usage:
#   ./install.sh                # interactive (auto-detects language from $LANG)
#   ./install.sh --dry-run      # preview rendered files, no system changes
#   ./install.sh --lang ko      # force Korean output
#   ./install.sh --lang en      # force English output
#   ./install.sh --help

set -euo pipefail

# ---------- color codes ----------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

# ---------- helpers ----------
# All message helpers use printf '%s\n' (raw) so backslashes in interpolated
# user input (paths, labels) are not interpreted as escape sequences.
info()    { printf '%s\n' "${CYAN}=>${RESET} $*"; }
ok()      { printf '%s\n' "${GREEN}OK${RESET} $*"; }
warn()    { printf '%s\n' "${YELLOW}!!${RESET} $*"; }
err()     { printf '%s\n' "${RED}ERROR${RESET} $*" >&2; }
section() { printf '\n%s\n' "${BOLD}--- $1 ---${RESET}"; }
ask()     { local prompt="$1" default="${2:-}" ans; printf -- "${BOLD}? %s${RESET}%s: " "$prompt" "${default:+ [default: $default]}" >&2; read -r ans; printf '%s\n' "${ans:-$default}"; }
confirm() { local prompt="$1" default="${2:-N}" ans; while true; do printf -- "${BOLD}? %s [y/N]${RESET} " "$prompt"; read -r ans; ans="${ans:-$default}"; case "$ans" in [yY]*) return 0 ;; [nN]*|"") return 1 ;; esac; done; }
fmt()     { printf -- "$1" "${@:2}"; }

# Context-aware escapers.
# All output uses printf '%s\n' (raw) — never `print --`, which interprets \b/\t/\c.
shell_quote() {
    # POSIX shell-safe single-quoted form. Embed apostrophes via the canonical '\'' pattern.
    # Use sed because zsh-double-quoted backslash escaping doesn't compose cleanly here.
    local escaped
    escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'\n" "$escaped"
}
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s\n' "$s"
}
sed_replacement_safe() {
    # Escape characters that are special in sed s|...|REPLACEMENT|g context.
    # Uses sed itself because zsh ${var//&/\\&} swallows backslash-ampersand inside
    # function bodies (interpreted as escape rather than literal-then-match).
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/&/\\\&/g'
}

spinner() {
    local pid="$1" msg="$2"
    if [[ ! -t 1 ]]; then
        wait "$pid"; return $?
    fi
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local n=${#frames[@]} i=0
    # EPOCHSECONDS may be unset (zsh/datetime not loaded, or stripped from
    # environment). With set -u, bare $EPOCHSECONDS aborts the script — use
    # parameter-default expansion to fall back to date(1).
    local start=${EPOCHSECONDS:-$(date +%s)}
    while kill -0 "$pid" 2>/dev/null; do
        local now=${EPOCHSECONDS:-$(date +%s)}
        local e=$((now - start))
        local mm=$((e/60))
        local ss=$((e%60))
        printf "\r${CYAN}%s${RESET} %s ${BOLD}%dm%02ds${RESET}   " "${frames[$((i % n + 1))]}" "$msg" "$mm" "$ss"
        i=$((i+1))
        sleep 0.1
    done
    printf "\r%-100s\r" ""
    wait "$pid"; return $?
}

# ---------- language detection + arg parsing ----------
LANG_CODE="en"
case "${LANG:-}" in
    ko*|*ko_*) LANG_CODE="ko" ;;
esac

DRY_RUN=0
require_arg() { [[ $# -ge 2 ]] || { printf "%s\n" "ERROR option $1 requires an argument" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --lang)    require_arg "$@"; LANG_CODE="$2"; shift 2 ;;
        --lang=*)  LANG_CODE="${1#--lang=}"; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--dry-run] [--lang en|ko]

Interactive installer.
  --dry-run        Preview rendered files in /tmp/rblm-dryrun/, do not modify ~ or load LaunchAgents.
  --lang en|ko     Force output language. Without this flag, language is detected from \$LANG.
  --help           Show this help.

Run ./uninstall.sh to remove.
EOF
            exit 0
            ;;
        *) printf "%s\n" "ERROR unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Source i18n file (fallback to en if requested locale doesn't exist)
if [[ -f "$REPO_ROOT/i18n/${LANG_CODE}.sh" ]]; then
    source "$REPO_ROOT/i18n/${LANG_CODE}.sh"
else
    source "$REPO_ROOT/i18n/en.sh"
    LANG_CODE="en"
fi

# ---------- preflight ----------
info "${M[checking_macos]}"
if [[ "$(uname)" != "Darwin" ]]; then
    err "${M[err_macos_only]}"
    exit 1
fi
ok "${M[ok_macos_detected]}"

info "${M[checking_deps]}"
need_install=()
for cmd in rclone fswatch; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd: $(command -v "$cmd")"
    else
        warn "$(fmt "${M[warn_cmd_not_found]}" "$cmd")"
        need_install+=("$cmd")
    fi
done

if [[ ${#need_install[@]} -gt 0 ]]; then
    if ! command -v brew >/dev/null 2>&1; then
        err "$(fmt "${M[err_brew_missing]}" "${need_install[*]}")"
        exit 1
    fi
    if confirm "$(fmt "${M[ask_install_deps]}" "${need_install[*]}")"; then
        if [[ $DRY_RUN -eq 1 ]]; then
            info "$(fmt "${M[info_dryrun_brew]}" "${need_install[*]}")"
        else
            brew install "${need_install[@]}"
        fi
    else
        err "$(fmt "${M[err_cannot_proceed]}" "${need_install[*]}")"
        exit 1
    fi
fi

if [[ ! -x /usr/bin/shlock ]]; then
    err "${M[err_shlock_missing]}"
    exit 1
fi
ok "${M[ok_shlock]}"

# rclone version check: need >= 1.71 for --recover, --max-lock, and --conflict-resolve.
RCLONE_VERSION="$(rclone version 2>/dev/null | awk 'NR==1 { gsub(/^rclone v/, ""); print $1 }')"
if [[ -z "$RCLONE_VERSION" ]]; then
    err "${M[err_rclone_version_unknown]}"
    exit 1
fi
RCLONE_MAJOR="${RCLONE_VERSION%%.*}"
RCLONE_REST="${RCLONE_VERSION#*.}"
RCLONE_MINOR="${RCLONE_REST%%.*}"
# Strip any non-digit suffix (e.g. "71-beta1") so arithmetic doesn't error.
RCLONE_MAJOR="${RCLONE_MAJOR%%[^0-9]*}"
RCLONE_MINOR="${RCLONE_MINOR%%[^0-9]*}"
if [[ -z "$RCLONE_MAJOR" || -z "$RCLONE_MINOR" ]]; then
    err "${M[err_rclone_version_unknown]}"
    exit 1
fi
if [[ "$RCLONE_MAJOR" -lt 1 || ( "$RCLONE_MAJOR" -eq 1 && "$RCLONE_MINOR" -lt 71 ) ]]; then
    err "$(fmt "${M[err_rclone_too_old]}" "$RCLONE_VERSION")"
    exit 1
fi
ok "$(fmt "${M[ok_rclone_version]}" "$RCLONE_VERSION")"

# ---------- rclone config sanity ----------
info "${M[checking_rclone_config]}"
if ! rclone listremotes >/dev/null 2>&1 || [[ -z "$(rclone listremotes 2>/dev/null)" ]]; then
    warn "${M[warn_no_remotes]}"
    warn "${M[warn_no_remotes_2]}"
    if ! confirm "${M[ask_continue_no_remote]}"; then
        exit 1
    fi
else
    info "${M[info_remotes_listed]}"
    rclone listremotes | sed 's/^/    /'
fi

# ---------- prompts ----------
section "${M[section_config]}"

LOCAL_PATH=""
while true; do
    LOCAL_PATH=$(ask "${M[ask_local_path]}" "${LOCAL_PATH}")
    if [[ -z "$LOCAL_PATH" ]]; then warn "${M[warn_required]}"; continue; fi
    if [[ "$LOCAL_PATH" != /* ]]; then
        warn "${M[warn_path_not_absolute]}"
        continue
    fi
    if [[ -d "$LOCAL_PATH" ]]; then break; fi

    warn "$(fmt "${M[warn_path_not_exist]}" "$LOCAL_PATH")"
    printf "%s\n" "${M[path_action_prompt]}"
    printf "%s\n" "${M[path_action_retry]}"
    printf "%s\n" "${M[path_action_create]}"
    printf "%s\n" "${M[path_action_continue]}"
    action=""
    while [[ "$action" != "1" && "$action" != "2" && "$action" != "3" ]]; do
        action=$(ask "${M[ask_path_action]}" "1")
    done
    case "$action" in
        1) continue ;;
        2)
            if mkdir -p "$LOCAL_PATH" 2>/dev/null; then
                ok "$(fmt "${M[ok_path_created]}" "$LOCAL_PATH")"
                break
            else
                err "$(fmt "${M[err_path_create_failed]}" "$LOCAL_PATH")"
                continue
            fi
            ;;
        3) break ;;
    esac
done

REMOTE=""
while true; do
    REMOTE=$(ask "${M[ask_remote]}" "${REMOTE}")
    if [[ -z "$REMOTE" ]]; then warn "${M[warn_required]}"; continue; fi
    info "$(fmt "${M[info_validate_remote]}" "$REMOTE")"
    if rclone lsd "$REMOTE" >/dev/null 2>&1; then
        ok "${M[ok_remote_reachable]}"
        break
    else
        warn "${M[warn_remote_unlistable]}"
        printf "%s\n" "${M[guide_remote_causes]}"
        printf "%s\n" "${M[guide_remote_cause1]}"
        printf "%s\n" "${M[guide_remote_cause2]}"
        printf "%s\n" "${M[guide_remote_cause3]}"
        printf "%s\n" "${M[guide_remote_advice]}"
        confirm "${M[ask_use_remote_anyway]}" && break
    fi
done

# Validate label prefix: only [A-Za-z0-9._-], no whitespace/slash/etc.
LABEL_PREFIX=""
while true; do
    LABEL_PREFIX=$(ask "${M[ask_label_prefix]}" "${LABEL_PREFIX:-local.rclone-bisync}")
    if [[ -z "$LABEL_PREFIX" ]]; then warn "${M[warn_required]}"; continue; fi
    if [[ ! "$LABEL_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "${M[warn_label_invalid]}"
        continue
    fi
    break
done

HOME_DIR="$HOME"
SCRIPTS_DIR=""
while true; do
    SCRIPTS_DIR=$(ask "${M[ask_scripts_dir]}" "${SCRIPTS_DIR:-$HOME/scripts}")
    # Expand a leading ~ / ~/ since launchd requires absolute paths.
    case "$SCRIPTS_DIR" in
        '~')   SCRIPTS_DIR="$HOME" ;;
        '~/'*) SCRIPTS_DIR="$HOME/${SCRIPTS_DIR#'~/'}" ;;
    esac
    if [[ "$SCRIPTS_DIR" != /* ]]; then
        warn "${M[warn_scripts_dir_not_absolute]}"
        continue
    fi
    break
done
RCLONE_BIN="$(command -v rclone)"
FSWATCH_BIN="$(command -v fswatch)"

# Numeric validation.
DEBOUNCE_SEC=""
while true; do
    DEBOUNCE_SEC=$(ask "${M[ask_debounce]}" "${DEBOUNCE_SEC:-30}")
    if [[ "$DEBOUNCE_SEC" =~ ^[0-9]+$ && "$DEBOUNCE_SEC" -ge 1 ]]; then break; fi
    warn "${M[warn_positive_int_required]}"
done

INTERVAL_SEC=""
while true; do
    INTERVAL_SEC=$(ask "${M[ask_interval]}" "${INTERVAL_SEC:-600}")
    if [[ "$INTERVAL_SEC" =~ ^[0-9]+$ && "$INTERVAL_SEC" -ge 60 ]]; then break; fi
    warn "${M[warn_interval_too_small]}"
done

MAX_DELETE_PERCENT=""
while true; do
    MAX_DELETE_PERCENT=$(ask "${M[ask_max_delete]}" "${MAX_DELETE_PERCENT:-50}")
    if [[ "$MAX_DELETE_PERCENT" =~ ^[0-9]+$ && "$MAX_DELETE_PERCENT" -le 100 ]]; then break; fi
    warn "${M[warn_percent_required]}"
done

printf "\n"
info "${M[info_backup_dir_intro]}"
# Validate Path1 backup as a remote spec ('<remote>:<path>') with a colon. This
# catches accidental local paths or absolute paths up front; rclone would still
# error during resync, but installer-level feedback is friendlier. The remote
# name must match the configured sync remote (sanity check).
SYNC_REMOTE_NAME="${REMOTE%%:*}"
BACKUP_DIR1=""
while true; do
    BACKUP_DIR1=$(ask "${M[ask_backup_dir1]}" "${BACKUP_DIR1:-}")
    [[ -z "$BACKUP_DIR1" ]] && break
    if [[ "$BACKUP_DIR1" != *:* ]]; then
        warn "${M[warn_backup_dir1_not_remote]}"
        continue
    fi
    BACKUP_REMOTE_NAME="${BACKUP_DIR1%%:*}"
    if [[ "$BACKUP_REMOTE_NAME" != "$SYNC_REMOTE_NAME" ]]; then
        warn "$(fmt "${M[warn_backup_dir1_remote_mismatch]}" "$BACKUP_REMOTE_NAME" "$SYNC_REMOTE_NAME")"
        continue
    fi
    # Cheap overlap guard: backup path must differ from sync path. rclone
    # would error during resync, but installer-level feedback is friendlier.
    # Full subpath/parent overlap check would need rclone-specific path
    # normalization; we leave that to rclone itself.
    if [[ "$BACKUP_DIR1" == "$REMOTE" ]]; then
        warn "$(fmt "${M[warn_backup_dir1_overlaps_sync]}" "$BACKUP_DIR1")"
        continue
    fi
    break
done
# Loop until BACKUP_DIR2 is empty (disabled) or a validated absolute path —
# matches the retry pattern used by the other path prompts.
BACKUP_DIR2=""
while true; do
    BACKUP_DIR2=$(ask "${M[ask_backup_dir2]}" "${BACKUP_DIR2:-}")
    [[ -z "$BACKUP_DIR2" ]] && break
    case "$BACKUP_DIR2" in
        '~')   BACKUP_DIR2="$HOME" ;;
        '~/'*) BACKUP_DIR2="$HOME/${BACKUP_DIR2#'~/'}" ;;
    esac
    if [[ "$BACKUP_DIR2" != /* ]]; then
        warn "${M[err_backup_dir2_not_absolute]}"
        continue
    fi
    break
done
BACKUP_FLAGS=()
[[ -n "$BACKUP_DIR1" ]] && BACKUP_FLAGS+=(--backup-dir1 "$BACKUP_DIR1")
[[ -n "$BACKUP_DIR2" ]] && BACKUP_FLAGS+=(--backup-dir2 "$BACKUP_DIR2")

# ---------- compute escaped values for each rendering context ----------
# Shell-quoted (for sync.sh, watch.sh)
LOCAL_PATH_SH=$(shell_quote "$LOCAL_PATH")
REMOTE_SH=$(shell_quote "$REMOTE")
LABEL_PREFIX_SH=$(shell_quote "$LABEL_PREFIX")
RCLONE_BIN_SH=$(shell_quote "$RCLONE_BIN")
FSWATCH_BIN_SH=$(shell_quote "$FSWATCH_BIN")
SCRIPTS_DIR_SH=$(shell_quote "$SCRIPTS_DIR")
HOME_SH=$(shell_quote "$HOME_DIR")
MAX_DELETE_PERCENT_SH=$(shell_quote "$MAX_DELETE_PERCENT")
BACKUP_FLAGS_SH=""
for flag in "${BACKUP_FLAGS[@]}"; do
    BACKUP_FLAGS_SH+=" $(shell_quote "$flag")"
done
BACKUP_FLAGS_SH="${BACKUP_FLAGS_SH# }"

# XML-escaped (for plist)
LOCAL_PATH_XML=$(xml_escape "$LOCAL_PATH")
LABEL_PREFIX_XML=$(xml_escape "$LABEL_PREFIX")
SCRIPTS_DIR_XML=$(xml_escape "$SCRIPTS_DIR")
HOME_XML=$(xml_escape "$HOME_DIR")

# ---------- render ----------
section "${M[section_render]}"

if [[ $DRY_RUN -eq 1 ]]; then
    OUT_SCRIPTS="/tmp/rblm-dryrun/scripts"
    OUT_AGENTS="/tmp/rblm-dryrun/LaunchAgents"
    mkdir -p "$OUT_SCRIPTS" "$OUT_AGENTS"
else
    OUT_SCRIPTS="$SCRIPTS_DIR"
    OUT_AGENTS="$HOME/Library/LaunchAgents"
    mkdir -p "$OUT_SCRIPTS" "$OUT_AGENTS" "$HOME/Library/Logs"
fi

SYNC_SH="$OUT_SCRIPTS/${LABEL_PREFIX}.sh"
WATCH_SH="$OUT_SCRIPTS/${LABEL_PREFIX}-watch.sh"
FILTER="$OUT_SCRIPTS/${LABEL_PREFIX}-filter.txt"
SYNC_PLIST="$OUT_AGENTS/${LABEL_PREFIX}.plist"
WATCH_PLIST="$OUT_AGENTS/${LABEL_PREFIX}-watch.plist"

# Path of the rendered sync.sh (used by watch.sh) — also shell-quoted
SYNC_SCRIPT_SH=$(shell_quote "$SYNC_SH")

# Atomic render: write to a unique temp file then mv into place.
# - mktemp prevents predictable-path symlink races on shared SCRIPTS_DIRs.
# - umask 077 narrows the tmp permissions before chmod restores +x.
# - Cleanup on any failure path so reruns don't see stale .tmp.*.
render_shell() {
    local in="$1" out="$2"
    local tmp
    tmp=$(umask 077 && mktemp "${out}.tmp.XXXXXX") || return 1
    if ! sed \
            -e "s|{{LOCAL_PATH_SH}}|$(sed_replacement_safe "$LOCAL_PATH_SH")|g" \
            -e "s|{{REMOTE_SH}}|$(sed_replacement_safe "$REMOTE_SH")|g" \
            -e "s|{{LABEL_PREFIX_SH}}|$(sed_replacement_safe "$LABEL_PREFIX_SH")|g" \
            -e "s|{{RCLONE_BIN_SH}}|$(sed_replacement_safe "$RCLONE_BIN_SH")|g" \
            -e "s|{{FSWATCH_BIN_SH}}|$(sed_replacement_safe "$FSWATCH_BIN_SH")|g" \
            -e "s|{{SCRIPTS_DIR_SH}}|$(sed_replacement_safe "$SCRIPTS_DIR_SH")|g" \
            -e "s|{{HOME_SH}}|$(sed_replacement_safe "$HOME_SH")|g" \
            -e "s|{{MAX_DELETE_PERCENT_SH}}|$(sed_replacement_safe "$MAX_DELETE_PERCENT_SH")|g" \
            -e "s|{{BACKUP_FLAGS_SH}}|$(sed_replacement_safe "$BACKUP_FLAGS_SH")|g" \
            -e "s|{{SYNC_SCRIPT_SH}}|$(sed_replacement_safe "$SYNC_SCRIPT_SH")|g" \
            -e "s|{{DEBOUNCE_SEC}}|$DEBOUNCE_SEC|g" \
            "$in" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    chmod 0755 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$out"; then
        rm -f "$tmp"; return 1
    fi
}

render_xml() {
    local in="$1" out="$2"
    local tmp
    tmp=$(umask 077 && mktemp "${out}.tmp.XXXXXX") || return 1
    if ! sed \
            -e "s|{{LABEL_PREFIX_XML}}|$(sed_replacement_safe "$LABEL_PREFIX_XML")|g" \
            -e "s|{{LOCAL_PATH_XML}}|$(sed_replacement_safe "$LOCAL_PATH_XML")|g" \
            -e "s|{{SCRIPTS_DIR_XML}}|$(sed_replacement_safe "$SCRIPTS_DIR_XML")|g" \
            -e "s|{{HOME_XML}}|$(sed_replacement_safe "$HOME_XML")|g" \
            -e "s|{{INTERVAL_SEC}}|$INTERVAL_SEC|g" \
            "$in" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if ! mv -f "$tmp" "$out"; then
        rm -f "$tmp"; return 1
    fi
}

LAUNCHD_DOMAIN="gui/$(id -u)"

# Boot out existing agents only at the last safe moment —
# right before bootstrap. atomic mv-f already prevents half-rendered reads,
# and deferring bootout means a failed render/resync leaves the previous
# install fully running instead of stopped.
#
# Lock-acquisition timing (race protection):
# Existing LaunchAgent (still loaded) shares /tmp/${LABEL_PREFIX}.lock with
# sync.sh. We MUST take this lock BEFORE overwriting the script files —
# otherwise a scheduled run between render and bootstrap would execute the
# new sync.sh against the new paths without an established baseline.
# Lock-cleanup uses two variables to avoid removing a lock we don't own:
# - INSTALLER_LOCK_PATH: where the lock would live (set before shlock attempt
#   so error messages can reference it).
# - INSTALLER_LOCK_HELD: 1 only after shlock succeeds, so cleanup is a no-op
#   if we're aborting between trap setup and shlock success.
INSTALLER_LOCK_PATH="/tmp/${LABEL_PREFIX}.lock"
INSTALLER_LOCK_HELD=0
installer_lock_cleanup() {
    # Idempotent + ownership-checked.
    # 1) Drop HELD BEFORE rm so a signal-induced reentrant call sees HELD=0.
    # 2) Verify the lock file's PID still matches us before deleting; another
    #    process may have grabbed the lock between our trap firings.
    if [[ "$INSTALLER_LOCK_HELD" == "1" ]]; then
        INSTALLER_LOCK_HELD=0
        if [[ -f "$INSTALLER_LOCK_PATH" ]] && \
           [[ "$(/bin/cat "$INSTALLER_LOCK_PATH" 2>/dev/null)" == "$$" ]]; then
            rm -f "$INSTALLER_LOCK_PATH"
        fi
    fi
}
trap installer_lock_cleanup EXIT
trap 'installer_lock_cleanup; exit 130' INT
trap 'installer_lock_cleanup; exit 143' TERM

if [[ $DRY_RUN -eq 0 ]]; then
    if ! /usr/bin/shlock -f "$INSTALLER_LOCK_PATH" -p $$; then
        err "$(fmt "${M[err_installer_lock_held]}" "$INSTALLER_LOCK_PATH")"
        exit 1
    fi
    INSTALLER_LOCK_HELD=1
fi

# Preserve a user-modified filter.txt; only copy the default if no filter
# exists, or the existing one is empty (truncated/corrupted). Refuse to
# overwrite through a symlink (cp would follow it and clobber an arbitrary
# file the symlink points to — a hardening step for shared SCRIPTS_DIRs).
if [[ -L "$FILTER" ]]; then
    err "$(fmt "${M[err_filter_is_symlink]}" "$FILTER")"
    exit 1
fi
if [[ ! -e "$FILTER" ]]; then
    cp "$REPO_ROOT/templates/scripts/filter.txt" "$FILTER"
elif [[ ! -s "$FILTER" ]]; then
    warn "$(fmt "${M[warn_filter_empty_restored]}" "$FILTER")"
    cp "$REPO_ROOT/templates/scripts/filter.txt" "$FILTER"
fi
render_or_die() {
    local kind="$1" in="$2" out="$3"
    if ! "render_${kind}" "$in" "$out"; then
        err "$(fmt "${M[err_render_failed]}" "$in" "$out")"
        exit 1
    fi
}
render_or_die shell "$REPO_ROOT/templates/scripts/sync.sh.tmpl"           "$SYNC_SH"
render_or_die shell "$REPO_ROOT/templates/scripts/watch.sh.tmpl"          "$WATCH_SH"
render_or_die xml   "$REPO_ROOT/templates/launchagents/sync.plist.tmpl"   "$SYNC_PLIST"
render_or_die xml   "$REPO_ROOT/templates/launchagents/watch.plist.tmpl"  "$WATCH_PLIST"

ok "${M[ok_rendered]}"
printf "%s\n" "    $SYNC_SH"
printf "%s\n" "    $WATCH_SH"
printf "%s\n" "    $FILTER"
printf "%s\n" "    $SYNC_PLIST"
printf "%s\n" "    $WATCH_PLIST"

# Validation — templates use #!/bin/zsh, so check with zsh -n.
if ! zsh -n "$SYNC_SH";  then err "${M[err_sync_syntax]}"; exit 1; fi
if ! zsh -n "$WATCH_SH"; then err "${M[err_watch_syntax]}"; exit 1; fi
if ! /usr/bin/plutil -lint "$SYNC_PLIST" >/dev/null;  then err "${M[err_sync_plist]}"; exit 1; fi
if ! /usr/bin/plutil -lint "$WATCH_PLIST" >/dev/null; then err "${M[err_watch_plist]}"; exit 1; fi

# Unrendered placeholder check. Use an explicit list (not a regex) so user
# input that legitimately contains '{{...}}' inside a path doesn't trigger a false alarm.
EXPECTED_PLACEHOLDERS=(
    LOCAL_PATH_SH REMOTE_SH LABEL_PREFIX_SH RCLONE_BIN_SH FSWATCH_BIN_SH
    SCRIPTS_DIR_SH HOME_SH MAX_DELETE_PERCENT_SH BACKUP_FLAGS_SH SYNC_SCRIPT_SH DEBOUNCE_SEC
    LOCAL_PATH_XML LABEL_PREFIX_XML SCRIPTS_DIR_XML HOME_XML INTERVAL_SEC
)
for p in "${EXPECTED_PLACEHOLDERS[@]}"; do
    if grep -q -F "{{$p}}" "$SYNC_SH" "$WATCH_SH" "$SYNC_PLIST" "$WATCH_PLIST" 2>/dev/null; then
        err "${M[err_unrendered_placeholder]}"
        exit 1
    fi
done
ok "${M[ok_static_pass]}"

if [[ $DRY_RUN -eq 1 ]]; then
    printf "\n"
    info "${M[info_dryrun_done1]}"
    info "${M[info_dryrun_done2]}"
    exit 0
fi

# ---------- initial resync ----------
section "${M[section_resync]}"
printf "%s\n" "${M[resync_intro1]}"
printf "%s\n" "${M[resync_intro2_pre]}${YELLOW}${M[resync_intro2_warn]}${RESET}"
printf "\n"
RESYNC_MODE=""

# Sentinel for --check-access (verifies external drive really mounted).
ACCESS_FILE="RCLONE_TEST"
LOCAL_SENTINEL="$LOCAL_PATH/$ACCESS_FILE"

ensure_sentinel() {
    # User may have chosen path-action option 3 (continue anyway) for a path
    # that doesn't exist. mkdir -p before touch so the "first sync creates it"
    # promise actually holds. mkdir -p succeeds when the path already exists.
    if ! mkdir -p "$LOCAL_PATH" 2>/dev/null; then
        err "$(fmt "${M[err_path_create_failed]}" "$LOCAL_PATH")"
        exit 1
    fi
    if ! touch "$LOCAL_SENTINEL" 2>/dev/null; then
        err "$(fmt "${M[err_sentinel_local_failed]}" "$LOCAL_SENTINEL")"
        exit 1
    fi
    info "$(fmt "${M[info_sentinel_local]}" "$LOCAL_SENTINEL")"
    # Remote sentinel is REQUIRED for --check-access. If push fails, abort
    # before resync (otherwise bisync aborts immediately on missing sentinel).
    if ! "$RCLONE_BIN" copyto "$LOCAL_SENTINEL" "$REMOTE/$ACCESS_FILE" 2>/dev/null; then
        err "$(fmt "${M[err_sentinel_remote_failed]}" "$REMOTE/$ACCESS_FILE")"
        exit 1
    fi
    info "$(fmt "${M[info_sentinel_remote]}" "$REMOTE/$ACCESS_FILE")"
}

while true; do
    printf "%s\n" "${BOLD}${M[resync_question]}${RESET}"
    printf "%s\n" "  ${BOLD}1${RESET}${M[resync_opt1_desc]}"
    printf "%s\n" "  ${BOLD}2${RESET}${M[resync_opt2_desc]}"
    printf "%s\n" "  ${BOLD}3${RESET}${M[resync_opt3_desc]}"
    printf "%s\n" "  ${BOLD}4${RESET}${M[resync_opt4_desc]}"
    printf "\n"
    RESYNC_MODE=""
    while [[ "$RESYNC_MODE" != "1" && "$RESYNC_MODE" != "2" && "$RESYNC_MODE" != "3" && "$RESYNC_MODE" != "4" ]]; do
        RESYNC_MODE=$(ask "${M[ask_resync_choice]}" "3")
    done

    [[ "$RESYNC_MODE" != "3" ]] && break

    ensure_sentinel
    # Preview always runs in Path2 (Local→Remote) direction — preview is meant
    # for first-time setup where local is typically the source of truth. After
    # reviewing the output, the user picks options 1, 2, or 4 to commit.
    RESYNC_FLAG="--resync --resync-mode path2"
    info "${M[info_preview_direction_note]}"
    info "$(fmt "${M[info_resync_preview_running]}" "$RESYNC_FLAG")"
    if "$RCLONE_BIN" bisync "$REMOTE" "$LOCAL_PATH" \
        --filter-from "$FILTER" \
        --check-access \
        --resilient --recover --max-lock 2m \
        --max-delete "$MAX_DELETE_PERCENT" \
        --conflict-resolve newer \
        ${=RESYNC_FLAG} \
        "${BACKUP_FLAGS[@]}" \
        --dry-run --verbose; then
        ok "${M[ok_resync_preview_done]}"
    else
        err "${M[err_resync_preview_failed]}"
    fi
    printf "\n"
done

if [[ "$RESYNC_MODE" == "4" ]]; then
    warn "${M[warn_resync_skipped]}"
    # Shell-quote every interpolated value so the printed commands are safe
    # to copy-paste even when paths contain spaces, $, backticks, or quotes.
    MANUAL_BACKUP_FLAGS=""
    for flag in "${BACKUP_FLAGS[@]}"; do
        MANUAL_BACKUP_FLAGS+=$' \\\n        '"$(shell_quote "$flag")"
    done
    Q_LOCAL=$(shell_quote "$LOCAL_PATH")
    Q_REMOTE=$(shell_quote "$REMOTE")
    Q_RCLONE=$(shell_quote "$RCLONE_BIN")
    Q_FILTER=$(shell_quote "$FILTER")
    Q_LOCAL_SENTINEL=$(shell_quote "$LOCAL_PATH/$ACCESS_FILE")
    Q_REMOTE_SENTINEL=$(shell_quote "$REMOTE/$ACCESS_FILE")
    Q_LOG=$(shell_quote "$HOME/Library/Logs/${LABEL_PREFIX}.log")
    Q_SYNC_PLIST=$(shell_quote "$SYNC_PLIST")
    Q_WATCH_PLIST=$(shell_quote "$WATCH_PLIST")
    cat <<EOF
    # 1) Ensure local path exists, then create sentinel on both sides:
    mkdir -p ${Q_LOCAL}
    touch ${Q_LOCAL_SENTINEL}
    ${Q_RCLONE} copyto ${Q_LOCAL_SENTINEL} ${Q_REMOTE_SENTINEL}
    # 2) Run resync:
    ${Q_RCLONE} bisync ${Q_REMOTE} ${Q_LOCAL} \\
        --filter-from ${Q_FILTER} \\
        --check-access \\
        --resilient --recover --max-lock 2m \\
        --max-delete ${MAX_DELETE_PERCENT} \\
        --conflict-resolve newer \\
        --resync${MANUAL_BACKUP_FLAGS} \\
        --log-file ${Q_LOG} --log-level INFO
    # 3) Then load LaunchAgents (re-run installer or run these directly):
    DOMAIN="gui/\$(id -u)"
    launchctl bootstrap "\$DOMAIN" ${Q_SYNC_PLIST}
    launchctl bootstrap "\$DOMAIN" ${Q_WATCH_PLIST}
EOF
    # Race fix: when user picks skip during a reinstall, the existing
    # LaunchAgent (still loaded) points at the script files we just overwrote.
    # If we leave it loaded, its next scheduled fire would execute the new
    # script before the manual resync establishes baseline. Bootout deactivates
    # the previous install; the user must re-run installer (or launchctl
    # bootstrap manually) after the manual resync — see info_resync_skipped_no_load.
    launchctl bootout "$LAUNCHD_DOMAIN/$LABEL_PREFIX"        2>/dev/null || true
    launchctl bootout "$LAUNCHD_DOMAIN/$LABEL_PREFIX-watch"  2>/dev/null || true
    info "${M[info_resync_skipped_no_load]}"
    exit 0
else
    ensure_sentinel

    RESYNC_FLAG="--resync"
    [[ "$RESYNC_MODE" == "2" ]] && RESYNC_FLAG="--resync --resync-mode path2"
    info "$(fmt "${M[info_resync_running]}" "$RESYNC_FLAG")"
    # Set rclone-aware traps BEFORE starting rclone. Helper guards against
    # `kill 0` (which signals the whole process group) when the trap fires
    # before $! has been captured.
    RCLONE_PID=
    forward_rclone_signal() {
        local sig="$1" code="$2"
        if [[ -n "${RCLONE_PID:-}" ]]; then
            kill "-$sig" "$RCLONE_PID" 2>/dev/null || true
            wait "$RCLONE_PID" 2>/dev/null || true
        fi
        exit "$code"
    }
    trap 'forward_rclone_signal INT 130'  INT
    trap 'forward_rclone_signal TERM 143' TERM
    "$RCLONE_BIN" bisync "$REMOTE" "$LOCAL_PATH" \
        --filter-from "$FILTER" \
        --check-access \
        --resilient --recover --max-lock 2m \
        --max-delete "$MAX_DELETE_PERCENT" \
        --conflict-resolve newer \
        ${=RESYNC_FLAG} \
        "${BACKUP_FLAGS[@]}" \
        --log-file "$HOME/Library/Logs/${LABEL_PREFIX}.log" \
        --log-level INFO >/dev/null 2>&1 &
    RCLONE_PID=$!
    if ! spinner "$RCLONE_PID" "${M[spinner_resync]}"; then
        # Restore the lock-cleanup INT/TERM handlers so a signal during the
        # post-resync (bootout/bootstrap/verify) phase still releases the lock.
        trap 'installer_lock_cleanup; exit 130' INT
        trap 'installer_lock_cleanup; exit 143' TERM
        err "$(fmt "${M[err_resync_failed]}" "$LABEL_PREFIX")"
        exit 1
    fi
    trap 'installer_lock_cleanup; exit 130' INT
    trap 'installer_lock_cleanup; exit 143' TERM
    ok "${M[ok_resync_done]}"
fi

# ---------- LaunchAgent load ----------
# Prefer modern bootstrap/bootout over legacy load/unload (deprecated and
# returns exit 0 even on certain failures on Sequoia/Tahoe).
section "${M[section_load]}"

# Bootout only here — a failed render/resync above leaves the previous
# install untouched. atomic mv-f earlier already prevents torn reads.
launchctl bootout "$LAUNCHD_DOMAIN/$LABEL_PREFIX"        2>/dev/null || true
launchctl bootout "$LAUNCHD_DOMAIN/$LABEL_PREFIX-watch"  2>/dev/null || true

if ! launchctl bootstrap "$LAUNCHD_DOMAIN" "$SYNC_PLIST"; then
    err "$(fmt "${M[err_load_failed]}" "$LABEL_PREFIX")"
    exit 1
fi
ok "$(fmt "${M[ok_loaded]}" "$LABEL_PREFIX")"
if ! launchctl bootstrap "$LAUNCHD_DOMAIN" "$WATCH_PLIST"; then
    err "$(fmt "${M[err_load_failed]}" "$LABEL_PREFIX-watch")"
    # Roll back the sync agent that loaded a moment ago — leaving a half-
    # installed pair (schedule running, watch missing) is worse than nothing.
    warn "$(fmt "${M[warn_partial_rollback]}" "$LABEL_PREFIX")"
    launchctl bootout "$LAUNCHD_DOMAIN/$LABEL_PREFIX" 2>/dev/null || true
    exit 1
fi
ok "$(fmt "${M[ok_loaded]}" "$LABEL_PREFIX-watch")"

# ---------- verify ----------
sleep 2
section "${M[section_verify]}"
# launchctl print is the domain-aware equivalent of the legacy `launchctl list`.
if launchctl print "$LAUNCHD_DOMAIN/$LABEL_PREFIX"        >/dev/null 2>&1; then ok "$(fmt "${M[ok_listed]}" "$LABEL_PREFIX")";        else warn "$(fmt "${M[warn_not_listed]}" "$LABEL_PREFIX")"; fi
if launchctl print "$LAUNCHD_DOMAIN/$LABEL_PREFIX-watch"  >/dev/null 2>&1; then ok "$(fmt "${M[ok_listed]}" "$LABEL_PREFIX-watch")";  else warn "$(fmt "${M[warn_not_listed]}" "$LABEL_PREFIX-watch")"; fi
# Use FSWATCH_BIN's basename (no path metachars) + LOCAL_PATH literal in pgrep -F
if pgrep -fl fswatch 2>/dev/null | grep -F -- "$LOCAL_PATH" >/dev/null; then
    ok "${M[ok_fswatch_running]}"
else
    warn "${M[warn_fswatch_not]}"
fi

printf "\n"
ok "${M[ok_install_complete]}"
printf "%s\n" "${M[next_steps]}"
printf "%s\n" "$(fmt "${M[next_step_edit]}" "$LOCAL_PATH" "$LABEL_PREFIX")"
printf "%s\n" "$(fmt "${M[next_step_manual]}" "$LABEL_PREFIX")"
printf "%s\n" "$(fmt "${M[next_step_doctor]}" \
    "$(shell_quote "$LABEL_PREFIX")" \
    "$(shell_quote "$SCRIPTS_DIR")" \
    "$(shell_quote "$LOCAL_PATH")" \
    "$(shell_quote "$REMOTE")")"
printf "%s\n" "${M[next_step_uninstall]}"
