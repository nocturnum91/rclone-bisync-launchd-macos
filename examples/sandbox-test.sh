#!/bin/zsh
# shellcheck shell=bash
# shellcheck disable=SC2329
# Sandbox integration test for rclone-bisync-launchd-macos templates.
# Renders templates with isolated paths, exercises sync + fswatch + shlock,
# then cleans up. Does NOT install or load LaunchAgents.
#
# Usage:
#   ./examples/sandbox-test.sh [--keep]    # --keep skips cleanup at end

set -euo pipefail
# BGNICE renices backgrounded jobs; on locked-down zsh setups this fails
# the test silently when we run "$WATCH_SH" in the background.
unsetopt BGNICE 2>/dev/null || true

SANDBOX="/tmp/rblm-sandbox"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# Isolate rclone state — without this, rclone would write its config/cache
# under the user's $HOME and leave bisync baselines behind. The README claims
# the test runs in /tmp; these env vars make that claim true. Files/dirs are
# created in step 1 below (after `rm -rf $SANDBOX` so we don't recreate and
# then immediately delete them).
export RCLONE_CONFIG="$SANDBOX/rclone.conf"
export RCLONE_CACHE_DIR="$SANDBOX/Library/Caches/rclone"

step() { echo; echo "=== $1 ==="; }
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
ng()   { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

cleanup() {
    if [[ $KEEP -eq 1 ]]; then
        echo
        echo "Sandbox preserved at $SANDBOX (--keep)"
        return
    fi
    [[ -f "$SANDBOX/lock-file-path" ]] && rm -f "$(cat "$SANDBOX/lock-file-path")"
    # Step 14 spawns a `sleep 600` whose PID is recorded in this lock. Kill the
    # sleep process so the test never leaves background jobs behind, then drop
    # the lock file so a re-run starts from a clean state.
    if [[ -f "/tmp/com.test.uninstall-lock.lock" ]]; then
        local stale_pid
        stale_pid=$(/bin/cat "/tmp/com.test.uninstall-lock.lock" 2>/dev/null)
        [[ -n "$stale_pid" ]] && kill "$stale_pid" 2>/dev/null || true
        rm -f "/tmp/com.test.uninstall-lock.lock"
    fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Context-safe escapers (mirror install.sh; printf is raw, unlike `print --`).
shell_quote() {
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
sed_safe() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/&/\\\&/g'
}

step "1. Set up sandbox structure"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"/{local,remote,scripts,logs,Library/Logs,Library/Caches/rclone}
: > "$SANDBOX/rclone.conf"
ok "created $SANDBOX"

step "2. Render templates"
LOCAL_PATH="$SANDBOX/local"
REMOTE=":local:$SANDBOX/remote"
LABEL_PREFIX="com.test.rblm-sandbox"
HOME_DIR="$SANDBOX"
SCRIPTS_DIR="$SANDBOX/scripts"
RCLONE_BIN="$(command -v rclone)"
FSWATCH_BIN="$(command -v fswatch)"
DEBOUNCE_SEC=2
INTERVAL_SEC=60
MAX_DELETE_PERCENT=50

if [[ -z "$RCLONE_BIN" ]]; then ng "rclone not found in PATH"; exit 1; fi
if [[ -z "$FSWATCH_BIN" ]]; then ng "fswatch not found in PATH"; exit 1; fi

LOCAL_PATH_SH=$(shell_quote "$LOCAL_PATH")
REMOTE_SH=$(shell_quote "$REMOTE")
LABEL_PREFIX_SH=$(shell_quote "$LABEL_PREFIX")
RCLONE_BIN_SH=$(shell_quote "$RCLONE_BIN")
FSWATCH_BIN_SH=$(shell_quote "$FSWATCH_BIN")
SCRIPTS_DIR_SH=$(shell_quote "$SCRIPTS_DIR")
HOME_SH=$(shell_quote "$HOME_DIR")
MAX_DELETE_PERCENT_SH=$(shell_quote "$MAX_DELETE_PERCENT")
BACKUP_FLAGS_SH=""

LOCAL_PATH_XML=$(xml_escape "$LOCAL_PATH")
LABEL_PREFIX_XML=$(xml_escape "$LABEL_PREFIX")
SCRIPTS_DIR_XML=$(xml_escape "$SCRIPTS_DIR")
HOME_XML=$(xml_escape "$HOME_DIR")

SYNC_SH="$SCRIPTS_DIR/${LABEL_PREFIX}.sh"
WATCH_SH="$SCRIPTS_DIR/${LABEL_PREFIX}-watch.sh"
FILTER="$SCRIPTS_DIR/${LABEL_PREFIX}-filter.txt"
SYNC_PLIST="$SANDBOX/${LABEL_PREFIX}.plist"
WATCH_PLIST="$SANDBOX/${LABEL_PREFIX}-watch.plist"
SYNC_SCRIPT_SH=$(shell_quote "$SYNC_SH")

render_shell() {
    sed \
        -e "s|{{LOCAL_PATH_SH}}|$(sed_safe "$LOCAL_PATH_SH")|g" \
        -e "s|{{REMOTE_SH}}|$(sed_safe "$REMOTE_SH")|g" \
        -e "s|{{LABEL_PREFIX_SH}}|$(sed_safe "$LABEL_PREFIX_SH")|g" \
        -e "s|{{RCLONE_BIN_SH}}|$(sed_safe "$RCLONE_BIN_SH")|g" \
        -e "s|{{FSWATCH_BIN_SH}}|$(sed_safe "$FSWATCH_BIN_SH")|g" \
        -e "s|{{SCRIPTS_DIR_SH}}|$(sed_safe "$SCRIPTS_DIR_SH")|g" \
        -e "s|{{HOME_SH}}|$(sed_safe "$HOME_SH")|g" \
        -e "s|{{MAX_DELETE_PERCENT_SH}}|$(sed_safe "$MAX_DELETE_PERCENT_SH")|g" \
        -e "s|{{BACKUP_FLAGS_SH}}|$(sed_safe "$BACKUP_FLAGS_SH")|g" \
        -e "s|{{SYNC_SCRIPT_SH}}|$(sed_safe "$SYNC_SCRIPT_SH")|g" \
        -e "s|{{DEBOUNCE_SEC}}|$DEBOUNCE_SEC|g" \
        "$1"
}
render_xml() {
    sed \
        -e "s|{{LABEL_PREFIX_XML}}|$(sed_safe "$LABEL_PREFIX_XML")|g" \
        -e "s|{{LOCAL_PATH_XML}}|$(sed_safe "$LOCAL_PATH_XML")|g" \
        -e "s|{{SCRIPTS_DIR_XML}}|$(sed_safe "$SCRIPTS_DIR_XML")|g" \
        -e "s|{{HOME_XML}}|$(sed_safe "$HOME_XML")|g" \
        -e "s|{{INTERVAL_SEC}}|$INTERVAL_SEC|g" \
        "$1"
}

render_shell "$REPO_ROOT/templates/scripts/sync.sh.tmpl"          > "$SYNC_SH"
render_shell "$REPO_ROOT/templates/scripts/watch.sh.tmpl"         > "$WATCH_SH"
cp           "$REPO_ROOT/templates/scripts/filter.txt"              "$FILTER"
render_xml   "$REPO_ROOT/templates/launchagents/sync.plist.tmpl"  > "$SYNC_PLIST"
render_xml   "$REPO_ROOT/templates/launchagents/watch.plist.tmpl" > "$WATCH_PLIST"
chmod +x "$SYNC_SH" "$WATCH_SH"
ok "rendered 5 files"

step "3. Static validation"
# Templates use #!/bin/zsh — match installer (install.sh uses zsh -n).
if zsh -n "$SYNC_SH";  then ok  "sync.sh syntax";  else ng "sync.sh syntax"; fi
if zsh -n "$WATCH_SH"; then ok  "watch.sh syntax"; else ng "watch.sh syntax"; fi
if /usr/bin/plutil -lint "$SYNC_PLIST" >/dev/null;  then ok "sync.plist lint";  else ng "sync.plist lint"; fi
if /usr/bin/plutil -lint "$WATCH_PLIST" >/dev/null; then ok "watch.plist lint"; else ng "watch.plist lint"; fi

if ! grep -lE '\{\{[A-Z_]+\}\}' "$SYNC_SH" "$WATCH_SH" "$SYNC_PLIST" "$WATCH_PLIST" 2>/dev/null; then
    ok "no unrendered placeholders"
else
    ng "unrendered placeholders found"
fi

step "4. Initial resync (with sentinel)"
echo "hello world" > "$LOCAL_PATH/note1.md"
echo "rblm test" > "$LOCAL_PATH/note2.md"
mkdir -p "$LOCAL_PATH/sub"
echo "nested" > "$LOCAL_PATH/sub/nested.md"
# Create RCLONE_TEST sentinel on both sides for --check-access
touch "$LOCAL_PATH/RCLONE_TEST"
"$RCLONE_BIN" copyto "$LOCAL_PATH/RCLONE_TEST" "$REMOTE/RCLONE_TEST" 2>/dev/null || true

"$RCLONE_BIN" bisync "$REMOTE" "$LOCAL_PATH" \
    --filter-from "$FILTER" \
    --check-access \
    --resilient --recover --max-lock 2m \
    --conflict-resolve newer \
    --resync \
    --log-file "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log" \
    --log-level INFO 2>&1 | tail -3 || true

if [[ -f "$LOCAL_PATH/note1.md" && -f "$SANDBOX/remote/note1.md" ]]; then
    ok "remote received initial files"
else
    ng "initial resync did not propagate to remote"
fi

step "5. Sync via rendered sync.sh"
echo "after resync" > "$LOCAL_PATH/note3.md"
"$SYNC_SH"
sleep 1
if [[ -f "$SANDBOX/remote/note3.md" ]]; then
    ok "sync.sh propagated note3.md to remote"
else
    ng "sync.sh did not propagate note3.md"
fi

step "6. shlock concurrency guard"
LOCK_FILE="/tmp/${LABEL_PREFIX}.lock"
echo "$LOCK_FILE" > "$SANDBOX/lock-file-path"
/usr/bin/shlock -f "$LOCK_FILE" -p $$ >/dev/null
START=$(date +%s)
"$SYNC_SH"
RC=$?
END=$(date +%s)
DURATION=$((END - START))
rm -f "$LOCK_FILE"
if [[ $RC -eq 0 && $DURATION -le 2 ]]; then
    ok "shlock blocked second invocation (exited in ${DURATION}s)"
else
    ng "shlock did not block second invocation (rc=$RC, ${DURATION}s)"
fi

step "7. fswatch real-time trigger"
"$WATCH_SH" >"$SANDBOX/watch-stdout.log" 2>&1 &
WATCH_PID=$!
sleep 2
echo "fswatch trigger test $(date +%s)" > "$LOCAL_PATH/fswatch-test.md"
sleep $((DEBOUNCE_SEC + 8))
kill $WATCH_PID 2>/dev/null || true
wait $WATCH_PID 2>/dev/null || true
if [[ -f "$SANDBOX/remote/fswatch-test.md" ]]; then
    ok "fswatch triggered sync, file reached remote"
else
    ng "fswatch did not propagate change within ${DEBOUNCE_SEC}+8s"
fi

step "8a. --check-access aborts when LOCAL sentinel missing"
rm -f "$LOCAL_PATH/RCLONE_TEST"
SENTINEL_LOG_BEFORE=$(wc -c < "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log" 2>/dev/null || echo 0)
"$SYNC_SH" || true   # rclone bisync exits non-zero on sentinel-missing; that's the point.
sleep 1
SENTINEL_LOG_AFTER=$(wc -c < "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log")
if [[ $SENTINEL_LOG_AFTER -gt $SENTINEL_LOG_BEFORE ]] && \
   tail -c $((SENTINEL_LOG_AFTER - SENTINEL_LOG_BEFORE)) "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log" \
       | grep -q "Access test failed\|check.access\|check file check failed"; then
    ok "bisync aborted on missing local sentinel"
else
    ng "bisync did not abort on missing local sentinel"
fi
touch "$LOCAL_PATH/RCLONE_TEST"

step "8b. --check-access aborts when REMOTE sentinel missing"
rm -f "$SANDBOX/remote/RCLONE_TEST"
SENTINEL_LOG_BEFORE=$(wc -c < "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log")
"$SYNC_SH" || true
sleep 1
SENTINEL_LOG_AFTER=$(wc -c < "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log")
if [[ $SENTINEL_LOG_AFTER -gt $SENTINEL_LOG_BEFORE ]] && \
   tail -c $((SENTINEL_LOG_AFTER - SENTINEL_LOG_BEFORE)) "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log" \
       | grep -q "Access test failed\|check.access\|check file check failed"; then
    ok "bisync aborted on missing remote sentinel"
else
    ng "bisync did not abort on missing remote sentinel"
fi
"$RCLONE_BIN" copyto "$LOCAL_PATH/RCLONE_TEST" "$REMOTE/RCLONE_TEST" 2>/dev/null || true

step "9. Special-character substitution"
# Use a brutal value: spaces, &, ', ", $, backslash, backticks
SP_SANDBOX="$SANDBOX/special"
mkdir -p "$SP_SANDBOX/scripts"
SP_LOCAL_PATH="$SANDBOX/path with space & 'apos' \"dq\" \$dollar \\bs \`tick\`"
SP_REMOTE=':local:'"$SANDBOX/remote with & quotes"
SP_LABEL='com.test.rblm-special'
SP_SCRIPTS="$SP_SANDBOX/scripts with & 'apos'"
mkdir -p "$SP_SCRIPTS"

SP_LOCAL_SH=$(shell_quote "$SP_LOCAL_PATH")
SP_LOCAL_XML=$(xml_escape "$SP_LOCAL_PATH")
SP_REMOTE_SH=$(shell_quote "$SP_REMOTE")
SP_LABEL_SH=$(shell_quote "$SP_LABEL")
SP_LABEL_XML=$(xml_escape "$SP_LABEL")
SP_SCRIPTS_SH=$(shell_quote "$SP_SCRIPTS")
SP_SCRIPTS_XML=$(xml_escape "$SP_SCRIPTS")
SP_HOME_SH=$(shell_quote "$HOME_DIR")
SP_HOME_XML=$(xml_escape "$HOME_DIR")
SP_MAX_DELETE_PERCENT_SH=$(shell_quote "$MAX_DELETE_PERCENT")
SP_BACKUP_FLAGS_SH=""
SP_RCLONE_SH=$(shell_quote "$RCLONE_BIN")
SP_FSWATCH_SH=$(shell_quote "$FSWATCH_BIN")
SP_SYNC_SH_PATH="$SP_SCRIPTS/${SP_LABEL}.sh"
SP_SYNC_SCRIPT_SH=$(shell_quote "$SP_SYNC_SH_PATH")

sed \
    -e "s|{{LOCAL_PATH_SH}}|$(sed_safe "$SP_LOCAL_SH")|g" \
    -e "s|{{REMOTE_SH}}|$(sed_safe "$SP_REMOTE_SH")|g" \
    -e "s|{{LABEL_PREFIX_SH}}|$(sed_safe "$SP_LABEL_SH")|g" \
    -e "s|{{RCLONE_BIN_SH}}|$(sed_safe "$SP_RCLONE_SH")|g" \
    -e "s|{{FSWATCH_BIN_SH}}|$(sed_safe "$SP_FSWATCH_SH")|g" \
    -e "s|{{SCRIPTS_DIR_SH}}|$(sed_safe "$SP_SCRIPTS_SH")|g" \
    -e "s|{{HOME_SH}}|$(sed_safe "$SP_HOME_SH")|g" \
    -e "s|{{MAX_DELETE_PERCENT_SH}}|$(sed_safe "$SP_MAX_DELETE_PERCENT_SH")|g" \
    -e "s|{{BACKUP_FLAGS_SH}}|$(sed_safe "$SP_BACKUP_FLAGS_SH")|g" \
    -e "s|{{SYNC_SCRIPT_SH}}|$(sed_safe "$SP_SYNC_SCRIPT_SH")|g" \
    -e "s|{{DEBOUNCE_SEC}}|$DEBOUNCE_SEC|g" \
    "$REPO_ROOT/templates/scripts/sync.sh.tmpl" > "$SP_SYNC_SH_PATH"
SP_WATCH_SH_PATH="$SP_SCRIPTS/${SP_LABEL}-watch.sh"
sed \
    -e "s|{{LOCAL_PATH_SH}}|$(sed_safe "$SP_LOCAL_SH")|g" \
    -e "s|{{LABEL_PREFIX_SH}}|$(sed_safe "$SP_LABEL_SH")|g" \
    -e "s|{{FSWATCH_BIN_SH}}|$(sed_safe "$SP_FSWATCH_SH")|g" \
    -e "s|{{SCRIPTS_DIR_SH}}|$(sed_safe "$SP_SCRIPTS_SH")|g" \
    -e "s|{{HOME_SH}}|$(sed_safe "$SP_HOME_SH")|g" \
    -e "s|{{SYNC_SCRIPT_SH}}|$(sed_safe "$SP_SYNC_SCRIPT_SH")|g" \
    -e "s|{{DEBOUNCE_SEC}}|$DEBOUNCE_SEC|g" \
    "$REPO_ROOT/templates/scripts/watch.sh.tmpl" > "$SP_WATCH_SH_PATH"

SP_SYNC_PLIST="$SP_SANDBOX/${SP_LABEL}.plist"
SP_WATCH_PLIST="$SP_SANDBOX/${SP_LABEL}-watch.plist"
sed \
    -e "s|{{LABEL_PREFIX_XML}}|$(sed_safe "$SP_LABEL_XML")|g" \
    -e "s|{{LOCAL_PATH_XML}}|$(sed_safe "$SP_LOCAL_XML")|g" \
    -e "s|{{SCRIPTS_DIR_XML}}|$(sed_safe "$SP_SCRIPTS_XML")|g" \
    -e "s|{{HOME_XML}}|$(sed_safe "$SP_HOME_XML")|g" \
    -e "s|{{INTERVAL_SEC}}|$INTERVAL_SEC|g" \
    "$REPO_ROOT/templates/launchagents/sync.plist.tmpl" > "$SP_SYNC_PLIST"
sed \
    -e "s|{{LABEL_PREFIX_XML}}|$(sed_safe "$SP_LABEL_XML")|g" \
    -e "s|{{LOCAL_PATH_XML}}|$(sed_safe "$SP_LOCAL_XML")|g" \
    -e "s|{{SCRIPTS_DIR_XML}}|$(sed_safe "$SP_SCRIPTS_XML")|g" \
    -e "s|{{HOME_XML}}|$(sed_safe "$SP_HOME_XML")|g" \
    -e "s|{{INTERVAL_SEC}}|$INTERVAL_SEC|g" \
    "$REPO_ROOT/templates/launchagents/watch.plist.tmpl" > "$SP_WATCH_PLIST"

# Templates use #!/bin/zsh — match installer's zsh -n.
if zsh -n "$SP_SYNC_SH_PATH";  then ok "special-char sync.sh zsh-syntax valid";  else ng "special-char sync.sh zsh-syntax invalid"; fi
if zsh -n "$SP_WATCH_SH_PATH"; then ok "special-char watch.sh zsh-syntax valid"; else ng "special-char watch.sh zsh-syntax invalid"; fi
if /usr/bin/plutil -lint "$SP_SYNC_PLIST" >/dev/null; then ok "special-char sync.plist lint valid"; else ng "special-char sync.plist lint invalid"; fi
if /usr/bin/plutil -lint "$SP_WATCH_PLIST" >/dev/null; then ok "special-char watch.plist lint valid"; else ng "special-char watch.plist lint invalid"; fi

# Round-trip every shell-quoted variable through bash AND zsh.
# Extract the single VAR=... line from the rendered script (avoids issues with
# sourcing whole files containing apostrophes in their own paths) and let the
# target interpreter parse it natively.
roundtrip_var_through() {
    local interp="$1" file="$2" varname="$3" expected="$4"
    local line actual
    line=$(grep "^${varname}=" "$file" | head -1)
    if [[ -z "$line" ]]; then
        ng "[$interp] $varname declaration not found in rendered script"
        return
    fi
    actual=$("$interp" -c "$line"$'\n'"printf '%s' \"\$$varname\"" 2>/dev/null) || actual=""
    if [[ "$actual" == "$expected" ]]; then
        ok "[$interp] $varname round-trips correctly"
    else
        ng "[$interp] $varname mismatch — expected '$expected', got '$actual'"
    fi
}
for INTERP in bash zsh; do
    roundtrip_var_through "$INTERP" "$SP_SYNC_SH_PATH" LOCAL_PATH "$SP_LOCAL_PATH"
    roundtrip_var_through "$INTERP" "$SP_SYNC_SH_PATH" REMOTE     "$SP_REMOTE"
    roundtrip_var_through "$INTERP" "$SP_SYNC_SH_PATH" SCRIPTS_DIR "$SP_SCRIPTS"
done

# XML decode round-trip (use plutil to extract Label string)
SP_PLIST_LABEL=$(/usr/bin/plutil -extract Label raw -o - "$SP_SYNC_PLIST" 2>/dev/null || echo "")
if [[ "$SP_PLIST_LABEL" == "$SP_LABEL" ]]; then
    ok "plist Label decodes back to original label"
else
    ng "plist Label mismatch — expected '$SP_LABEL', got '$SP_PLIST_LABEL'"
fi
# PathState key (LOCAL_PATH_XML) round-trip
SP_PATHSTATE=$(/usr/bin/plutil -extract KeepAlive.PathState raw -o - "$SP_WATCH_PLIST" 2>/dev/null | head -1 || echo "")
if [[ -z "$SP_PATHSTATE" ]]; then
    # plutil doesn't allow extracting dict keys directly; alternatively grep the rendered content
    if grep -F -- "<key>$SP_LOCAL_XML</key>" "$SP_WATCH_PLIST" >/dev/null; then
        ok "watch.plist PathState contains XML-escaped local path"
    else
        ng "watch.plist PathState missing escaped local path"
    fi
else
    ok "watch.plist PathState extractable"
fi

step "10. install.sh --dry-run smoke test (validates real renderer + helper drift)"
SMOKE_VAULT="$SANDBOX/smoke-vault"
SMOKE_REMOTE_DIR="$SANDBOX/smoke-remote"
mkdir -p "$SMOKE_VAULT" "$SMOKE_REMOTE_DIR"
SMOKE_OUT="$SANDBOX/smoke-out"
mkdir -p "$SMOKE_OUT"
rm -rf /tmp/rblm-dryrun
SMOKE_LOG="$SMOKE_OUT/install.log"
"$REPO_ROOT/install.sh" --dry-run --lang en >"$SMOKE_LOG" 2>&1 <<EOF
y
$SMOKE_VAULT
:local:$SMOKE_REMOTE_DIR
com.test.smoke


30
600
50
:local:$SANDBOX/smoke-remote-backup
$SANDBOX/smoke-local-backup
EOF
SMOKE_RC=$?
SMOKE_SYNC=/tmp/rblm-dryrun/scripts/com.test.smoke.sh
SMOKE_PLIST=/tmp/rblm-dryrun/LaunchAgents/com.test.smoke.plist
if [[ $SMOKE_RC -eq 0 && -f "$SMOKE_SYNC" && -f "$SMOKE_PLIST" ]]; then
    ok "install.sh --dry-run rendered all files (rc=0)"
else
    ng "install.sh --dry-run failed (rc=$SMOKE_RC); see $SMOKE_LOG"
fi
if zsh -n "$SMOKE_SYNC"; then
    ok "install.sh-rendered sync.sh passes zsh -n"
else
    ng "install.sh-rendered sync.sh has zsh syntax error"
fi
if /usr/bin/plutil -lint "$SMOKE_PLIST" >/dev/null; then
    ok "install.sh-rendered plist passes plutil -lint"
else
    ng "install.sh-rendered plist has plist error"
fi
if grep -F -- "--max-delete" "$SMOKE_SYNC" >/dev/null; then
    ok "install.sh-rendered sync.sh includes configured max-delete"
else
    ng "install.sh-rendered sync.sh missing configured max-delete"
fi
if grep -F -- "--backup-dir1" "$SMOKE_SYNC" >/dev/null && grep -F -- "--backup-dir2" "$SMOKE_SYNC" >/dev/null; then
    ok "install.sh-rendered sync.sh includes configured backup dirs"
else
    ng "install.sh-rendered sync.sh missing configured backup dirs"
fi
rm -rf /tmp/rblm-dryrun

step "11. doctor.sh --check-sync"
DOCTOR_LOG="$SANDBOX/doctor.log"
# Exit codes: 0=ok, 1=warnings only, 3=errors, 2=arg error.
# Sandbox lacks log files in $HOME/Library/Logs so warnings are expected → 1.
DOCTOR_RC=0
"$REPO_ROOT/doctor.sh" --label "$LABEL_PREFIX" --scripts-dir "$SCRIPTS_DIR" --local-path "$LOCAL_PATH" --remote "$REMOTE" --check-sync --lang en >"$DOCTOR_LOG" 2>&1 || DOCTOR_RC=$?
if [[ "$DOCTOR_RC" -eq 0 || "$DOCTOR_RC" -eq 1 ]]; then
    ok "doctor.sh --check-sync exited cleanly (rc=$DOCTOR_RC)"
else
    ng "doctor.sh --check-sync failed unexpectedly (rc=$DOCTOR_RC); see $DOCTOR_LOG"
fi
if grep -F -- "check-sync passed" "$DOCTOR_LOG" >/dev/null; then
    ok "doctor.sh reported check-sync passed"
else
    ng "doctor.sh did not report check-sync passed"
fi

step "12. doctor.sh log-size warning"
DOCTOR_LOG_SIZE_LOG="$SANDBOX/doctor-log-size.log"
printf 'large enough for threshold zero\n' > "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log"
DOCTOR_LOG_RC=0
HOME="$SANDBOX" "$REPO_ROOT/doctor.sh" --label "$LABEL_PREFIX" --scripts-dir "$SCRIPTS_DIR" --log-warn-mb 0 --lang en >"$DOCTOR_LOG_SIZE_LOG" 2>&1 || DOCTOR_LOG_RC=$?
# Threshold 0 + non-empty log → at least one warning → rc=1 expected.
if [[ "$DOCTOR_LOG_RC" -eq 1 ]]; then
    ok "doctor.sh --log-warn-mb exited with rc=1 (warnings present, expected)"
else
    ng "doctor.sh --log-warn-mb unexpected rc=$DOCTOR_LOG_RC; see $DOCTOR_LOG_SIZE_LOG"
fi
if grep -F -- "large log file:" "$DOCTOR_LOG_SIZE_LOG" >/dev/null; then
    ok "doctor.sh reported large log file"
else
    ng "doctor.sh did not report large log file"
fi

step "13. uninstall.sh lists install and log files"
UNINSTALL_LABEL="com.test.uninstall"
UNINSTALL_SCRIPTS="$SANDBOX/uninstall-scripts"
UNINSTALL_LOG="$SANDBOX/uninstall.log"
mkdir -p "$UNINSTALL_SCRIPTS" "$SANDBOX/Library/LaunchAgents" "$SANDBOX/Library/Logs"
touch "$UNINSTALL_SCRIPTS/${UNINSTALL_LABEL}.sh"
touch "$UNINSTALL_SCRIPTS/${UNINSTALL_LABEL}-watch.sh"
touch "$UNINSTALL_SCRIPTS/${UNINSTALL_LABEL}-filter.txt"
touch "$SANDBOX/Library/LaunchAgents/${UNINSTALL_LABEL}.plist"
touch "$SANDBOX/Library/LaunchAgents/${UNINSTALL_LABEL}-watch.plist"
touch "$SANDBOX/Library/Logs/${UNINSTALL_LABEL}.log"
touch "$SANDBOX/Library/Logs/${UNINSTALL_LABEL}-watch-error.log"
if HOME="$SANDBOX" "$REPO_ROOT/uninstall.sh" --label "$UNINSTALL_LABEL" --lang en >"$UNINSTALL_LOG" 2>&1 <<EOF
$UNINSTALL_SCRIPTS
y
y
EOF
then
    ok "uninstall.sh exited successfully"
else
    ng "uninstall.sh failed; see $UNINSTALL_LOG"
fi
if grep -F -- "Install files to remove:" "$UNINSTALL_LOG" >/dev/null && grep -F -- "Log files found:" "$UNINSTALL_LOG" >/dev/null; then
    ok "uninstall.sh listed install files and log files"
else
    ng "uninstall.sh did not list expected file sections"
fi
if [[ ! -e "$UNINSTALL_SCRIPTS/${UNINSTALL_LABEL}.sh" && ! -e "$SANDBOX/Library/Logs/${UNINSTALL_LABEL}.log" ]]; then
    ok "uninstall.sh removed selected files"
else
    ng "uninstall.sh left selected files behind"
fi

step "14. uninstall.sh preserves lock with live PID, removes lock with dead PID"
LIVE_LOCK_LABEL="com.test.uninstall-lock"
LIVE_LOCK_PATH="/tmp/${LIVE_LOCK_LABEL}.lock"
LIVE_LOCK_LOG="$SANDBOX/uninstall-lock.log"
mkdir -p "$UNINSTALL_SCRIPTS"
touch "$UNINSTALL_SCRIPTS/${LIVE_LOCK_LABEL}.sh"

# Spawn a long-lived sleep process; its PID is the "live owner" of the lock.
sleep 600 &
LIVE_PID=$!
printf '%s' "$LIVE_PID" > "$LIVE_LOCK_PATH"

LIVE_RC=0
HOME="$SANDBOX" "$REPO_ROOT/uninstall.sh" --label "$LIVE_LOCK_LABEL" --lang en >"$LIVE_LOCK_LOG" 2>&1 <<EOF || LIVE_RC=$?
$UNINSTALL_SCRIPTS
y
n
EOF
if [[ "$LIVE_RC" -eq 0 ]]; then
    ok "uninstall.sh (live-PID lock) exited cleanly"
else
    ng "uninstall.sh (live-PID lock) exited rc=$LIVE_RC; see $LIVE_LOCK_LOG"
fi
if [[ -e "$LIVE_LOCK_PATH" ]]; then
    ok "uninstall.sh kept lock held by live PID $LIVE_PID"
else
    ng "uninstall.sh REMOVED a lock held by live PID $LIVE_PID"
fi
if grep -F -- "held by live PID" "$LIVE_LOCK_LOG" >/dev/null; then
    ok "uninstall.sh emitted live-PID warning"
else
    ng "uninstall.sh did not emit live-PID warning; see $LIVE_LOCK_LOG"
fi

# Now kill the live owner and re-run; lock should be removed this time.
# Heredoc lines: scripts_dir, then 'y' to confirm removing the (now-stale) lock.
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
DEAD_RC=0
HOME="$SANDBOX" "$REPO_ROOT/uninstall.sh" --label "$LIVE_LOCK_LABEL" --lang en >>"$LIVE_LOCK_LOG" 2>&1 <<EOF || DEAD_RC=$?
$UNINSTALL_SCRIPTS
y
EOF
if [[ ! -e "$LIVE_LOCK_PATH" ]]; then
    ok "uninstall.sh removed stale lock once owner PID was gone (rc=$DEAD_RC)"
else
    ng "uninstall.sh left stale lock behind (rc=$DEAD_RC); see $LIVE_LOCK_LOG"
    rm -f "$LIVE_LOCK_PATH"   # don't leak between sandbox runs
fi

step "Summary"
echo "PASS: $PASS   FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Sync log tail:"
    tail -20 "$SANDBOX/Library/Logs/${LABEL_PREFIX}.log" 2>/dev/null || true
    exit 1
fi
exit 0
