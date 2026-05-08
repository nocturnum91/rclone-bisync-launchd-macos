# Example: External-SSD folder → Google Drive

This example shows concrete values for a typical setup.

The same approach works for any local directory (notes folder, code workspace, document archive, etc.) and any rclone-supported backend (Dropbox, OneDrive, S3, etc.).

## Scenario

- macOS host (Apple Silicon, Homebrew at `/opt/homebrew`)
- Local folder at `/Volumes/Storage/Documents` (external SSD)
- rclone remote `gdrive` configured pointing to a Google Drive folder `Documents`
- Goal: real-time sync (30s debounce) plus a 10-minute safety net

## Recommended path: `install.sh`

```bash
git clone <this repo>
cd rclone-bisync-launchd-macos
./install.sh
```

When prompted:
- Local path: `/Volumes/Storage/Documents`
- Remote: `gdrive:Documents`
- Label prefix: `local.docs-sync` (or accept default `local.rclone-bisync`)
- Scripts dir: accept default `~/scripts`
- Debounce: accept default `30`
- Interval: accept default `600`
- Max delete percentage: accept default `50`
- Backup dirs: leave blank unless you want rclone to keep overwritten/deleted files
- Resync direction: choose based on which side is authoritative (option 1 if remote, option 2 if local, option 3 to preview, option 4 to skip)

`install.sh` handles edge cases the manual recipe below does not:
- Context-safe escaping of paths/labels (shell vs XML contexts)
- Input validation (label format, numeric ranges, absolute paths)
- rclone version check (>= 1.71)
- `RCLONE_TEST` sentinel creation for `--check-access`
- Graceful Ctrl-C handling during resync
- Unrendered `{{...}}` placeholder detection

## Manual reference (illustrative — does not handle escaping)

If you prefer to render the templates by hand (or want to understand what `install.sh` does), the rough sed-substitution flow is below. **Use `install.sh` for any input that may contain spaces or special characters** — the manual flow assumes simple alphanumeric paths.

```bash
LOCAL_PATH="/Volumes/Storage/Documents"
REMOTE="gdrive:Documents"
LABEL_PREFIX="local.docs-sync"
SCRIPTS_DIR="$HOME/scripts"
RCLONE_BIN="$(command -v rclone)"
FSWATCH_BIN="$(command -v fswatch)"
DEBOUNCE_SEC=30
INTERVAL_SEC=600
MAX_DELETE_PERCENT=50
BACKUP_FLAGS_SH=""

# Shell-quote helper (single-quoted form, escapes inner ')
sq() { local s="${1//\'/\'\\\'\'}"; printf "'%s'" "$s"; }

# Render shell templates (sync.sh.tmpl, watch.sh.tmpl)
mkdir -p "$SCRIPTS_DIR"
SYNC_SH="$SCRIPTS_DIR/${LABEL_PREFIX}.sh"
WATCH_SH="$SCRIPTS_DIR/${LABEL_PREFIX}-watch.sh"

sed \
    -e "s|{{LOCAL_PATH_SH}}|$(sq "$LOCAL_PATH")|g" \
    -e "s|{{REMOTE_SH}}|$(sq "$REMOTE")|g" \
    -e "s|{{LABEL_PREFIX_SH}}|$(sq "$LABEL_PREFIX")|g" \
    -e "s|{{RCLONE_BIN_SH}}|$(sq "$RCLONE_BIN")|g" \
    -e "s|{{FSWATCH_BIN_SH}}|$(sq "$FSWATCH_BIN")|g" \
    -e "s|{{SCRIPTS_DIR_SH}}|$(sq "$SCRIPTS_DIR")|g" \
    -e "s|{{HOME_SH}}|$(sq "$HOME")|g" \
    -e "s|{{MAX_DELETE_PERCENT_SH}}|$(sq "$MAX_DELETE_PERCENT")|g" \
    -e "s|{{BACKUP_FLAGS_SH}}|$BACKUP_FLAGS_SH|g" \
    -e "s|{{SYNC_SCRIPT_SH}}|$(sq "$SYNC_SH")|g" \
    -e "s|{{DEBOUNCE_SEC}}|$DEBOUNCE_SEC|g" \
    templates/scripts/sync.sh.tmpl > "$SYNC_SH"

sed \
    -e "s|{{LOCAL_PATH_SH}}|$(sq "$LOCAL_PATH")|g" \
    -e "s|{{LABEL_PREFIX_SH}}|$(sq "$LABEL_PREFIX")|g" \
    -e "s|{{FSWATCH_BIN_SH}}|$(sq "$FSWATCH_BIN")|g" \
    -e "s|{{SCRIPTS_DIR_SH}}|$(sq "$SCRIPTS_DIR")|g" \
    -e "s|{{HOME_SH}}|$(sq "$HOME")|g" \
    -e "s|{{SYNC_SCRIPT_SH}}|$(sq "$SYNC_SH")|g" \
    -e "s|{{DEBOUNCE_SEC}}|$DEBOUNCE_SEC|g" \
    templates/scripts/watch.sh.tmpl > "$WATCH_SH"

cp templates/scripts/filter.txt "$SCRIPTS_DIR/${LABEL_PREFIX}-filter.txt"
chmod +x "$SYNC_SH" "$WATCH_SH"

# Render plists (XML — assumes no special chars in paths/labels for simplicity)
SYNC_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}.plist"
WATCH_PLIST="$HOME/Library/LaunchAgents/${LABEL_PREFIX}-watch.plist"

sed \
    -e "s|{{LABEL_PREFIX_XML}}|$LABEL_PREFIX|g" \
    -e "s|{{SCRIPTS_DIR_XML}}|$SCRIPTS_DIR|g" \
    -e "s|{{HOME_XML}}|$HOME|g" \
    -e "s|{{INTERVAL_SEC}}|$INTERVAL_SEC|g" \
    templates/launchagents/sync.plist.tmpl > "$SYNC_PLIST"

sed \
    -e "s|{{LABEL_PREFIX_XML}}|$LABEL_PREFIX|g" \
    -e "s|{{LOCAL_PATH_XML}}|$LOCAL_PATH|g" \
    -e "s|{{SCRIPTS_DIR_XML}}|$SCRIPTS_DIR|g" \
    -e "s|{{HOME_XML}}|$HOME|g" \
    -e "s|{{INTERVAL_SEC}}|$INTERVAL_SEC|g" \
    templates/launchagents/watch.plist.tmpl > "$WATCH_PLIST"
```

## First-time bootstrap

`bisync` needs an initial baseline. Both sides must have the `RCLONE_TEST` sentinel (used by `--check-access`).

```bash
# 1) Create the sentinel locally and push to remote
touch "$LOCAL_PATH/RCLONE_TEST"
rclone copyto "$LOCAL_PATH/RCLONE_TEST" "$REMOTE/RCLONE_TEST"

# 2) Run the baseline resync (only needed once, or after fresh install / cache loss)
rclone bisync "$REMOTE" "$LOCAL_PATH" \
    --filter-from "$SCRIPTS_DIR/${LABEL_PREFIX}-filter.txt" \
    --check-access \
    --resilient --recover --max-lock 2m \
    --max-delete "$MAX_DELETE_PERCENT" \
    --conflict-resolve newer \
    --resync \
    --log-file "$HOME/Library/Logs/${LABEL_PREFIX}.log" \
    --log-level INFO
```

`--resync` rebuilds the baseline. **Path1 (remote) wins** for any conflicting file by default. To make local win, add `--resync-mode path2`.

## Activate

```bash
DOMAIN="gui/$(id -u)"
# Defensive bootout in case a prior install is still loaded.
launchctl bootout "$DOMAIN/${LABEL_PREFIX}"        2>/dev/null || true
launchctl bootout "$DOMAIN/${LABEL_PREFIX}-watch"  2>/dev/null || true
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/${LABEL_PREFIX}.plist
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/${LABEL_PREFIX}-watch.plist
```

## Verify

```bash
DOMAIN="gui/$(id -u)"
launchctl print "$DOMAIN/${LABEL_PREFIX}"
launchctl print "$DOMAIN/${LABEL_PREFIX}-watch"

# fswatch process should be running
ps aux | grep fswatch | grep -v grep

# Trigger by editing any file in the local dir, then check log
echo "test" >> "$LOCAL_PATH/test.md"
sleep 60
tail -10 ~/Library/Logs/${LABEL_PREFIX}.log
```
