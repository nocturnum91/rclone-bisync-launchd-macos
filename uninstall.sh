#!/bin/zsh
# shellcheck shell=bash
# shellcheck disable=SC1090,SC1091,SC2059,SC2088
# Uninstaller for rclone-bisync-launchd-macos.
# Unloads LaunchAgents, removes plists + scripts. Logs are removed on confirm;
# the global rclone bisync cache is preserved (warn only) since it may contain
# baselines for unrelated bisync jobs.
#
# Usage:
#   ./uninstall.sh                                # interactive (auto-detects language)
#   ./uninstall.sh --label com.your.label-prefix  # specify label non-interactively
#   ./uninstall.sh --lang ko                      # force Korean output
#   ./uninstall.sh --help

set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info()    { printf "%s\n" "${CYAN}=>${RESET} $*"; }
ok()      { printf "%s\n" "${GREEN}OK${RESET} $*"; }
warn()    { printf "%s\n" "${YELLOW}!!${RESET} $*"; }
err()     { printf "%s\n" "${RED}ERROR${RESET} $*" >&2; }
ask()     { local prompt="$1" default="${2:-}" ans; printf -- "${BOLD}? %s${RESET}%s: " "$prompt" "${default:+ [default: $default]}" >&2; read -r ans; printf "%s\n" "${ans:-$default}"; }
confirm() { local prompt="$1" default="${2:-N}" ans; while true; do printf -- "${BOLD}? %s [y/N]${RESET} " "$prompt"; read -r ans; ans="${ans:-$default}"; case "$ans" in [yY]*) return 0 ;; [nN]*|"") return 1 ;; esac; done; }
fmt()     { printf -- "$1" "${@:2}"; }

# ---------- language + arg parsing ----------
LANG_CODE="en"
case "${LANG:-}" in
    ko*|*ko_*) LANG_CODE="ko" ;;
esac

LABEL_PREFIX=""
require_arg() { [[ $# -ge 2 ]] || { printf "%s\n" "ERROR option $1 requires an argument" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)   require_arg "$@"; LABEL_PREFIX="$2"; shift 2 ;;
        --label=*) LABEL_PREFIX="${1#--label=}"; shift ;;
        --lang)    require_arg "$@"; LANG_CODE="$2"; shift 2 ;;
        --lang=*)  LANG_CODE="${1#--lang=}"; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--label LABEL_PREFIX] [--lang en|ko]

Removes a rblm install with the given label prefix.
Prompts before destructive actions.
  --label LABEL    Skip prompt for label (default: local.rclone-bisync)
  --lang en|ko     Force output language. Without this flag, language is detected from \$LANG.
EOF
            exit 0
            ;;
        *)
            # Backwards compat: bare positional arg = label
            if [[ -z "$LABEL_PREFIX" ]]; then
                LABEL_PREFIX="$1"
                shift
            else
                err "unknown arg: $1"; exit 2
            fi
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$REPO_ROOT/i18n/${LANG_CODE}.sh" ]]; then
    source "$REPO_ROOT/i18n/${LANG_CODE}.sh"
else
    source "$REPO_ROOT/i18n/en.sh"
    LANG_CODE="en"
fi

[[ -z "$LABEL_PREFIX" ]] && LABEL_PREFIX=$(ask "${M[ask_uninstall_label]}" "local.rclone-bisync")
# Validate label format same as install.sh — prevents '../' or other path
# traversal that would cause rm -f to delete files outside intended scope.
if [[ ! "$LABEL_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
    err "${M[warn_label_invalid]}"
    exit 1
fi
# Expand ~ / ~/ same as install.sh, then enforce absolute path. Without
# this, a relative input would resolve against $PWD and could rm files that
# are NOT the intended install (especially dangerous when running from /).
while true; do
    SCRIPTS_DIR=$(ask "${M[ask_uninstall_scripts_dir]}" "${SCRIPTS_DIR:-$HOME/scripts}")
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

SYNC_SH="$SCRIPTS_DIR/${LABEL_PREFIX}.sh"
WATCH_SH="$SCRIPTS_DIR/${LABEL_PREFIX}-watch.sh"
FILTER="$SCRIPTS_DIR/${LABEL_PREFIX}-filter.txt"
SYNC_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}.plist"
WATCH_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}-watch.plist"
LOCK="/tmp/${LABEL_PREFIX}.lock"
LOG="$HOME/Library/Logs/${LABEL_PREFIX}.log"
LOG_ERR="$HOME/Library/Logs/${LABEL_PREFIX}-error.log"
WATCH_LOG="$HOME/Library/Logs/${LABEL_PREFIX}-watch.log"
WATCH_LOG_ERR="$HOME/Library/Logs/${LABEL_PREFIX}-watch-error.log"

# Detect a live-owner lock up-front so the preview list is honest: it shows
# only the things that will actually be removed, with a separate notice for
# the active lock (which will be preserved — see warn_lock_alive at exec).
LOCK_ALIVE=0
if [[ -e "$LOCK" ]]; then
    LOCK_PID_PREVIEW="$(/bin/cat "$LOCK" 2>/dev/null)"
    if [[ -n "$LOCK_PID_PREVIEW" ]] && /bin/kill -0 "$LOCK_PID_PREVIEW" 2>/dev/null; then
        LOCK_ALIVE=1
    fi
fi

printf "\n"
printf "%s\n" "${BOLD}${M[uninstall_will_remove]}${RESET}"
found_remove_files=0
for f in "$SYNC_PLIST" "$WATCH_PLIST" "$SYNC_SH" "$WATCH_SH" "$FILTER"; do
    if [[ -e "$f" ]]; then
        printf '%s\n' "    $f"
        found_remove_files=$((found_remove_files+1))
    fi
done
if [[ -e "$LOCK" && "$LOCK_ALIVE" -eq 0 ]]; then
    printf '%s\n' "    $LOCK"
    found_remove_files=$((found_remove_files+1))
fi
if [[ "$LOCK_ALIVE" -eq 1 ]]; then
    info "$(fmt "${M[info_lock_will_keep]}" "$LOCK" "$LOCK_PID_PREVIEW")"
fi
# Decide whether bootout should run. With install files present we always
# bootout (they're being removed). With no files but possibly a stale loaded
# agent, ask explicitly so users who mistyped scripts-dir don't unload an
# unrelated install by accident.
DO_BOOTOUT=0
if [[ "$found_remove_files" -gt 0 ]]; then
    if ! confirm "${M[ask_uninstall_proceed]}"; then
        info "${M[info_uninstall_aborted]}"
        exit 0
    fi
    DO_BOOTOUT=1
else
    warn "${M[uninstall_no_files]}"
    if confirm "${M[ask_uninstall_unload_only]}"; then
        DO_BOOTOUT=1
    fi
fi

LAUNCHD_DOMAIN="gui/$(id -u)"
if [[ "$DO_BOOTOUT" -eq 1 ]]; then
    info "${M[info_uninstall_unloading]}"
    # Prefer modern bootout (load/unload deprecated, return 0 on certain failures).
    if launchctl bootout "$LAUNCHD_DOMAIN/$LABEL_PREFIX"        2>/dev/null; then
        ok "$(fmt "${M[ok_unloaded]}" "$LABEL_PREFIX")"
    else
        warn "$(fmt "${M[warn_not_loaded]}" "$LABEL_PREFIX")"
    fi
    if launchctl bootout "$LAUNCHD_DOMAIN/$LABEL_PREFIX-watch" 2>/dev/null; then
        ok "$(fmt "${M[ok_unloaded]}" "$LABEL_PREFIX-watch")"
    else
        warn "$(fmt "${M[warn_not_loaded]}" "$LABEL_PREFIX-watch")"
    fi
fi

info "${M[info_uninstall_removing]}"
for f in "$SYNC_PLIST" "$WATCH_PLIST" "$SYNC_SH" "$WATCH_SH" "$FILTER"; do
    if [[ -e "$f" ]]; then
        rm -f "$f" && ok "$(fmt "${M[ok_removed]}" "$f")"
    fi
done

# Lock file: removing it while a sync is still running could corrupt the
# bisync state (the live owner's EXIT trap will then rm a different file).
# If the lock holds a live PID, warn and keep it; the installer's idempotent
# cleanup will release it on next run.
if [[ -e "$LOCK" ]]; then
    LOCK_PID="$(/bin/cat "$LOCK" 2>/dev/null)"
    if [[ -n "$LOCK_PID" ]] && /bin/kill -0 "$LOCK_PID" 2>/dev/null; then
        warn "$(fmt "${M[warn_lock_alive]}" "$LOCK" "$LOCK_PID")"
    else
        rm -f "$LOCK" && ok "$(fmt "${M[ok_removed]}" "$LOCK")"
    fi
fi

printf "\n"
# NEVER auto-rm the global rclone bisync cache — it may contain baselines
# for unrelated bisync jobs. Only warn the user with a manual-removal pointer.
CACHE_GLOB="$HOME/Library/Caches/rclone/bisync"
if [[ -d "$CACHE_GLOB" ]]; then
    warn "$(fmt "${M[warn_cache_kept]}" "$CACHE_GLOB")"
fi

printf "\n"
log_files=()
for f in "$LOG" "$LOG_ERR" "$WATCH_LOG" "$WATCH_LOG_ERR"; do
    [[ -e "$f" ]] && log_files+=("$f")
done
if [[ ${#log_files[@]} -gt 0 ]]; then
    printf "%s\n" "${BOLD}${M[uninstall_logs_found]}${RESET}"
    for f in "${log_files[@]}"; do
        printf '%s\n' "    $f"
    done
    if confirm "$(fmt "${M[ask_remove_logs]}" "${#log_files[@]}")"; then
        rm -f "${log_files[@]}"
        ok "${M[ok_logs_removed]}"
    else
        info "${M[info_logs_kept]}"
    fi
fi

printf "\n"
ok "${M[ok_uninstall_complete]}"
