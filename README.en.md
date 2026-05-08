# rclone-bisync-launchd-macos

[![macOS](https://img.shields.io/badge/macOS-launchd-black?logo=apple)](#compatibility)
[![rclone](https://img.shields.io/badge/rclone-bisync-blue)](https://rclone.org/bisync/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[English](README.en.md) · [한국어](README.md)

> Safe, launchd-native, real-time **rclone bisync** for macOS.
>
> Built for external-drive folders, notes vaults, workspaces, and archives that need bidirectional cloud sync without trusting a desktop sync app.

`rclone-bisync-launchd-macos` wires together `rclone bisync`, `fswatch`, `launchd`, and `shlock` into a guarded macOS sync setup. It was originally built for Google Drive folders living on an external SSD, but should work with any cloud storage backend compatible with `rclone bisync`.

## What you get

| Capability | What it does |
|---|---|
| Real-time sync | `fswatch` watches the local directory and triggers sync after a debounce window. |
| Safety-net schedule | A separate LaunchAgent runs periodically in case filesystem events are missed. |
| Overlap protection | `shlock` prevents the watcher and scheduler from corrupting bisync state by running together. |
| Mount-point protection | `--check-access` + `RCLONE_TEST` sentinel prevents syncing the wrong empty directory when an external drive is unmounted. |
| Safer recovery | `--resilient --recover`, `--max-lock`, `--max-delete`, conflict handling, and optional backup dirs are wired in. |
| Operational tools | Includes installer, uninstaller, doctor, dry-run rendering, and an isolated sandbox integration test. |

## Quick start

```bash
brew install rclone fswatch
rclone config

git clone https://github.com/nocturnum91/rclone-bisync-launchd-macos.git
cd rclone-bisync-launchd-macos

# Optional but recommended: validates templates in /tmp only
./examples/sandbox-test.sh

# Interactive installer
./install.sh
```

Preview without changing your system:

```bash
./install.sh --dry-run
```

Check an existing install:

```bash
./doctor.sh
./doctor.sh --label local.rclone-bisync --scripts-dir ~/scripts \
  --local-path /Volumes/Storage/Documents --remote gdrive:Documents --check-sync
```

Remove an install:

```bash
./uninstall.sh
```

## Why not just cron?

A naive `rclone bisync` cron job works until real-world edge cases show up:

| Failure mode | What can happen | Defense here |
|---|---|---|
| Cloud API throttling mid-sync | `.lst` baseline corruption and repeated aborts | `--resilient --recover`, filtered noisy paths |
| Two syncs overlap | Competing runs mutate the same bisync state | `shlock` + rclone `--max-lock 2m` |
| User waits for the next interval | Slow sync feedback | `fswatch` real-time trigger |
| Same file edited on two machines | Conflict abort | `--conflict-resolve newer` |
| External disk is unmounted | Empty/stale mount point sync risk | local dir check + `RCLONE_TEST` sentinel |

## Architecture

```text
              file change events
[local dir] ───────────────────→ [fswatch LaunchAgent]
                                      │ debounce
                                      ▼
                              [sync wrapper]
                                      │ shlock
                                      ▼
                              rclone bisync
                                      ▲
                                      │ safety-net interval
                         [scheduled LaunchAgent]
```

Two LaunchAgents are installed:

- **Watch agent** (`<LABEL_PREFIX>-watch`): long-lived `fswatch` process, kept alive by launchd.
- **Schedule agent** (`<LABEL_PREFIX>`): periodic safety-net sync via `StartInterval`.

Only one sync can run at a time. If the watcher and schedule fire together, the later one sees the lock and exits cleanly.

## Contents

- [Compatibility](#compatibility)
- [Prerequisites](#prerequisites)
- [Install flow](#install-flow)
- [Pre-flight and health checks](#pre-flight-and-health-checks)
- [Removing the install](#removing-the-install)
- [Manual installation](#manual-installation)
- [Files](#files)
- [Placeholders](#placeholders)
- [Tuning](#tuning)
- [Operating](#operating)
- [Troubleshooting](#troubleshooting)
- [Lessons learned](#lessons-learned-the-journey)

## Compatibility

- **OS**: macOS only (`launchd`, `fswatch`, `/usr/bin/shlock`)
- **Primary tested backend**: Google Drive
- **Expected cloud storage**: cloud storage backends compatible with `rclone bisync`. Examples: OneDrive, Box, B2, pCloud, S3/WebDAV-compatible storage, etc.

Check rclone's authoritative [bisync supported backends and limitations](https://rclone.org/bisync/#supported-backends) before relying on a storage backend for continuous sync. This project automates macOS operation; storage-specific behavior still comes from rclone.

Notes:

- Large high-churn directories can still hit API limits. The default filter excludes common noisy paths such as `node_modules/` and `.git/`.
- iCloud via rclone's `iclouddrive` backend requires Apple ID + 2FA and may need periodic reauthentication. Test it with a small folder first. iCloud Photos is read-only and is not suitable for bisync.

## Prerequisites

- **rclone v1.71+**: required for `--recover`, `--max-lock`, and `--conflict-resolve`.
- **fswatch**: real-time filesystem events.
- **shlock**: included with macOS at `/usr/bin/shlock`.

```bash
brew install rclone fswatch
rclone config
rclone lsd <remote>:
```

## Install flow

`install.sh` will:

1. Verify macOS and dependency versions.
2. Confirm at least one rclone remote exists.
3. Prompt for local path, remote, label, intervals, delete limit, and optional backup dirs.
4. Render shell scripts and plist files with context-safe escaping.
5. Validate generated files with `zsh -n`, `plutil -lint`, and placeholder scans.
6. Create `RCLONE_TEST` sentinel files for `--check-access`.
7. Run, preview, or skip the initial `--resync` baseline.
8. Load the watch and scheduled LaunchAgents.
9. Verify launchd state and the fswatch process.

`install.sh` and `uninstall.sh` are localized. They auto-detect language from `$LANG` (`ko_*` → Korean, otherwise English), or accept `--lang en|ko`.

## Pre-flight and health checks

Run the sandbox test before touching real data:

```bash
./examples/sandbox-test.sh
```

It uses rclone's `:local:` backend under `/tmp/rblm-sandbox/`, isolates rclone config/cache, and does not install LaunchAgents.

Run doctor checks:

```bash
./doctor.sh
./doctor.sh --label local.rclone-bisync --scripts-dir ~/scripts \
  --local-path /Volumes/Storage/Documents --remote gdrive:Documents
./doctor.sh --label local.rclone-bisync --scripts-dir ~/scripts \
  --local-path /Volumes/Storage/Documents --remote gdrive:Documents --check-sync
./doctor.sh --label local.rclone-bisync --log-warn-mb 50
```

`--check-sync` runs `rclone bisync --check-sync=only`, comparing bisync's last Path1/Path2 listing snapshots without applying sync changes. It is a baseline integrity check, not a live file-by-file remote comparison.

`doctor.sh` warns when matching log files exceed 20 MiB by default. It never truncates or deletes logs.

**Exit codes**:

| Code | Meaning |
|---|---|
| `0` | All checks passed; no warnings or errors |
| `1` | Warnings only |
| `2` | Bad CLI argument |
| `3` | One or more errors |

## Removing the install

```bash
./uninstall.sh                              # default label prefix: local.rclone-bisync
./uninstall.sh --label com.your.label       # specific install
```

The uninstaller prints exact files before removing them. It preserves the global rclone bisync cache because it may contain baselines for unrelated jobs.

## Manual installation

If you prefer not to run a script, see [examples/example-setup.en.md](examples/example-setup.en.md) for the equivalent sed-based recipe with concrete values. The scripted installer is safer for paths with spaces, quotes, or other special characters.

## Files

```
install.sh                    # interactive installer (primary entry point)
doctor.sh                     # non-destructive environment/install health check
uninstall.sh                  # interactive remover
templates/
├── scripts/
│   ├── sync.sh.tmpl          # rclone bisync wrapper with shlock
│   ├── watch.sh.tmpl         # fswatch loop calling sync.sh
│   └── filter.txt            # default rclone filter (no placeholders)
└── launchagents/
    ├── sync.plist.tmpl       # schedule LaunchAgent
    └── watch.plist.tmpl      # watch LaunchAgent
examples/
├── example-setup.md          # Korean manual sed-based setup walkthrough
├── example-setup.en.md       # English manual sed-based setup walkthrough
└── sandbox-test.sh           # automated end-to-end test in /tmp
i18n/
├── en.sh                     # English messages for install.sh / uninstall.sh
└── ko.sh                     # Korean messages
```

## Placeholders

`install.sh` provides defaults for everything that can be auto-detected or has a sensible convention. Only the local path and rclone remote truly require user input.

| Variable | Meaning | Default in `install.sh` |
|---|---|---|
| Local path | Local directory absolute path | Required. Example: `/Volumes/Storage/Documents` |
| Remote | rclone remote spec | Required. Example: `mydrive:Documents` |
| Path1 backup dir | `--backup-dir1` for overwritten/deleted files from Path1 (remote). Must be a non-overlapping path on the same remote. Example: `mydrive:Documents-backup` | Optional. Blank disables it |
| Path2 backup dir | `--backup-dir2` for overwritten/deleted files from Path2 (local). Must be an absolute local path. Example: `/Volumes/Storage/Documents-backup` | Optional. Blank disables it |
| Label prefix | LaunchAgent label & file prefix (must match `^[A-Za-z0-9._-]+$`). Examples: `local.rclone-bisync`, `local.docs-sync`, `local.obsidian-sync` | `local.rclone-bisync` |
| Home | Absolute home directory | `$HOME` (auto) |
| Scripts dir | Where rendered scripts live (absolute path; `~` is expanded) | `$HOME/scripts` |
| rclone binary | rclone binary absolute path | `$(command -v rclone)` (auto) |
| fswatch binary | fswatch binary absolute path | `$(command -v fswatch)` (auto) |
| Interval | Schedule agent interval in seconds (≥ 60) | `600` (10 min) |
| Debounce | fswatch latency / debounce in seconds (≥ 1) | `30` |
| Max delete percentage | Abort if either side would delete more than this percentage of files | `50` |

Inside the templates each variable appears as **two** placeholders for context-safe escaping:

- `{{<NAME>_SH}}`: used in shell scripts (`sync.sh.tmpl`, `watch.sh.tmpl`); rendered as a single-quoted shell literal.
- `{{<NAME>_XML}}`: used in plist files; rendered with XML entity-escaping.

For example, `{{LOCAL_PATH_SH}}` and `{{LOCAL_PATH_XML}}` map to the same input value but are escaped differently. `install.sh` handles this automatically; you only see it if you edit templates directly.

## Tuning

- **`{{DEBOUNCE_SEC}}` (default 30)**: Total delay from edit to cloud upload is roughly debounce + sync time. Use 10s for near-real-time behavior, or 60s to reduce redundant runs. Your editor's save pattern matters (some autosave on idle, IDEs typically save on focus loss).
- **`{{INTERVAL_SEC}}` (default 600)**: Safety-net frequency. It does not need to be aggressive since fswatch handles real-time triggers. 600–1800 is a reasonable range.
- **Max delete percentage (default 50)**: Explicit rclone `--max-delete` safety limit. If more than this percentage of files would be deleted on either side, bisync aborts without applying changes. Use a lower value for conservative setups; use `--force` only for a deliberate one-time recovery after reviewing a dry run.
- **Backup dirs (default blank)**: Optional rclone `--backup-dir1` / `--backup-dir2` destinations for files that would be overwritten or deleted. Path1 is the remote side, so use a non-overlapping path on the same remote, for example `mydrive:Documents-backup`. Path2 is the local side, so use an absolute local path, for example `/Volumes/Storage/Documents-backup`.
- **Filter rules (`filter.txt`)**: Add anything that changes frequently but you don't want synced. Common: `node_modules/`, `.git/`, build outputs, IDE caches. **After changing `filter.txt`, run `rclone bisync ... --resync` once** to rebuild the baseline; otherwise bisync may flag previously-synced (and now filtered) files as deletions.

### Application-specific exclude patterns

Some apps write to internal state files on every click, which would cause fswatch to fire constantly. If you use any of these inside your synced directory, add the corresponding `--exclude` lines to `<LABEL_PREFIX>-watch.sh`:

```bash
# Obsidian (workspace state changes on every focus shift)
--exclude '\.obsidian/workspace\.json$'
--exclude '\.obsidian/workspace-mobile\.json$'
--exclude '\.obsidian/cache'

# JetBrains IDEs (IntelliJ, PyCharm, etc.)
--exclude '\.idea/workspace\.xml$'
--exclude '\.idea/usage\.statistics\.xml$'

# VS Code workspace state
--exclude '\.vscode/\.history'
```

The `filter.txt` file controls what `rclone bisync` syncs (content); the `--exclude` flags inside `<LABEL_PREFIX>-watch.sh` control what wakes up `fswatch` (triggers). They're separate.

## Operating

```bash
DOMAIN="gui/$(id -u)"

# Status (launchctl print accepts the same domain-aware target as bootstrap/bootout)
launchctl print "$DOMAIN/<LABEL_PREFIX>"
launchctl print "$DOMAIN/<LABEL_PREFIX>-watch"
ps aux | grep fswatch | grep -v grep

# Manual sync trigger
launchctl kickstart "$DOMAIN/<LABEL_PREFIX>"

# Live log
tail -f ~/Library/Logs/<LABEL_PREFIX>.log

# Reload after editing plist
launchctl bootout "$DOMAIN/<LABEL_PREFIX>"          2>/dev/null || true
launchctl bootout "$DOMAIN/<LABEL_PREFIX>-watch"    2>/dev/null || true
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/<LABEL_PREFIX>.plist
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/<LABEL_PREFIX>-watch.plist
```

## Troubleshooting

### `Access test failed` / `Bisync aborted: check file check failed`

`--check-access` is enforced by default. Both Path1 and Path2 must contain a `RCLONE_TEST` file (created by `install.sh`). If you see this error:

1. Verify the local directory is actually mounted (external drive plugged in, network volume reachable).
2. If mounted but the sentinel was deleted, recreate it: `touch <local-path>/RCLONE_TEST && rclone copyto <local-path>/RCLONE_TEST <remote>:<path>/RCLONE_TEST` then run a normal sync.
3. If you intentionally don't want sentinel-based mount checking, remove `--check-access` from `<scripts-dir>/<label-prefix>.sh`.

### `Bisync critical error: cannot find prior listings`

Baseline `.lst` files in `~/Library/Caches/rclone/bisync/` are missing or corrupted. Even with `--resilient --recover`, severe cases (e.g., deleted listings) need a manual one-time resync:

```bash
rclone bisync <REMOTE> <LOCAL_PATH> \
    --filter-from <SCRIPTS_DIR>/<LABEL_PREFIX>-filter.txt \
    --check-access \
    --resilient --recover --max-lock 2m \
    --max-delete 50 \
    --conflict-resolve newer \
    --resync \
    --log-file ~/Library/Logs/<LABEL_PREFIX>.log --log-level INFO
```

If backup dirs were configured, include `--backup-dir1 <REMOTE_BACKUP_DIR>` and/or `--backup-dir2 <LOCAL_BACKUP_DIR>` in the command above.

`--resync` rebuilds the baseline. **Path1 (remote) wins** for any file that exists on both sides — back up locally before running if you're unsure which side is authoritative. For first-time setup, preview the changes before applying them:

```bash
rclone bisync <REMOTE> <LOCAL_PATH> \
    --filter-from <SCRIPTS_DIR>/<LABEL_PREFIX>-filter.txt \
    --check-access \
    --resilient --recover --max-lock 2m \
    --max-delete 50 \
    --conflict-resolve newer \
    --resync --dry-run --verbose
```

### `Failed to bisync: too many deletes`

The configured safety guard defaults to `--max-delete 50` and fires if more than 50% of files would be deleted on either side. If you want stricter behavior, reinstall with a lower max delete percentage. If the deletion is intentional (e.g., you cleaned up the remote on another machine), first run with `--dry-run`; then add `--force` for one run and remove it afterward.

### Cloud API rate limit / quota

Add the offending paths to `filter.txt`. Most common culprit: `node_modules/` (tens of thousands of files).

### Watch agent restarting in a loop

Check `~/Library/Logs/<LABEL_PREFIX>-watch-error.log`. Common causes: local path doesn't exist (e.g. external drive unmounted), fswatch binary moved (Homebrew upgrade may break absolute paths in scripts).

## Lessons learned (the journey)

This setup reflects specific design decisions from real debugging. If you wonder *why* a particular flag is there, here's the short version:

- **`--resilient --recover`**: bisync would otherwise require manual `--resync` after any single transient error (DNS hiccup, brief API throttle). This was the single biggest stability improvement.
- **`--conflict-resolve newer`**: without it, any concurrent edit on two machines causes abort. Most users want "last write wins."
- **fswatch + LaunchAgent (not cron)**: cron has 1-minute floor and no FSEvents access. launchd's `StartInterval` works, but pairing with a separate watch agent gives both real-time and safety net.
- **shlock**: `/usr/bin/shlock` ships with macOS, validates PID, and self-heals stale locks. Lighter than `flock` (which isn't built-in on macOS).
- **`--filter-from` excluding `node_modules/`**: discovered the hard way after Google Drive started returning HTTP 403 quota-exceeded errors mid-sync. Listing 10k files per scan was burning the per-minute query quota.
- **`--max-lock 2m`**: rclone's own intra-process lock for additional safety against overlapping invocations from different sources.
- **`--check-access` + `RCLONE_TEST` sentinel**: protects against syncing the wrong location when the external drive is unmounted but a directory of the same path still exists (e.g., a stale mount point). Without this, bisync would happily mirror an empty directory back to the remote, causing massive data loss.

## Caveats

- **shlock + PID reuse**: `shlock` records the current PID in `/tmp/<label>.lock` and treats the lock as stale only if that PID no longer exists. On rare occasions, an unrelated process may inherit the same PID, making the lock appear valid. If you see sync runs being skipped indefinitely while no real lock-holder is running, delete `/tmp/<label>.lock` manually.
- **Sentinel removal blocks sync**: If `RCLONE_TEST` is deleted on either side (manually or by mistake), `--check-access` aborts every run. See Troubleshooting above to recreate.

## License

[MIT](LICENSE)

## Contributing

Issues and PRs welcome. Particularly interested in:
- Cross-backend test reports (especially Dropbox, OneDrive, S3)
- Linux port (systemd unit files instead of launchd)
- Additional `i18n/<lang>.sh` translations
