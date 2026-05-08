# rclone-bisync-launchd-macos

[![macOS](https://img.shields.io/badge/macOS-launchd-black?logo=apple)](#호환성)
[![rclone](https://img.shields.io/badge/rclone-bisync-blue)](https://rclone.org/bisync/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[한국어](README.md) · [English](README.en.md)

> macOS에서 **rclone bisync**를 launchd 방식으로 안전하게 운영하기 위한 도구입니다.
>
> 외장 디스크 폴더, 노트 vault, 작업 공간, 문서 아카이브를 클라우드와 양방향 동기화할 때 desktop sync app에 의존하지 않도록 만들었습니다.

`rclone-bisync-launchd-macos`는 `rclone bisync`, `fswatch`, `launchd`, `shlock`을 조합해 macOS용 안전한 양방향 동기화 구성을 만들어줍니다. 처음에는 외장 SSD에 있는 Google Drive 폴더를 위해 만들었지만, `rclone bisync`와 호환되는 클라우드 스토리지라면 함께 사용할 수 있습니다.

## 제공 기능

| 기능 | 설명 |
|---|---|
| 실시간 동기화 | `fswatch`가 로컬 디렉토리 변경을 감지하고 debounce 후 동기화를 실행합니다. |
| 주기적 안전망 | 별도 LaunchAgent가 주기적으로 실행되어 놓친 이벤트를 보완합니다. |
| 중복 실행 방지 | `shlock`으로 watcher와 scheduler가 동시에 bisync state를 건드리지 못하게 합니다. |
| 마운트 보호 | `--check-access` + `RCLONE_TEST` 센티널로 외장 디스크 미마운트 시 빈 디렉토리를 잘못 동기화하는 사고를 막습니다. |
| 복구 친화적 설정 | `--resilient --recover`, `--max-lock`, `--max-delete`, 충돌 처리, 선택적 backup dir를 기본 흐름에 포함합니다. |
| 운영 도구 | installer, uninstaller, doctor, dry-run 렌더링, 격리된 sandbox integration test를 포함합니다. |

## 빠른 시작

```bash
brew install rclone fswatch
rclone config

git clone https://github.com/nocturnum91/rclone-bisync-launchd-macos.git
cd rclone-bisync-launchd-macos

# 선택 사항이지만 권장: /tmp 안에서만 템플릿 검증
./examples/sandbox-test.sh

# 인터랙티브 설치
./install.sh
```

시스템 변경 없이 미리보기:

```bash
./install.sh --dry-run
```

설치 상태 점검:

```bash
./doctor.sh
./doctor.sh --label local.rclone-bisync --scripts-dir ~/scripts \
  --local-path /Volumes/Storage/Documents --remote gdrive:Documents --check-sync
```

제거:

```bash
./uninstall.sh
```

## 왜 cron만으로는 부족한가

단순히 `rclone bisync`를 cron이나 launchd 스케줄에 걸어두면 실제 환경에서 여러 문제가 생깁니다.

| 실패 패턴 | 발생 가능한 문제 | 이 도구의 방어 |
|---|---|---|
| 클라우드 API throttle | `.lst` baseline 손상, 이후 반복 abort | `--resilient --recover`, 노이즈 경로 필터 |
| 두 sync가 겹침 | 같은 bisync state를 동시에 변경 | `shlock` + rclone `--max-lock 2m` |
| 다음 주기까지 대기 | 사용자가 변경 반영을 오래 기다림 | `fswatch` 실시간 트리거 |
| 두 머신에서 같은 파일 편집 | conflict abort | `--conflict-resolve newer` |
| 외장 디스크 미마운트 | 빈/stale mount point를 동기화할 위험 | 로컬 경로 확인 + `RCLONE_TEST` 센티널 |

## 아키텍처

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

두 개의 LaunchAgent가 설치됩니다.

- **Watch agent** (`<LABEL_PREFIX>-watch`): `fswatch` 장기 실행 프로세스입니다. launchd가 유지합니다.
- **Schedule agent** (`<LABEL_PREFIX>`): `StartInterval` 기반의 주기적 안전망 동기화입니다.

한 번에 하나의 sync만 실행됩니다. watcher와 schedule이 동시에 깨어나면 나중에 실행된 쪽은 lock을 보고 조용히 종료합니다.

## 목차

- [호환성](#호환성)
- [사전 요구사항](#사전-요구사항)
- [설치 흐름](#설치-흐름)
- [사전 점검과 상태 확인](#사전-점검과-상태-확인)
- [제거](#제거)
- [수동 설치](#수동-설치)
- [파일 구조](#파일-구조)
- [Placeholder 목록](#placeholder-목록)
- [튜닝](#튜닝)
- [운영](#운영)
- [트러블슈팅](#트러블슈팅)
- [디자인 결정의 배경](#디자인-결정의-배경-디버깅-여정)

## 호환성

- **OS**: macOS 전용 (`launchd`, `fswatch`, `/usr/bin/shlock` 사용)
- **주 검증 클라우드 스토리지**: Google Drive
- **동작 예상 클라우드 스토리지**: `rclone bisync` 호환 대상. 예: OneDrive, Box, B2, pCloud, S3/WebDAV 호환 스토리지 등

사용하기 전 rclone 공식 문서의 [bisync supported backends and limitations](https://rclone.org/bisync/#supported-backends)를 확인하세요. 이 프로젝트는 macOS 운영 자동화를 제공하며, 클라우드 스토리지별 동작 특성은 rclone의 지원 범위를 따릅니다.

참고:

- 파일 수가 많고 자주 바뀌는 디렉토리는 API limit을 유발할 수 있습니다. 기본 필터는 `node_modules/`, `.git/` 같은 노이즈 경로를 제외합니다.
- rclone의 `iclouddrive`로 iCloud를 쓰려면 Apple ID + 2FA 인증이 필요하고 주기적 재인증이 필요할 수 있습니다. 작은 폴더로 먼저 테스트하세요. iCloud Photos는 읽기 전용이라 bisync 대상에 적합하지 않습니다.

## 사전 요구사항

- **rclone v1.71+**: `--recover`, `--max-lock`, `--conflict-resolve` 사용에 필요합니다.
- **fswatch**: 실시간 파일 이벤트 감지용.
- **shlock**: macOS에 `/usr/bin/shlock`로 기본 포함됩니다.

```bash
brew install rclone fswatch
rclone config
rclone lsd <remote>:
```

## 설치 흐름

`install.sh`는 다음을 수행합니다.

1. macOS와 의존성 버전을 확인합니다.
2. rclone remote가 최소 하나 있는지 확인합니다.
3. 로컬 경로, remote, label, 실행 주기, 삭제 한도, 선택적 backup dir를 입력받습니다.
4. shell/plist 컨텍스트에 맞게 안전하게 escape하여 스크립트와 plist를 렌더링합니다.
5. `zsh -n`, `plutil -lint`, placeholder scan으로 생성 파일을 검증합니다.
6. `--check-access`용 `RCLONE_TEST` 센티널을 양쪽에 생성합니다.
7. 초기 `--resync` baseline을 실행, 미리보기, 또는 건너뜁니다.
8. watch/schedule LaunchAgent를 로드합니다.
9. launchd 상태와 fswatch 프로세스를 확인합니다.

`install.sh`와 `uninstall.sh`는 다국어를 지원합니다. `$LANG`에서 자동 감지(`ko_*`이면 한국어, 그 외 영어)하며 `--lang en|ko`로 강제할 수 있습니다.

## 사전 점검과 상태 확인

실제 데이터에 손대기 전에 sandbox test를 실행하세요.

```bash
./examples/sandbox-test.sh
```

이 테스트는 `/tmp/rblm-sandbox/` 아래에서 rclone `:local:` 로컬 스토리지를 사용하고, rclone config/cache를 격리하며, LaunchAgent를 설치하지 않습니다.

상태 점검:

```bash
./doctor.sh
./doctor.sh --label local.rclone-bisync --scripts-dir ~/scripts \
  --local-path /Volumes/Storage/Documents --remote gdrive:Documents
./doctor.sh --label local.rclone-bisync --scripts-dir ~/scripts \
  --local-path /Volumes/Storage/Documents --remote gdrive:Documents --check-sync
./doctor.sh --label local.rclone-bisync --log-warn-mb 50
```

`--check-sync`는 `rclone bisync --check-sync=only`를 실행해 마지막 Path1/Path2 listing snapshot을 비교합니다. 실제 변경은 적용하지 않습니다. 현재 remote 파일을 실시간으로 1:1 비교하는 검사는 아닙니다.

`doctor.sh`는 관련 로그 파일이 기본 20 MiB를 넘으면 경고합니다. 로그를 자동으로 비우거나 삭제하지 않습니다.

**종료 코드**:

| 코드 | 의미 |
|---|---|
| `0` | 모든 점검 통과, 경고/오류 없음 |
| `1` | 경고만 있음 |
| `2` | 잘못된 CLI 인자 |
| `3` | 하나 이상의 오류 |

## 제거

```bash
./uninstall.sh                              # 기본 label prefix: local.rclone-bisync
./uninstall.sh --label com.your.label       # 특정 설치 제거
```

제거 스크립트는 삭제 전 정확한 파일 목록을 보여줍니다. 글로벌 rclone bisync cache는 다른 작업의 baseline을 포함할 수 있어 자동 삭제하지 않습니다.

## 수동 설치

스크립트를 실행하고 싶지 않다면 [examples/example-setup.md](examples/example-setup.md)의 sed 기반 수동 설치 예시를 참고하세요. 경로에 공백, 따옴표, 특수문자가 있다면 자동 escape를 처리하는 `install.sh` 사용을 권장합니다.

## 파일 구조

```
install.sh                    # 인터랙티브 설치 (주 진입점)
doctor.sh                     # 환경/설치 상태를 확인하는 비파괴 점검 도구
uninstall.sh                  # 인터랙티브 제거
templates/
├── scripts/
│   ├── sync.sh.tmpl          # shlock 포함 rclone bisync 래퍼
│   ├── watch.sh.tmpl         # sync.sh를 호출하는 fswatch 루프
│   └── filter.txt            # 기본 rclone 필터 (placeholder 없음)
└── launchagents/
    ├── sync.plist.tmpl       # 스케줄 LaunchAgent
    └── watch.plist.tmpl      # 감시 LaunchAgent
examples/
├── example-setup.md          # 한국어 수동 sed 기반 설치 예시
├── example-setup.en.md       # 영어 수동 sed 기반 설치 예시
└── sandbox-test.sh           # /tmp에서 실행되는 자동 통합 테스트
i18n/
├── en.sh                     # install.sh / uninstall.sh 영어 메시지
└── ko.sh                     # 한국어 메시지
```

## Placeholder 목록

`install.sh`는 자동 감지 가능하거나 합리적 기본값이 있는 항목에 default를 제공합니다. 실제 필수 입력은 로컬 경로와 rclone remote 둘뿐입니다.

| 변수 | 의미 | install.sh의 default |
|---|---|---|
| 로컬 경로 | 로컬 디렉토리 절대 경로 | 필수. 예: `/Volumes/Storage/Documents` |
| Remote | rclone remote 지정값 | 필수. 예: `mydrive:Documents` |
| Path1 백업 경로 | Path1(remote)에서 덮어써지거나 삭제될 파일을 보관할 `--backup-dir1`. 같은 remote 안의 겹치지 않는 경로여야 합니다. 예: `mydrive:Documents-backup` | 선택 사항. 빈 값이면 비활성화 |
| Path2 백업 경로 | Path2(local)에서 덮어써지거나 삭제될 파일을 보관할 `--backup-dir2`. 로컬 절대 경로여야 합니다. 예: `/Volumes/Storage/Documents-backup` | 선택 사항. 빈 값이면 비활성화 |
| Label prefix | LaunchAgent label과 파일 prefix (`^[A-Za-z0-9._-]+$` 매칭 필요). 예: `local.rclone-bisync`, `local.docs-sync`, `local.obsidian-sync` | `local.rclone-bisync` |
| Home | 사용자 홈 절대 경로 | `$HOME` (자동) |
| Scripts dir | 렌더된 스크립트 위치 (절대 경로, `~`는 자동 확장) | `$HOME/scripts` |
| rclone binary | rclone 절대 경로 | `$(command -v rclone)` (자동) |
| fswatch binary | fswatch 절대 경로 | `$(command -v fswatch)` (자동) |
| Interval | 스케줄 LaunchAgent 주기(초, 60 이상) | `600` (10분) |
| Debounce | fswatch latency / debounce(초, 1 이상) | `30` |
| 최대 삭제 비율 | 양쪽 중 한쪽에서 이 비율을 초과하는 삭제가 감지되면 bisync 중단 | `50` |

템플릿 안에서는 각 변수가 컨텍스트별 안전한 escape를 위해 **두 가지** placeholder로 등장합니다:

- `{{<NAME>_SH}}`: 셸 스크립트(`sync.sh.tmpl`, `watch.sh.tmpl`)에서 사용합니다. 단일 따옴표 셸 리터럴로 렌더링합니다.
- `{{<NAME>_XML}}`: plist 파일에서 사용합니다. XML 엔티티 escape를 적용합니다.

예를 들어 `{{LOCAL_PATH_SH}}`와 `{{LOCAL_PATH_XML}}`은 같은 입력값을 가리키지만 escape 방식이 다릅니다. `install.sh`가 자동 처리하므로, 템플릿을 직접 편집하지 않는 한 의식할 필요는 없습니다.

## 튜닝

- **`{{DEBOUNCE_SEC}}` (default 30)**: 파일 편집부터 클라우드 업로드까지의 총 지연은 대략 `debounce + 동기화 시간`입니다. 거의 실시간이 필요하면 10초, 호출 빈도를 줄이고 싶으면 60초 정도가 적당합니다. 사용하는 에디터의 저장 패턴도 영향을 줍니다 (자동 저장은 idle 시, IDE는 보통 focus loss 시).
- **`{{INTERVAL_SEC}}` (default 600)**: 안전망 실행 빈도입니다. fswatch가 실시간 트리거를 담당하므로 너무 짧게 잡을 필요는 없습니다. 600~1800초가 합리적입니다.
- **최대 삭제 비율 (default 50)**: rclone `--max-delete` 안전장치를 명시합니다. 양쪽 중 한쪽에서 이 비율을 초과하는 파일 삭제가 감지되면 bisync는 변경을 적용하지 않고 중단합니다. 더 보수적으로 쓰려면 낮은 값을 사용하세요. `--force`는 dry-run으로 결과를 확인한 뒤 의도된 복구 작업에서 한 번만 쓰는 편이 안전합니다.
- **백업 경로 (default 빈 값)**: rclone의 `--backup-dir1` / `--backup-dir2` 옵션입니다. 덮어써지거나 삭제될 파일을 별도 위치에 보관하고 싶을 때만 설정하세요. Path1은 remote 쪽이므로 같은 remote 안의 겹치지 않는 경로를 사용합니다. 예: `mydrive:Documents-backup`. Path2는 local 쪽이므로 로컬 절대 경로를 사용합니다. 예: `/Volumes/Storage/Documents-backup`.
- **필터 규칙 (`filter.txt`)**: 자주 변경되지만 동기화하고 싶지 않은 경로를 추가하세요. 흔한 예: `node_modules/`, `.git/`, 빌드 산출물, IDE 캐시. **`filter.txt` 변경 후엔 `rclone bisync ... --resync`를 한 번 실행**해 baseline을 재구축해야 합니다. 그렇지 않으면 bisync가 이전에 동기화했던, 이제는 필터된 파일을 삭제로 인식할 수 있습니다.

### 애플리케이션별 exclude 패턴

일부 앱은 클릭할 때마다 내부 상태 파일을 갱신해 fswatch를 계속 깨웁니다. 동기화 디렉토리 안에서 이런 앱을 사용한다면 `<LABEL_PREFIX>-watch.sh`에 해당 `--exclude` 라인을 추가하세요:

```bash
# Obsidian (focus 변경마다 workspace 상태 갱신)
--exclude '\.obsidian/workspace\.json$'
--exclude '\.obsidian/workspace-mobile\.json$'
--exclude '\.obsidian/cache'

# JetBrains IDE (IntelliJ, PyCharm 등)
--exclude '\.idea/workspace\.xml$'
--exclude '\.idea/usage\.statistics\.xml$'

# VS Code workspace 상태
--exclude '\.vscode/\.history'
```

`filter.txt` 파일은 `rclone bisync`가 동기화하는 내용을 제어하고, `<LABEL_PREFIX>-watch.sh` 안의 `--exclude` flag는 `fswatch`를 깨우는 트리거를 제어합니다. 둘은 별개입니다.

## 운영

```bash
DOMAIN="gui/$(id -u)"

# 상태 확인 (launchctl print는 bootstrap/bootout과 동일한 도메인 대상 사용)
launchctl print "$DOMAIN/<LABEL_PREFIX>"
launchctl print "$DOMAIN/<LABEL_PREFIX>-watch"
ps aux | grep fswatch | grep -v grep

# 수동 동기화 실행
launchctl kickstart "$DOMAIN/<LABEL_PREFIX>"

# 실시간 로그
tail -f ~/Library/Logs/<LABEL_PREFIX>.log

# plist 수정 후 재로드
launchctl bootout "$DOMAIN/<LABEL_PREFIX>"          2>/dev/null || true
launchctl bootout "$DOMAIN/<LABEL_PREFIX>-watch"    2>/dev/null || true
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/<LABEL_PREFIX>.plist
launchctl bootstrap "$DOMAIN" ~/Library/LaunchAgents/<LABEL_PREFIX>-watch.plist
```

## 트러블슈팅

### `Access test failed` / `Bisync aborted: check file check failed`

`--check-access`는 기본으로 활성화되어 있습니다. Path1과 Path2 양쪽에 `RCLONE_TEST` 파일(`install.sh`가 생성)이 있어야 합니다. 이 에러가 나면:

1. 로컬 디렉토리가 실제로 마운트되었는지 확인 (외장 드라이브 연결 여부, 네트워크 볼륨 접근성)
2. 마운트되어 있는데 센티널이 삭제되었다면 재생성: `touch <local-path>/RCLONE_TEST && rclone copyto <local-path>/RCLONE_TEST <remote>:<path>/RCLONE_TEST` 후 일반 동기화 실행
3. 의도적으로 센티널 기반 마운트 검사를 원치 않으면 `<scripts-dir>/<label-prefix>.sh`에서 `--check-access`를 제거

### `Bisync critical error: cannot find prior listings`

`~/Library/Caches/rclone/bisync/`의 baseline `.lst` 파일이 누락되거나 손상된 상태입니다. `--resilient --recover`로도 안 풀리는 심각한 경우(예: listings 삭제됨)에는 수동 1회성 resync가 필요합니다:

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

백업 경로를 설정했다면 위 명령에 `--backup-dir1 <REMOTE_BACKUP_DIR>` 또는 `--backup-dir2 <LOCAL_BACKUP_DIR>`를 함께 넣으세요.

`--resync`가 baseline을 재구축합니다. 양쪽에 동일하게 존재하는 파일은 **Path1 (remote) 우선**입니다. 어느 쪽이 기준인지 확실하지 않다면 실행 전 로컬 백업을 권장합니다. 최초 설정이라면 실제 적용 전에 변경 사항을 미리 확인하세요:

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

기본값은 `--max-delete 50`이며, 양쪽 중 한쪽에서 50%를 초과하는 파일 삭제가 감지되면 안전 가드가 발동합니다. 더 엄격하게 막고 싶다면 재설치 시 더 낮은 최대 삭제 비율을 입력하세요. 의도된 삭제(예: 다른 머신에서 remote 정리)라면 먼저 `--dry-run`으로 결과를 확인하고, 한 번만 `--force`를 추가한 뒤 원래 명령으로 되돌리세요.

### 클라우드 API rate limit / quota

문제 경로를 `filter.txt`에 추가하세요. 가장 흔한 원인: `node_modules/` (수만 개 파일).

### Watch agent 재시작 루프

`~/Library/Logs/<LABEL_PREFIX>-watch-error.log`를 확인하세요. 흔한 원인: 로컬 경로가 존재하지 않음(외장 드라이브가 마운트되지 않음), fswatch 바이너리 위치 변경(Homebrew 업그레이드로 스크립트의 절대 경로가 깨졌을 수 있음).

## 디자인 결정의 배경 (디버깅 여정)

이 구성에는 디버깅 과정에서 얻은 구체적인 설계 결정이 반영되어 있습니다. 어떤 옵션이 *왜* 들어갔는지 궁금하다면:

- **`--resilient --recover`**: 없으면 일시적인 오류(DNS 문제, 짧은 API throttle)마다 수동 `--resync`가 필요합니다. 안정성 측면에서 가장 큰 개선이었습니다.
- **`--conflict-resolve newer`**: 없으면 두 머신에서 동시에 편집할 때 중단됩니다. 대부분의 사용자는 "최근 편집 우선"을 원합니다.
- **fswatch + LaunchAgent (cron 아님)**: cron은 최소 1분 단위이고 FSEvents에 접근할 수 없습니다. launchd의 `StartInterval`은 동작하지만, 별도 watch agent와 결합해야 실시간성 + 안전망을 모두 확보할 수 있습니다.
- **shlock**: `/usr/bin/shlock`은 macOS에 기본 제공되며, PID 검증과 stale lock 자가 복구를 지원합니다. macOS에 기본 포함되지 않는 `flock`보다 가볍습니다.
- **`--filter-from`으로 `node_modules/` 제외**: Google Drive가 동기화 도중 HTTP 403 quota-exceeded를 반환하기 시작한 후 어렵게 발견했습니다. 스캔당 10K 파일 listing이 분당 quota를 소진하고 있었습니다.
- **`--max-lock 2m`**: rclone 자체의 intra-process lock. 다른 소스에서의 중첩 invocation 방지 추가 안전망.
- **`--check-access` + `RCLONE_TEST` 센티널**: 외장 드라이브가 마운트되지 않았는데 동일 경로의 디렉토리가 남아있는 경우(예: stale mount point) 잘못된 위치를 동기화하지 않도록 막아줍니다. 이 장치가 없으면 bisync가 빈 디렉토리를 remote로 미러링해 대규모 데이터 손실을 일으킬 수 있습니다.

## 주의사항

- **shlock + PID 재사용**: `shlock`은 현재 PID를 `/tmp/<label>.lock`에 기록하고, 그 PID가 더 이상 존재하지 않을 때만 stale lock으로 처리합니다. 드물게 무관한 프로세스가 같은 PID를 받으면 lock이 유효한 것처럼 보일 수 있습니다. 실제 lock holder 없이 동기화가 계속 건너뛰어진다면 `/tmp/<label>.lock`을 수동으로 삭제하세요.
- **센티널 제거 = 동기화 중단**: `RCLONE_TEST`가 어느 쪽에서든 삭제되면(수동 또는 실수로) `--check-access`가 매 실행마다 중단됩니다. 위 트러블슈팅을 참고하세요.

## 라이선스

[MIT](LICENSE)

## 기여

이슈와 PR 환영합니다. 특히 다음 분야 관심:
- 클라우드 스토리지 호환 테스트 리포트 (특히 Dropbox, OneDrive, S3)
- Linux 포팅 (launchd 대신 systemd unit)
- `i18n/<lang>.sh` 추가 번역
