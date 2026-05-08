#!/bin/zsh
# shellcheck shell=bash
# shellcheck disable=SC2088
# Health check for rclone-bisync-launchd-macos. Does not change sync state
# (no bisync, no bootstrap/bootout, no rm/mv on user files). When invoked with
# --check-sync, it runs `rclone bisync --check-sync only`, which compares the
# last bisync listings without applying any sync changes — but rclone may
# create its config/cache directories (~/.config/rclone, ~/Library/Caches/rclone)
# if they don't already exist.

set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

LANG_CODE="en"
case "${LANG:-}" in
    ko*|*ko_*) LANG_CODE="ko" ;;
esac

LABEL_PREFIX="local.rclone-bisync"
SCRIPTS_DIR="$HOME/scripts"
LOCAL_PATH=""
REMOTE=""
CHECK_SYNC=0
LOG_WARN_MB=20

require_arg() { [[ $# -ge 2 ]] || { printf "%s\n" "ERROR option $1 requires an argument" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) require_arg "$@"; LABEL_PREFIX="$2"; shift 2 ;;
        --label=*) LABEL_PREFIX="${1#--label=}"; shift ;;
        --scripts-dir) require_arg "$@"; SCRIPTS_DIR="$2"; shift 2 ;;
        --scripts-dir=*) SCRIPTS_DIR="${1#--scripts-dir=}"; shift ;;
        --local-path) require_arg "$@"; LOCAL_PATH="$2"; shift 2 ;;
        --local-path=*) LOCAL_PATH="${1#--local-path=}"; shift ;;
        --remote) require_arg "$@"; REMOTE="$2"; shift 2 ;;
        --remote=*) REMOTE="${1#--remote=}"; shift ;;
        --check-sync|--check-sync-only) CHECK_SYNC=1; shift ;;
        --log-warn-mb) require_arg "$@"; LOG_WARN_MB="$2"; shift 2 ;;
        --log-warn-mb=*) LOG_WARN_MB="${1#--log-warn-mb=}"; shift ;;
        --lang) require_arg "$@"; LANG_CODE="$2"; shift 2 ;;
        --lang=*) LANG_CODE="${1#--lang=}"; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--label LABEL] [--scripts-dir DIR] [--local-path PATH] [--remote REMOTE] [--check-sync] [--log-warn-mb MB] [--lang en|ko]

Checks prerequisites, rclone config, rendered files, LaunchAgent status, logs,
and optional local/remote sentinel files. Does not apply any sync changes.
With --check-sync, rclone may create its config/cache directories on first
use, but the existing bisync state is not modified.

Options:
  --label LABEL       LaunchAgent label / file prefix (default: local.rclone-bisync)
  --scripts-dir DIR   Directory where rendered shell scripts live (default: ~/scripts)
  --local-path PATH   Optional local sync path to validate
  --remote REMOTE     Optional rclone remote path to validate
  --check-sync        Run rclone bisync --check-sync=only (requires --local-path and --remote)
  --log-warn-mb MB    Warn when any log file is larger than this many MiB (default: 20)
  --lang en|ko        Force output language
EOF
            exit 0
            ;;
        *) printf '%s\n' "ERROR unknown arg: $1" >&2; exit 2 ;;
    esac
done

case "$SCRIPTS_DIR" in
    '~') SCRIPTS_DIR="$HOME" ;;
    '~/'*) SCRIPTS_DIR="$HOME/${SCRIPTS_DIR#'~/'}" ;;
esac

if [[ ! "$LABEL_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf '%s\n' "${RED}ERROR${RESET} invalid label: $LABEL_PREFIX" >&2
    exit 2
fi
if [[ ! "$LOG_WARN_MB" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${RED}ERROR${RESET} invalid --log-warn-mb: $LOG_WARN_MB" >&2
    exit 2
fi
LOG_WARN_BYTES=$((LOG_WARN_MB * 1024 * 1024))

ERRORS=0
WARNINGS=0

msg() {
    local key="$1"
    case "$LANG_CODE:$key" in
        ko:title) printf 'rclone-bisync-launchd-macos doctor\n' ;;
        ko:env) printf '환경\n' ;;
        ko:rclone) printf 'rclone\n' ;;
        ko:install) printf '설치 파일\n' ;;
        ko:launchd) printf 'LaunchAgent\n' ;;
        ko:paths) printf '동기화 경로\n' ;;
        ko:integrity) printf '무결성 점검\n' ;;
        ko:logs) printf '로그\n' ;;
        ko:found) printf '%s 확인됨: %s\n' "$2" "$3" ;;
        ko:missing_cmd) printf '%s를 찾을 수 없습니다\n' "$2" ;;
        ko:macos_only) printf 'macOS 전용 도구입니다\n' ;;
        ko:rclone_old) printf 'rclone v1.71 이상이 필요합니다. 현재: %s\n' "$2" ;;
        ko:rclone_unknown) printf 'rclone 버전을 확인할 수 없습니다\n' ;;
        ko:remote_count) printf '설정된 remote %s개\n' "$2" ;;
        ko:no_remotes) printf '설정된 rclone remote가 없습니다\n' ;;
        ko:file_ok) printf '파일 확인됨: %s\n' "$2" ;;
        ko:file_missing) printf '파일 없음: %s\n' "$2" ;;
        ko:syntax_ok) printf '문법 확인됨: %s\n' "$2" ;;
        ko:plist_ok) printf 'plist 검증 통과: %s\n' "$2" ;;
        ko:loaded) printf '로드됨: %s\n' "$2" ;;
        ko:not_loaded) printf '로드되지 않음: %s\n' "$2" ;;
        ko:path_ok) printf '경로 확인됨: %s\n' "$2" ;;
        ko:path_missing) printf '경로 없음: %s\n' "$2" ;;
        ko:path_not_abs) printf '절대 경로가 아닙니다: %s\n' "$2" ;;
        ko:remote_ok) printf 'remote 접근 가능: %s\n' "$2" ;;
        ko:remote_bad) printf 'remote 접근 실패: %s\n' "$2" ;;
        ko:sentinel_ok) printf '센티널 확인됨: %s\n' "$2" ;;
        ko:sentinel_missing) printf '센티널 없음: %s\n' "$2" ;;
        ko:check_sync_start) printf 'rclone bisync --check-sync=only 실행 중...\n' ;;
        ko:check_sync_ok) printf 'check-sync 통과\n' ;;
        ko:check_sync_fail) printf 'check-sync 실패\n' ;;
        ko:check_sync_missing_args) printf 'check-sync에는 --local-path와 --remote가 모두 필요합니다\n' ;;
        ko:check_sync_no_filter) printf '필터 파일이 없어 --filter-from 없이 check-sync를 실행합니다: %s\n' "$2" ;;
        ko:check_sync_note) printf '참고: check-sync는 현재 파일 내용이 아니라 마지막 bisync listing snapshot을 비교합니다\n' ;;
        ko:fswatch_seen) printf 'fswatch 감지됨: %s\n' "$2" ;;
        ko:fswatch_not_seen) printf 'fswatch 프로세스를 확인하지 못했습니다\n' ;;
        ko:log_ok) printf '로그 파일 확인됨: %s\n' "$2" ;;
        ko:log_missing) printf '로그 파일 없음: %s\n' "$2" ;;
        ko:log_large) printf '로그 파일이 큽니다: %s (%s, 기준: %s MiB)\n' "$2" "$3" "$4" ;;
        ko:cache_ok) printf 'rclone bisync 캐시 디렉토리 확인됨: %s\n' "$2" ;;
        ko:cache_missing) printf 'rclone bisync 캐시 디렉토리가 아직 없습니다: %s\n' "$2" ;;
        ko:not_provided) printf '%s 인자가 제공되지 않았습니다\n' "$2" ;;
        ko:summary_ok) printf '문제 없음\n' ;;
        ko:summary_done) printf '완료: 오류 %s개, 경고 %s개\n' "$2" "$3" ;;
        *) case "$key" in
            title) printf 'rclone-bisync-launchd-macos doctor\n' ;;
            env) printf 'Environment\n' ;;
            rclone) printf 'rclone\n' ;;
            install) printf 'Installed files\n' ;;
            launchd) printf 'LaunchAgents\n' ;;
            paths) printf 'Sync paths\n' ;;
            integrity) printf 'Integrity check\n' ;;
            logs) printf 'Logs\n' ;;
            found) printf '%s found: %s\n' "$2" "$3" ;;
            missing_cmd) printf '%s not found\n' "$2" ;;
            macos_only) printf 'macOS is required\n' ;;
            rclone_old) printf 'rclone v1.71+ required. Found: %s\n' "$2" ;;
            rclone_unknown) printf 'Could not determine rclone version\n' ;;
            remote_count) printf '%s configured remote(s)\n' "$2" ;;
            no_remotes) printf 'No rclone remotes configured\n' ;;
            file_ok) printf 'file found: %s\n' "$2" ;;
            file_missing) printf 'file missing: %s\n' "$2" ;;
            syntax_ok) printf 'syntax ok: %s\n' "$2" ;;
            plist_ok) printf 'plist ok: %s\n' "$2" ;;
            loaded) printf 'loaded: %s\n' "$2" ;;
            not_loaded) printf 'not loaded: %s\n' "$2" ;;
            path_ok) printf 'path found: %s\n' "$2" ;;
            path_missing) printf 'path missing: %s\n' "$2" ;;
            path_not_abs) printf 'not an absolute path: %s\n' "$2" ;;
            remote_ok) printf 'remote reachable: %s\n' "$2" ;;
            remote_bad) printf 'remote not reachable: %s\n' "$2" ;;
            sentinel_ok) printf 'sentinel found: %s\n' "$2" ;;
            sentinel_missing) printf 'sentinel missing: %s\n' "$2" ;;
            check_sync_start) printf 'running rclone bisync --check-sync=only...\n' ;;
            check_sync_ok) printf 'check-sync passed\n' ;;
            check_sync_fail) printf 'check-sync failed\n' ;;
            check_sync_missing_args) printf '--check-sync requires both --local-path and --remote\n' ;;
            check_sync_no_filter) printf 'filter file missing; running check-sync without --filter-from: %s\n' "$2" ;;
            check_sync_note) printf 'Note: check-sync compares the last bisync listing snapshots, not current file contents\n' ;;
            fswatch_seen) printf 'fswatch detected: %s\n' "$2" ;;
            fswatch_not_seen) printf 'fswatch process not detected\n' ;;
            log_ok) printf 'log file found: %s\n' "$2" ;;
            log_missing) printf 'log file missing: %s\n' "$2" ;;
            log_large) printf 'large log file: %s (%s, threshold: %s MiB)\n' "$2" "$3" "$4" ;;
            cache_ok) printf 'rclone bisync cache directory found: %s\n' "$2" ;;
            cache_missing) printf 'rclone bisync cache directory not created yet: %s\n' "$2" ;;
            not_provided) printf '%s not provided\n' "$2" ;;
            summary_ok) printf 'No issues found\n' ;;
            summary_done) printf 'Done: %s error(s), %s warning(s)\n' "$2" "$3" ;;
            *) printf '[missing message: %s]\n' "$key" >&2 ;;
        esac ;;
    esac
}

section() { printf '\n%s\n' "${BOLD}--- $(msg "$1") ---${RESET}"; }
info() { printf '%s\n' "${CYAN}=>${RESET} $*"; }
ok() { printf '%s\n' "${GREEN}OK${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}!!${RESET} $*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '%s\n' "${RED}ERROR${RESET} $*"; ERRORS=$((ERRORS+1)); }

version_at_least_1_71() {
    local version="$1" major rest minor
    major="${version%%.*}"
    rest="${version#*.}"
    minor="${rest%%.*}"
    # Strip any non-digit suffix (e.g. "71-beta1" -> "71") so arithmetic doesn't error.
    major="${major%%[^0-9]*}"
    minor="${minor%%[^0-9]*}"
    [[ -n "$major" && -n "$minor" ]] || return 1
    [[ "$major" -gt 1 || ( "$major" -eq 1 && "$minor" -ge 71 ) ]]
}

human_bytes() {
    local bytes="$1"
    if [[ "$bytes" -ge 1073741824 ]]; then
        printf '%d GiB' $(((bytes + 1073741823) / 1073741824))
    elif [[ "$bytes" -ge 1048576 ]]; then
        printf '%d MiB' $(((bytes + 1048575) / 1048576))
    elif [[ "$bytes" -ge 1024 ]]; then
        printf '%d KiB' $(((bytes + 1023) / 1024))
    else
        printf '%d B' "$bytes"
    fi
}

printf '%s\n' "${BOLD}$(msg title)${RESET}"

section env
if [[ "$(uname)" == "Darwin" ]]; then ok "macOS"; else fail "$(msg macos_only)"; fi
for cmd in rclone fswatch; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$(msg found "$cmd" "$(command -v "$cmd")")"
    else
        fail "$(msg missing_cmd "$cmd")"
    fi
done
if [[ -x /usr/bin/shlock ]]; then ok "$(msg found shlock /usr/bin/shlock)"; else fail "$(msg missing_cmd shlock)"; fi

section rclone
if command -v rclone >/dev/null 2>&1; then
    # Wrap rclone calls so a broken config / non-zero exit gets reported as
    # a fail/warn instead of aborting doctor (set -euo pipefail + pipefail).
    RCLONE_VERSION_RAW=""
    if RCLONE_VERSION_RAW="$(rclone version 2>/dev/null)"; then
        RCLONE_VERSION="$(printf '%s\n' "$RCLONE_VERSION_RAW" | awk 'NR==1 { gsub(/^rclone v/, ""); print $1 }')"
        if [[ -z "$RCLONE_VERSION" ]]; then
            fail "$(msg rclone_unknown)"
        elif version_at_least_1_71 "$RCLONE_VERSION"; then
            ok "rclone $RCLONE_VERSION"
        else
            fail "$(msg rclone_old "$RCLONE_VERSION")"
        fi
    else
        fail "$(msg rclone_unknown)"
    fi
    REMOTE_COUNT=0
    if RCLONE_REMOTES="$(rclone listremotes 2>/dev/null)"; then
        REMOTE_COUNT="$(printf '%s' "$RCLONE_REMOTES" | grep -c ':$' || true)"
    else
        warn "$(msg no_remotes)"
    fi
    if [[ "$REMOTE_COUNT" -gt 0 ]]; then
        ok "$(msg remote_count "$REMOTE_COUNT")"
    elif [[ "${RCLONE_REMOTES+set}" == "set" ]]; then
        warn "$(msg no_remotes)"
    fi
fi

section install
SYNC_SH="$SCRIPTS_DIR/${LABEL_PREFIX}.sh"
WATCH_SH="$SCRIPTS_DIR/${LABEL_PREFIX}-watch.sh"
FILTER="$SCRIPTS_DIR/${LABEL_PREFIX}-filter.txt"
SYNC_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}.plist"
WATCH_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}-watch.plist"
for f in "$SYNC_SH" "$WATCH_SH" "$FILTER" "$SYNC_PLIST" "$WATCH_PLIST"; do
    if [[ -e "$f" ]]; then ok "$(msg file_ok "$f")"; else warn "$(msg file_missing "$f")"; fi
done
if [[ -f "$SYNC_SH" ]]; then if zsh -n "$SYNC_SH"; then ok "$(msg syntax_ok "$SYNC_SH")"; else fail "zsh -n failed: $SYNC_SH"; fi; fi
if [[ -f "$WATCH_SH" ]]; then if zsh -n "$WATCH_SH"; then ok "$(msg syntax_ok "$WATCH_SH")"; else fail "zsh -n failed: $WATCH_SH"; fi; fi
if [[ -f "$SYNC_PLIST" ]]; then if /usr/bin/plutil -lint "$SYNC_PLIST" >/dev/null; then ok "$(msg plist_ok "$SYNC_PLIST")"; else fail "plutil failed: $SYNC_PLIST"; fi; fi
if [[ -f "$WATCH_PLIST" ]]; then if /usr/bin/plutil -lint "$WATCH_PLIST" >/dev/null; then ok "$(msg plist_ok "$WATCH_PLIST")"; else fail "plutil failed: $WATCH_PLIST"; fi; fi

section launchd
LAUNCHD_DOMAIN="gui/$(id -u)"
if launchctl print "$LAUNCHD_DOMAIN/$LABEL_PREFIX" >/dev/null 2>&1; then ok "$(msg loaded "$LABEL_PREFIX")"; else warn "$(msg not_loaded "$LABEL_PREFIX")"; fi
if launchctl print "$LAUNCHD_DOMAIN/$LABEL_PREFIX-watch" >/dev/null 2>&1; then ok "$(msg loaded "$LABEL_PREFIX-watch")"; else warn "$(msg not_loaded "$LABEL_PREFIX-watch")"; fi
if [[ -n "$LOCAL_PATH" ]]; then
    if command -v pgrep >/dev/null 2>&1 && pgrep -fl fswatch 2>/dev/null | grep -F -- "$LOCAL_PATH" >/dev/null; then
        ok "$(msg fswatch_seen "$LOCAL_PATH")"
    else
        warn "$(msg fswatch_not_seen)"
    fi
fi

section paths
if [[ -n "$LOCAL_PATH" ]]; then
    if [[ "$LOCAL_PATH" != /* ]]; then fail "$(msg path_not_abs "$LOCAL_PATH")"
    elif [[ -d "$LOCAL_PATH" ]]; then ok "$(msg path_ok "$LOCAL_PATH")"
    else fail "$(msg path_missing "$LOCAL_PATH")"; fi
    if [[ -e "$LOCAL_PATH/RCLONE_TEST" ]]; then ok "$(msg sentinel_ok "$LOCAL_PATH/RCLONE_TEST")"; else warn "$(msg sentinel_missing "$LOCAL_PATH/RCLONE_TEST")"; fi
else
    warn "$(msg not_provided --local-path)"
fi
if [[ -n "$REMOTE" ]]; then
    if rclone lsd "$REMOTE" >/dev/null 2>&1 || rclone lsf "$REMOTE" >/dev/null 2>&1; then ok "$(msg remote_ok "$REMOTE")"; else fail "$(msg remote_bad "$REMOTE")"; fi
    if rclone lsf "$REMOTE" --files-only 2>/dev/null | grep -Fx 'RCLONE_TEST' >/dev/null; then ok "$(msg sentinel_ok "$REMOTE/RCLONE_TEST")"; else warn "$(msg sentinel_missing "$REMOTE/RCLONE_TEST")"; fi
else
    warn "$(msg not_provided --remote)"
fi

if [[ "$CHECK_SYNC" -eq 1 ]]; then
    section integrity
    info "$(msg check_sync_note)"
    if [[ -z "$LOCAL_PATH" || -z "$REMOTE" ]]; then
        fail "$(msg check_sync_missing_args)"
    elif ! command -v rclone >/dev/null 2>&1; then
        fail "$(msg missing_cmd rclone)"
    else
        CHECK_SYNC_CMD=(
            rclone bisync "$REMOTE" "$LOCAL_PATH"
            --check-access
            --resilient
            --recover
            --max-lock 2m
            --check-sync only
        )
        if [[ -f "$FILTER" ]]; then
            CHECK_SYNC_CMD+=(--filter-from "$FILTER")
        else
            warn "$(msg check_sync_no_filter "$FILTER")"
        fi

        info "$(msg check_sync_start)"
        CHECK_SYNC_OUTPUT=""
        if CHECK_SYNC_OUTPUT="$("${CHECK_SYNC_CMD[@]}" 2>&1)"; then
            ok "$(msg check_sync_ok)"
        else
            fail "$(msg check_sync_fail)"
            printf '%s\n' "$CHECK_SYNC_OUTPUT" | tail -12 | sed 's/^/    /'
        fi
    fi
fi

section logs
for f in "$HOME/Library/Logs/${LABEL_PREFIX}.log" "$HOME/Library/Logs/${LABEL_PREFIX}-error.log" "$HOME/Library/Logs/${LABEL_PREFIX}-watch.log" "$HOME/Library/Logs/${LABEL_PREFIX}-watch-error.log"; do
    if [[ -e "$f" ]]; then
        ok "$(msg log_ok "$f")"
        LOG_SIZE="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
        if [[ "$LOG_SIZE" =~ ^[0-9]+$ && "$LOG_SIZE" -gt "$LOG_WARN_BYTES" ]]; then
            warn "$(msg log_large "$f" "$(human_bytes "$LOG_SIZE")" "$LOG_WARN_MB")"
        fi
    else
        warn "$(msg log_missing "$f")"
    fi
done
CACHE_DIR="$HOME/Library/Caches/rclone/bisync"
if [[ -d "$CACHE_DIR" ]]; then ok "$(msg cache_ok "$CACHE_DIR")"; else warn "$(msg cache_missing "$CACHE_DIR")"; fi

printf '\n'
if [[ "$ERRORS" -eq 0 && "$WARNINGS" -eq 0 ]]; then
    ok "$(msg summary_ok)"
    exit 0
fi
printf '%s\n' "$(msg summary_done "$ERRORS" "$WARNINGS")"
# Exit codes: 0=ok, 1=warnings only, 2=arg error (handled earlier), 3=errors.
if [[ "$ERRORS" -gt 0 ]]; then
    exit 3
fi
exit 1
