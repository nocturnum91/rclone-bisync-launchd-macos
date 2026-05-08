# 예시: 외장 SSD 폴더 → Google Drive

이 문서는 일반적인 설정을 실제 값으로 보여주는 예시입니다.

같은 방식은 로컬 디렉토리(노트 폴더, 코드 작업 공간, 문서 아카이브 등)와 `rclone bisync`를 지원하는 클라우드 스토리지(Dropbox, OneDrive, S3 등)에 적용할 수 있습니다.

## 시나리오

- macOS 호스트 (Apple Silicon, Homebrew 경로는 `/opt/homebrew`)
- 로컬 폴더: `/Volumes/Storage/Documents` (외장 SSD)
- rclone remote: `gdrive`, Google Drive의 `Documents` 폴더를 가리키도록 설정됨
- 목표: 실시간 동기화(30초 debounce) + 10분 주기의 안전망 동기화

## 권장 방식: `install.sh`

```bash
git clone <this repo>
cd rclone-bisync-launchd-macos
./install.sh
```

프롬프트가 나오면 다음처럼 입력합니다.

- Local path: `/Volumes/Storage/Documents`
- Remote: `gdrive:Documents`
- Label prefix: `local.docs-sync` (또는 기본값 `local.rclone-bisync` 사용)
- Scripts dir: 기본값 `~/scripts` 사용
- Debounce: 기본값 `30` 사용
- Interval: 기본값 `600` 사용
- Max delete percentage: 기본값 `50` 사용
- Backup dirs: 덮어써지거나 삭제될 파일을 rclone이 별도로 보관하길 원할 때만 입력
- Resync direction: 어느 쪽이 기준인지에 따라 선택 (remote 기준이면 1, local 기준이면 2, 미리보기는 3, 건너뛰기는 4)

`install.sh`는 아래 예외 상황을 처리합니다. 아래의 수동 예시는 이 부분을 직접 처리하지 않습니다.

- 경로/label의 context-safe escaping (shell 컨텍스트와 XML 컨텍스트 분리)
- 입력 검증 (label 형식, 숫자 범위, 절대 경로)
- rclone 버전 확인 (>= 1.71)
- `--check-access`용 `RCLONE_TEST` 센티널 생성
- resync 중 Ctrl-C 처리
- 렌더링되지 않은 `{{...}}` placeholder 탐지

## 수동 참고용 예시 (escaping 처리를 생략한 설명용)

템플릿을 직접 렌더링하고 싶거나 `install.sh`가 내부적으로 무엇을 하는지 보고 싶다면 아래 흐름을 참고하세요. **경로에 공백, 따옴표, 특수문자가 들어갈 수 있다면 `install.sh`를 사용하세요.** 이 수동 예시는 단순한 영숫자 경로를 가정합니다.

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

# Shell quote helper (single-quoted form, escapes inner ')
sq() { local s="${1//\'/\'\\\'\'}"; printf "'%s'" "$s"; }

# shell template 렌더링 (sync.sh.tmpl, watch.sh.tmpl)
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

# plist 렌더링 (XML. 단순화를 위해 경로/label에 특수문자가 없다고 가정)
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

## 최초 baseline 생성

`bisync`는 초기 baseline이 필요합니다. 또한 `--check-access`에 쓰는 `RCLONE_TEST` 센티널이 양쪽에 있어야 합니다.

```bash
# 1) 로컬에 센티널을 만들고 remote로 복사
touch "$LOCAL_PATH/RCLONE_TEST"
rclone copyto "$LOCAL_PATH/RCLONE_TEST" "$REMOTE/RCLONE_TEST"

# 2) baseline resync 실행 (최초 1회, 또는 fresh install / cache 손실 후 필요)
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

`--resync`는 baseline을 재구축합니다. 기본적으로 충돌 파일은 **Path1(remote) 우선**입니다. local을 우선하려면 `--resync-mode path2`를 추가하세요.

## 활성화

```bash
DOMAIN="gui/$(id -u)"
# 이전 설치가 아직 로드되어 있을 수 있으므로 방어적으로 bootout
launchctl bootout "$DOMAIN/${LABEL_PREFIX}"        2>/dev/null || true
launchctl bootout "$DOMAIN/${LABEL_PREFIX}-watch"  2>/dev/null || true
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/${LABEL_PREFIX}.plist
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/${LABEL_PREFIX}-watch.plist
```

## 확인

```bash
DOMAIN="gui/$(id -u)"
launchctl print "$DOMAIN/${LABEL_PREFIX}"
launchctl print "$DOMAIN/${LABEL_PREFIX}-watch"

# fswatch 프로세스가 실행 중이어야 함
ps aux | grep fswatch | grep -v grep

# 로컬 디렉토리의 파일을 하나 수정해서 트리거한 뒤 로그 확인
echo "test" >> "$LOCAL_PATH/test.md"
sleep 60
tail -10 ~/Library/Logs/${LABEL_PREFIX}.log
```
