#!/usr/bin/env bash
# MCS Log Analyzer — 진입점 스크립트
# 사용법: ./analyze.sh <path-to-tar.gz> [report-name]
#
# Claude Code harness engineering 예시:
#   - CLAUDE.md: 분석 지침 (Claude가 자동으로 읽음)
#   - --dangerously-skip-permissions: 자동화 실행 시 권한 승인 생략
#   - -p <prompt>: 비대화형 print 모드 (stdout에 결과 출력)

set -euo pipefail

# ── 모델 선택 및 인자 파싱 ─────────────────────────────────────────────────
# 기본값(prod): Haiku triage로 복잡도 판별 후 Sonnet(moderate/simple) 또는 Opus(complex) 자동 선택
# 개발 모드: Sonnet 강제 + triage 건너뜀 (Haiku 비용 + Opus 비용 모두 회피)
#   - `MCS_DEV=1` env var 설정 시 활성화 (개발 셸에서 export 해두면 편함)
#   - `--dev` flag 로 1회 한정 활성화
#   - `--prod` flag 로 dev 모드 무시 (env가 설정돼 있어도 prod 동작)
# 기타 플래그:
#   --model <id> : 모델 수동 지정 (triage 건너뜀, 최우선 순위)
#   --no-triage  : --dev 와 동일 (하위 호환)
MODEL=""
SKIP_TRIAGE=false
if [ "${MCS_DEV:-0}" = "1" ]; then
    SKIP_TRIAGE=true
fi
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --model|-m)         MODEL="$2"; shift 2 ;;
        --dev|--no-triage)  SKIP_TRIAGE=true; shift ;;
        --prod)             SKIP_TRIAGE=false; shift ;;
        *)                  POSITIONAL+=("$1"); shift ;;
    esac
done
(( ${#POSITIONAL[@]} > 0 )) && set -- "${POSITIONAL[@]}"

# ── 색상 출력 ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()  { echo -e "${GREEN}[*]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

# ── 인자 확인 ──────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "사용법: $0 <path-to-tar.gz> [report-name] [--dev|--prod|--model <id>|--no-triage]"
    echo ""
    echo "  기본(prod): Haiku triage → Sonnet/Opus 자동 선택"
    echo "  --dev    : Sonnet 강제, triage 건너뜀 (개발용 저렴 모드)"
    echo "  --prod   : prod 동작 강제 (MCS_DEV=1 env 무시)"
    echo "  --model X: 모델 수동 지정"
    echo ""
    echo "  환경변수 MCS_DEV=1 → --dev 와 동일 효과 (셸에 export 해두면 편함)"
    echo ""
    echo "  예시: $0 /path/to/report.tar.gz"
    echo "       $0 /path/to/report.tar.gz customer-abc-2026-04-07"
    echo "       MCS_DEV=1 $0 /path/to/report.tar.gz       # 개발 모드"
    echo "       $0 /path/to/report.tar.gz --model claude-opus-4-7"
    exit 1
fi

TARBALL="$(realpath "$1")"
if [ ! -f "$TARBALL" ]; then
    error "파일이 없습니다: $TARBALL"
    exit 1
fi

# ── 경로 설정 ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"
TIMESTAMP="$(date +%y%m%d%H%M%S)"
BASENAME="$(basename "$TARBALL" .tar.gz)"
REPORT_NAME="${2:-${TIMESTAMP}_${BASENAME}}"
REPORT_FILE="$REPORT_DIR/${REPORT_NAME}.md"

# 임시 디렉터리 (종료 시 자동 삭제)
WORKSPACE="$(mktemp -d -t mcs-log-XXXXXX)"
trap 'rm -rf "$WORKSPACE"' EXIT

# ── 압축 해제 ──────────────────────────────────────────────────────────────
info "압축 해제 중: $TARBALL"
tar -xzf "$TARBALL" -C "$WORKSPACE"

# 최상위 디렉터리 탐색 (아카이브 구조에 따라 다를 수 있음)
EXTRACTED_DIR="$(find "$WORKSPACE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
if [ -z "$EXTRACTED_DIR" ]; then
    # 최상위 디렉터리 없이 파일이 바로 압축된 경우
    EXTRACTED_DIR="$WORKSPACE"
fi

info "압축 해제 완료: $EXTRACTED_DIR"
info "보고서 저장 경로: $REPORT_FILE"

mkdir -p "$REPORT_DIR"

# ── 토큰 사용량 로깅 헬퍼 ──────────────────────────────────────────────────
TOKEN_LOG="$REPORT_DIR/_token-log.tsv"
log_tokens() {
    local phase="$1" model="$2" usage_json="$3"
    if [ -z "$usage_json" ] || [ "$usage_json" = "null" ] || [ "$usage_json" = "{}" ]; then
        return
    fi
    if [ ! -f "$TOKEN_LOG" ]; then
        printf 'timestamp\tarchive\tmodel\tphase\tinput\toutput\tcache_read\tcache_creation\n' \
            > "$TOKEN_LOG"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -Iseconds)" \
        "$BASENAME" \
        "$model" \
        "$phase" \
        "$(printf '%s' "$usage_json" | jq -r '.input_tokens // 0')" \
        "$(printf '%s' "$usage_json" | jq -r '.output_tokens // 0')" \
        "$(printf '%s' "$usage_json" | jq -r '.cache_read_input_tokens // 0')" \
        "$(printf '%s' "$usage_json" | jq -r '.cache_creation_input_tokens // 0')" \
        >> "$TOKEN_LOG"
}

# ── 로그 전처리 (토큰 절약) ─────────────────────────────────────────────
# Claude 호출 전에 bash로 대형 로그를 정제한다.
# 이 단계는 토큰을 소모하지 않는다.
PREPROCESS_DIR="$EXTRACTED_DIR/_preprocessed"
mkdir -p "$PREPROCESS_DIR"

info "로그 전처리 중..."

# --- journalctl.txt 전처리 (가장 큰 파일, 3단계로 분해) ---
JOURNALCTL="$EXTRACTED_DIR/system-logs/journalctl.txt"
if [ -f "$JOURNALCTL" ]; then
    JCTL_LINES=$(wc -l < "$JOURNALCTL")
    info "  journalctl.txt: ${JCTL_LINES} 줄 → 전처리 시작"

    # 1a) Tier 1: 하드 크리티컬 — 4가지 유형별로 dedup·크기 제한하여 결합
    #     문제: 단순 grep으로는 soft lockup·MCE·EDAC 반복 이벤트가 수만 줄 생성
    #     해결: 유형별로 분리하여 반복성 이벤트는 dedup+head, 단발성은 전체 보존
    {
        # (A) 단발성 크리티컬 — panic/OOM/segfault/I/O error (보통 수십 줄)
        grep -iE 'kernel panic|Oops:|oom-kill|Out of memory:|segfault|I/O error|blk_update_request' \
            "$JOURNALCTL" 2>/dev/null | head -100

        # (B) soft lockup — 처음 발생 1줄 + 마지막(최대 stuck) 1줄 + 총 횟수
        _LOCKUP=$(grep 'watchdog: BUG: soft lockup' "$JOURNALCTL" 2>/dev/null)
        if [ -n "$_LOCKUP" ]; then
            printf '# soft lockup 이벤트 (첫 발생 ~ 최대 stuck):\n'
            printf '%s\n' "$_LOCKUP" | head -1
            printf '%s\n' "$_LOCKUP" | tail -1
            printf '# (총 %d줄 반복)\n' "$(printf '%s\n' "$_LOCKUP" | wc -l)"
        fi

        # (C) MCE/EDAC/Hardware Error — dedup 후 빈도 상위 30줄
        printf '# MCE/EDAC/Hardware Error (dedup):\n'
        grep -iE 'EDAC|Machine Check|MCE|Hardware Error' "$JOURNALCTL" 2>/dev/null \
            | sed -E 's/^[A-Za-z]+ {1,2}[0-9]+ [0-9:]+ [^ ]+ //' \
            | sort | uniq -c | sort -rn | head -30

        # (D) Call Trace 스택 — Modules linked in 제거, 함수 경로만 (head -80)
        printf '# Call Trace / RIP (함수 경로):\n'
        grep -E 'Call Trace:|RIP: 0010:|^\s+\? |BUG: ' "$JOURNALCTL" 2>/dev/null \
            | grep -v 'Modules linked in\|soft lockup' | head -80
    } > "$PREPROCESS_DIR/journalctl-critical.txt" 2>/dev/null || true

    # 1b) Tier 2: 광범위 패턴 → 타임스탬프·호스트명 제거 후 중복 제거 → 빈도 상위 100행
    #     수십만 줄 → 100줄 빈도표로 압축. 형식: "  횟수 process: 메시지"
    #     (이전엔 200행이었으나 100행으로도 패턴 파악 충분, 토큰 절약)
    grep -iE 'fail|error|warning|killed|watchdog|critical|oom|panic|segfault' "$JOURNALCTL" \
        | sed -E 's/^[A-Za-z]+ {1,2}[0-9]+ [0-9:]+ [^ ]+ //' \
        | sort | uniq -c | sort -rn | head -100 \
        > "$PREPROCESS_DIR/journalctl-errors.txt" 2>/dev/null || true

    # 1c) 서비스 재시작 루프 감지 — restart counter가 높은 서비스 요약
    #     vscode-server 등 잘못 설치된 서비스가 수만 번 반복 재시작하는 케이스를 잡음
    {
        printf '# 서비스 재시작 루프 (restart counter 최고값 상위 10개)\n'
        grep 'restart counter is at' "$JOURNALCTL" 2>/dev/null \
            | grep -oE '[a-zA-Z0-9_@.\\-]+\.service.*restart counter is at [0-9]+' \
            | awk '{svc=$1; sub(/\.service.*/, "", svc); n=$NF; if (n > max[svc]) max[svc]=n} END {for (s in max) printf "%7d  %s\n", max[s], s}' \
            | sort -rn | head -10
        printf '\n# 서비스별 대표 에러 메시지 (dedup)\n'
        grep -E 'Failed to determine user credentials|start request repeated too quickly|Main process exited.*status=217' \
            "$JOURNALCTL" 2>/dev/null \
            | sed -E 's/^[A-Za-z]+ {1,2}[0-9]+ [0-9:]+ [^ ]+ //' \
            | sort | uniq -c | sort -rn | head -10
    } > "$PREPROCESS_DIR/journalctl-service-loops.txt" 2>/dev/null || true

    # 2) 구조적 이벤트: 키워드로 못 잡는 시스템 상태 변화
    grep -inE 'Reached target.*(Power-Off|Reboot|Shutdown|Multi-User)|logind.*(Power key|Lid|Suspend)|Started.*Shutdown|Stopping|Started.*Reboot|shutdown\[|reboot\[|Power-Off' \
        "$JOURNALCTL" | head -200 > "$PREPROCESS_DIR/journalctl-lifecycle.txt" 2>/dev/null || true

    # 3) 시간대별 로그 밀도 (분 단위, 상위 50개 — 비정상 폭주 구간 탐지)
    #    특정 분에 로그가 수천 줄 몰리면 그 시간대에 사건 발생
    awk '{ ts=substr($0,1,15); print ts }' "$JOURNALCTL" \
        | sort | uniq -c | sort -rn | head -50 \
        > "$PREPROCESS_DIR/journalctl-density.txt" 2>/dev/null || true

    # 4) 부팅 경계 추출: "-- Boot" 마커 + 직전 40줄 / 직후 10줄
    #    systemd 저널이 찍는 부팅 구분선. 재부팅 시점 목록 + 직전/직후 문맥 제공
    #    - Boot 마커 직전 = 이전 세션 마지막 이벤트 (종료 원인 단서) — 서비스 종료 시퀀스가 수십 줄이므로 넉넉히
    #    - Boot 마커 직후 = crash recovery, unexpected reboot 등 비정상 종료 증거
    grep -n '^\-\- Boot' "$JOURNALCTL" > "$PREPROCESS_DIR/journalctl-boots.txt" 2>/dev/null || true
    BOOT_COUNT=$(wc -l < "$PREPROCESS_DIR/journalctl-boots.txt" 2>/dev/null || echo 0)

    # Boot 경계 직전 40줄 / 직후 10줄 추출 (종료 원인 포착 우선)
    if [ "$BOOT_COUNT" -gt 0 ]; then
        grep -n -B40 -A10 '^\-\- Boot' "$JOURNALCTL" \
            | tail -500 \
            > "$PREPROCESS_DIR/journalctl-boot-context.txt" 2>/dev/null || true
    fi

    CRITICAL_LINES=$(wc -l < "$PREPROCESS_DIR/journalctl-critical.txt" 2>/dev/null || echo 0)
    FILTERED_LINES=$(wc -l < "$PREPROCESS_DIR/journalctl-errors.txt" 2>/dev/null || echo 0)
    LOOP_LINES=$(wc -l < "$PREPROCESS_DIR/journalctl-service-loops.txt" 2>/dev/null || echo 0)
    info "  journalctl.txt: ${JCTL_LINES} 줄, 부팅 ${BOOT_COUNT}회 → critical ${CRITICAL_LINES} 줄, errors-dedup ${FILTERED_LINES} 줄, service-loops ${LOOP_LINES} 줄"
fi

# --- syslog 전처리 ---
SYSLOG="$EXTRACTED_DIR/system-logs/syslog"
if [ -f "$SYSLOG" ]; then
    grep -inE 'error|fatal|fail|oom|panic|BUG:|Oops:|authentication failure|Failed password|disk I/O|read error|CRON.*ERROR' \
        "$SYSLOG" | head -500 > "$PREPROCESS_DIR/syslog-errors.txt" 2>/dev/null || true
    info "  syslog: $(wc -l < "$SYSLOG") 줄 → errors $(wc -l < "$PREPROCESS_DIR/syslog-errors.txt") 줄"
fi

# --- kern.log 전처리 ---
KERNLOG="$EXTRACTED_DIR/system-logs/kern.log"
if [ -f "$KERNLOG" ]; then
    grep -inE 'error|warning|fail|EXT4-fs error|XFS error|link is not ready|Link is Down|I/O error|oom|panic|MCE|EDAC' \
        "$KERNLOG" | head -300 > "$PREPROCESS_DIR/kern-errors.txt" 2>/dev/null || true
    info "  kern.log: $(wc -l < "$KERNLOG") 줄 → errors $(wc -l < "$PREPROCESS_DIR/kern-errors.txt") 줄"
fi

# --- dmesg-errors.txt 전처리 (보통 작지만 큰 경우 대비) ---
DMESG="$EXTRACTED_DIR/system-logs/dmesg-errors.txt"
if [ -f "$DMESG" ]; then
    DMESG_LINES=$(wc -l < "$DMESG")
    if [ "$DMESG_LINES" -gt 500 ]; then
        grep -inE 'panic|Oops|BUG:|Out of memory|oom|I/O error|blk_update_request|SCSI error|Hardware Error|EDAC|MCE|Machine Check|RAID|md:|mdadm|NFS|Lustre|filesystem error' \
            "$DMESG" > "$PREPROCESS_DIR/dmesg-critical.txt" 2>/dev/null || true
        info "  dmesg-errors.txt: ${DMESG_LINES} 줄 (대형) → critical $(wc -l < "$PREPROCESS_DIR/dmesg-critical.txt") 줄"
    else
        info "  dmesg-errors.txt: ${DMESG_LINES} 줄 (소형, 전처리 불필요)"
    fi
fi

# --- system-logs/dmesg 전처리 (원본 전체 dmesg — err 미만 레벨 + 스택 트레이스 포함) ---
# dmesg-errors.txt는 `dmesg -Tl err` 필터 결과라 스택 트레이스 줄이 잘린다.
# 원본 dmesg(/var/log/dmesg 복사본)는 모든 레벨을 포함하므로 여기서 보완한다.
DMESG_FULL="$EXTRACTED_DIR/system-logs/dmesg"
if [ -f "$DMESG_FULL" ]; then
    DMESG_FULL_LINES=$(wc -l < "$DMESG_FULL")
    # 크래시 패턴: BUG:/Oops/panic 전후 문맥 포함 (스택 트레이스 캡처)
    grep -nE 'panic|Oops|BUG:|Call Trace|RIP: ' \
        "$DMESG_FULL" | head -500 \
        > "$PREPROCESS_DIR/dmesg-crash-context.txt" 2>/dev/null || true
    CRASH_LINES=$(wc -l < "$PREPROCESS_DIR/dmesg-crash-context.txt" 2>/dev/null || echo 0)
    if [ "$CRASH_LINES" -gt 0 ]; then
        # 크래시가 있으면 전후 문맥(스택 트레이스)을 별도로 추출
        grep -nE 'panic|Oops|BUG:' -A30 -B2 \
            "$DMESG_FULL" >> "$PREPROCESS_DIR/dmesg-crash-context.txt" 2>/dev/null || true
    fi
    # 일반 에러 필터 (dmesg-errors.txt 보완 — err 미만 레벨 포함)
    # head -150은 보완 목적상 충분 (Critical 신호는 dmesg-errors.txt / dmesg-crash-context.txt에서 이미 캡처됨)
    grep -inE 'error|fail|warning|EDAC|MCE|Machine Check|I/O error|blk_update_request|SCSI|RAID|md:|NFS|Lustre|filesystem' \
        "$DMESG_FULL" | head -150 > "$PREPROCESS_DIR/dmesg-full-errors.txt" 2>/dev/null || true
    info "  dmesg (full): ${DMESG_FULL_LINES} 줄 → crash-context ${CRASH_LINES} 줄, errors $(wc -l < "$PREPROCESS_DIR/dmesg-full-errors.txt") 줄"
fi

# --- hw-list.txt → 하드웨어 요약 (_hw-summary.txt) ---
# Claude의 *-core/*-cpu/*-memory/*-bank Grep 4회를 Read 1회로 대체
HW_LIST="$EXTRACTED_DIR/hw-list.txt"
if [ -f "$HW_LIST" ]; then
    {
        echo "# hw-list 하드웨어 요약 (hw-list.txt에서 추출)"
        printf '\n## 메인보드 (*-core)\n'
        grep -m1 -A20 '^\s*\*-core' "$HW_LIST" \
            | grep -E '^\s+(description|product|vendor):' | head -5
        printf '\n## CPU (*-cpu)\n'
        grep -A50 '^\s*\*-cpu' "$HW_LIST" \
            | grep -E '^\s+(description|product|slot|capacity|width|clock):' | head -30
        printf '\n## 메모리 총량 (*-memory)\n'
        grep -m1 -A15 '^\s*\*-memory$' "$HW_LIST" \
            | grep -E '^\s+(description|size|capabilities):' | head -5
        printf '\n## 메모리 슬롯 (*-bank)\n'
        grep -A20 '^\s*\*-bank' "$HW_LIST" \
            | grep -E '(\*-bank|^\s+(slot|size|product|description|clock):)' | head -80
    } > "$PREPROCESS_DIR/_hw-summary.txt" 2>/dev/null || true
    info "  hw-list.txt → _hw-summary.txt ($(wc -l < "$PREPROCESS_DIR/_hw-summary.txt") 줄)"
fi

# --- nvidia-smi.txt → GPU 요약 (_nvidia-summary.txt) ---
NVIDIA_SMI="$EXTRACTED_DIR/nvidia-smi.txt"
if [ -f "$NVIDIA_SMI" ]; then
    {
        echo "# nvidia-smi GPU 요약"
        grep -E 'Driver Version|CUDA Version' "$NVIDIA_SMI" | head -3
        printf '\n'
        if grep -q '^\+' "$NVIDIA_SMI" 2>/dev/null; then
            # 기본 테이블 형식 (nvidia-smi)
            grep -E '^\+[-=]|^\| ' "$NVIDIA_SMI" | head -40
        else
            # 상세 형식 (nvidia-smi -q)
            grep -E 'GPU [0-9]+|Product Name|Bus-Id|ECC Mode|ECC Errors|Uncorrected|Corrected|Temperature|Fan Speed|Memory.*Used|Memory.*Free|Memory.*Total|Serial' \
                "$NVIDIA_SMI" | head -60
        fi
    } > "$PREPROCESS_DIR/_nvidia-summary.txt" 2>/dev/null || true
    info "  nvidia-smi.txt → _nvidia-summary.txt ($(wc -l < "$PREPROCESS_DIR/_nvidia-summary.txt") 줄)"
fi

# --- smartctl-*.txt → SMART 요약 (_smart-summary.txt) ---
# 드라이브당 100~200줄 원본 → 드라이브당 10~30줄 핵심 속성만 추출
SMART_SUMMARY="$PREPROCESS_DIR/_smart-summary.txt"
{
    echo "# SMART 요약 (smartctl-*.txt에서 추출)"
    for sfile in "$EXTRACTED_DIR/drives-and-storage/smartctl-"*.txt; do
        [ -f "$sfile" ] || continue
        dname=$(basename "$sfile" .txt | sed 's/^smartctl-//')
        printf '\n## 드라이브: %s\n' "$dname"
        # 공통: 장치 식별 + 건강 판정
        grep -E 'Device Model:|Model Number:|Serial Number:|Firmware Version:|SMART overall-health|SMART Status:|Terminate command early' \
            "$sfile" | head -6
        # SATA/SAS: 핵심 불량 속성만
        if grep -q 'SMART Attributes Data Structure' "$sfile" 2>/dev/null; then
            echo "[SATA]"
            grep -E 'Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Reallocated_Event_Count|Uncorrectable_Error_Cnt|Elements in grown defect' \
                "$sfile"
        fi
        # NVMe: Health Information 섹션 + 써멀 스로틀링
        if grep -q 'SMART/Health Information' "$sfile" 2>/dev/null; then
            echo "[NVMe]"
            awk '/SMART\/Health Information/,/^[[:space:]]*$/' "$sfile" | head -25
            grep -E 'Thermal Temp\. [12]|Warning.*Comp\. Temp|Critical.*Comp\. Temp' "$sfile"
        fi
    done
} > "$SMART_SUMMARY" 2>/dev/null || true
[ -s "$SMART_SUMMARY" ] && info "  smartctl-*.txt → _smart-summary.txt ($(wc -l < "$SMART_SUMMARY") 줄)"

# --- gpu-memory-errors/ → ECC 요약 (_ecc-summary.txt) ---
# 3개 파일을 1개로 통합하여 Read 3회 → 1회
ECC_SUMMARY="$PREPROCESS_DIR/_ecc-summary.txt"
{
    echo "# GPU ECC / 리매핑 요약"
    for eccfile in \
        "$EXTRACTED_DIR/gpu-memory-errors/uncorrected-ecc_errors.txt" \
        "$EXTRACTED_DIR/gpu-memory-errors/remapped-memory.txt" \
        "$EXTRACTED_DIR/gpu-memory-errors/ecc-errors.txt"; do
        [ -f "$eccfile" ] || continue
        printf '\n## %s\n' "$(basename "$eccfile")"
        head -20 "$eccfile"
    done
} > "$ECC_SUMMARY" 2>/dev/null || true
[ -s "$ECC_SUMMARY" ] && info "  gpu-memory-errors/ → _ecc-summary.txt ($(wc -l < "$ECC_SUMMARY") 줄)"

# --- systemctl-services.txt → 서비스 요약 (_systemctl-summary.txt) ---
SYSTEMCTL_FILE="$EXTRACTED_DIR/systemctl-services.txt"
if [ -f "$SYSTEMCTL_FILE" ]; then
    {
        echo "# systemctl 서비스 요약"
        printf '\n## Failed 서비스\n'
        grep -E 'failed' "$SYSTEMCTL_FILE" | head -30 || echo "(없음)"
        printf '\n## 서버 운영 관련 서비스 (masked/disabled 여부)\n'
        for svc in unattended-upgrades.service sleep.target suspend.target hibernate.target hybrid-sleep.target; do
            result=$(grep -m1 "$svc" "$SYSTEMCTL_FILE" 2>/dev/null || echo "$svc: (목록에 없음 — masked 가능)")
            echo "$result"
        done
    } > "$PREPROCESS_DIR/_systemctl-summary.txt" 2>/dev/null || true
    ORIG_LINES=$(wc -l < "$SYSTEMCTL_FILE")
    info "  systemctl-services.txt: ${ORIG_LINES} 줄 → _systemctl-summary.txt ($(wc -l < "$PREPROCESS_DIR/_systemctl-summary.txt") 줄)"
fi

info "로그 전처리 완료 → $PREPROCESS_DIR/"

# ── 모델 자동 선택 (Haiku triage) ──────────────────────────────────────────
if [ -n "$MODEL" ]; then
    info "모델 수동 지정: $MODEL"
elif [ "$SKIP_TRIAGE" = true ]; then
    MODEL="claude-sonnet-4-6"
    info "모델: $MODEL (triage 건너뜀)"
else
    info "모델 자동 선택 중 (Haiku triage)..."

    TRIAGE_PROMPT="[TRIAGE MODE — 복잡도 판별 전용. 보고서 작성·Write 도구 사용 금지.]

아래 파일들을 **단일 응답 블록 안에서 병렬로 Read** 하세요 (모든 Read 호출을 한 응답에 묶어 호출 — 순차 호출 금지). 의존성이 없으므로 한 번에 호출 가능합니다:
- ${PREPROCESS_DIR}/journalctl-critical.txt
- ${PREPROCESS_DIR}/journalctl-errors.txt
- ${PREPROCESS_DIR}/journalctl-service-loops.txt
- ${PREPROCESS_DIR}/_ecc-summary.txt
- ${PREPROCESS_DIR}/_smart-summary.txt
- ${PREPROCESS_DIR}/_systemctl-summary.txt
- ${PREPROCESS_DIR}/dmesg-crash-context.txt
- ${PREPROCESS_DIR}/dmesg-critical.txt

(없는 파일은 자동 건너뜁니다.)

복잡도 기준:
- complex: 서로 다른 소스에서 Critical 신호 ≥3, 또는 soft lockup·OOM·service-loop·ECC 중 ≥2 동시 존재
- moderate: Critical 신호 1~2개
- simple: Critical 신호 없음

**출력 규칙 (엄수)**: 분석 과정·해설·요약·중간 텍스트를 일체 출력하지 마세요. Read 완료 후 마지막 응답에 정확히 아래 두 줄만 포함하세요. 그 외 토큰은 비용 낭비입니다:
COMPLEXITY: simple|moderate|complex
CRITICAL_COUNT: N"

    # cwd를 압축 해제 디렉터리로 변경하여 프로젝트 CLAUDE.md 자동 로드 회피.
    # Haiku triage는 두 줄(COMPLEXITY/CRITICAL_COUNT)만 출력하므로 24KB 가이드가 불필요.
    # --output-format json: 응답 + usage를 한 JSON 객체로 받음
    TRIAGE_RAW=$(cd "$EXTRACTED_DIR" && claude --dangerously-skip-permissions -p "$TRIAGE_PROMPT" \
        --model "claude-haiku-4-5-20251001" --max-turns 15 \
        --output-format json 2>/dev/null) || TRIAGE_RAW=''

    if [ -n "$TRIAGE_RAW" ]; then
        TRIAGE_OUT=$(printf '%s' "$TRIAGE_RAW" | jq -r '.result // ""')
        TRIAGE_USAGE=$(printf '%s' "$TRIAGE_RAW" | jq -c '.usage // empty')
        log_tokens "triage" "claude-haiku-4-5-20251001" "$TRIAGE_USAGE"
    else
        TRIAGE_OUT="COMPLEXITY: moderate"
    fi

    COMPLEXITY=$(printf '%s' "$TRIAGE_OUT" | grep '^COMPLEXITY:' | awk '{print $2}' | tr -d '[:space:]')
    CRITICAL_N=$(printf '%s' "$TRIAGE_OUT" | grep '^CRITICAL_COUNT:' | awk '{print $2}' | tr -d '[:space:]')
    CRITICAL_N="${CRITICAL_N:-?}"

    case "$COMPLEXITY" in
        complex)  MODEL="claude-opus-4-7";   info "  triage → Opus (complex, Critical ${CRITICAL_N}개)" ;;
        moderate) MODEL="claude-sonnet-4-6"; info "  triage → Sonnet (moderate, Critical ${CRITICAL_N}개)" ;;
        simple)   MODEL="claude-sonnet-4-6"; info "  triage → Sonnet (simple)" ;;
        *)        MODEL="claude-sonnet-4-6"; warn "  triage 파싱 실패 → Sonnet (기본값 사용)" ;;
    esac
fi

# ── 파일 매니페스트 생성 ───────────────────────────────────────────────────
info "파일 매니페스트 생성 중..."
{
    echo "# 아카이브 파일 매니페스트"
    echo "# 생성 시각: $(date -Iseconds)"
    echo "# 형식: [크기(bytes)] [파일경로]"
    echo "---"
    find "$EXTRACTED_DIR" -type f -not -path "*/_preprocessed/*" -printf '%s %P\n' | sort -k2
} > "$EXTRACTED_DIR/_manifest.txt"

if [ -d "$PREPROCESS_DIR" ]; then
    echo "--- preprocessed ---" >> "$EXTRACTED_DIR/_manifest.txt"
    find "$PREPROCESS_DIR" -type f -printf '%s %P\n' | sort -k2 >> "$EXTRACTED_DIR/_manifest.txt"
fi

info "매니페스트 생성 완료: $(grep -c '' "$EXTRACTED_DIR/_manifest.txt") 항목"

# ── 환경 감지 ──────────────────────────────────────────────────────────────
info "환경 감지 중..."
ENV_HINTS="$EXTRACTED_DIR/_env-hints.txt"
{
    echo "# 환경 감지 결과"
    echo "# 생성 시각: $(date -Iseconds)"

    ENV_TYPE="베어메탈"

    # 커널 버전에서 WSL 감지
    for kfile in "$EXTRACTED_DIR/system-logs/dmesg-errors.txt" \
                 "$EXTRACTED_DIR/system-logs/kern.log" \
                 "$EXTRACTED_DIR/nvidia-bug-report.log"; do
        if [ -f "$kfile" ] && grep -qi 'microsoft-standard-WSL' "$kfile" 2>/dev/null; then
            ENV_TYPE="WSL2"
            break
        fi
    done

    # VM 감지 (WSL이 아닌 경우만)
    # ⚠ 주의: kvm_amd, kvm_intel 등 KVM 모듈 로딩 로그는 베어메탈 호스트에서도 나타남.
    #   "KVM"이라는 단어가 있다고 VM 게스트가 아님.
    #   반드시 **게스트 전용 지표**만 사용해야 한다.
    #
    # 잘못된 예: grep -qiE 'QEMU|KVM|Xen|VMware' → KVM 호스트를 VM으로 오판
    # 올바른 예: DMI product/manufacturer에서 가상 하드웨어 벤더 확인
    if [ "$ENV_TYPE" = "베어메탈" ]; then
        for vfile in "$EXTRACTED_DIR/system-logs/dmesg-errors.txt" \
                     "$EXTRACTED_DIR/system-logs/kern.log" \
                     "$EXTRACTED_DIR/hw-list.txt"; do
            if [ ! -f "$vfile" ]; then continue; fi

            # 1) DMI 기반 감지 — 가장 신뢰도 높음 (게스트에서만 나타나는 가상 하드웨어)
            if grep -qiE 'DMI:.*QEMU|DMI:.*VirtualBox|DMI:.*VMware.*Virtual|DMI:.*Microsoft.*Virtual|product.*QEMU|QEMU Standard PC' "$vfile" 2>/dev/null; then
                VM_VENDOR=$(grep -oiE 'QEMU|VMware|VirtualBox|Hyper-V' "$vfile" | head -1)
                ENV_TYPE="VM (${VM_VENDOR:-unknown})"
                break
            fi

            # 2) Xen HVM — Xen은 DMI에 안 나올 수 있으므로 별도 처리
            #    "Hypervisor detected" 단독은 nested virt 호스트에서도 출력되므로 Xen HVM으로 한정
            if grep -qiE 'Xen HVM' "$vfile" 2>/dev/null; then
                ENV_TYPE="VM (Xen)"
                break
            fi
        done
    fi

    echo "ENV_TYPE=${ENV_TYPE}"

    # 호스트명 추출
    HOSTNAME_FILE="$EXTRACTED_DIR/networking/etc-hostname.txt"
    if [ -f "$HOSTNAME_FILE" ]; then
        echo "HOSTNAME=$(cat "$HOSTNAME_FILE" | tr -d '[:space:]')"
    elif [ -f "$EXTRACTED_DIR/etc-config/networking/etc-hostname.txt" ]; then
        echo "HOSTNAME=$(cat "$EXTRACTED_DIR/etc-config/networking/etc-hostname.txt" | tr -d '[:space:]')"
    else
        echo "HOSTNAME=알 수 없음"
    fi

    # 커널 버전 추출
    if [ -f "$EXTRACTED_DIR/grub/proc_cmdline.txt" ]; then
        KVER=$(grep -oE 'BOOT_IMAGE=[^ ]+' "$EXTRACTED_DIR/grub/proc_cmdline.txt" | head -1)
        echo "KERNEL_BOOT=${KVER}"
    fi

} > "$ENV_HINTS"

info "환경 감지 완료: $(grep 'ENV_TYPE' "$ENV_HINTS")"

# ── Claude 프롬프트 구성 ───────────────────────────────────────────────────
# CLAUDE.md의 분석 지침을 참조하도록 안내
# Claude는 CLAUDE.md를 자동으로 읽으므로 간결하게 작성
ANALYSIS_START_TIME="$(date '+%Y-%m-%d %H:%M KST')"

# ── 케이스 DB staging (db/knowledge-base.md 존재 시에만 활성화) ──────────────
# 프로젝트 루트 = reports/ 의 부모. staging 파일은 보고서와 같은 basename의 .json.
PROJECT_ROOT="$(cd "$(dirname "$REPORT_DIR")" && pwd)"
DB_DIR="${PROJECT_ROOT}/db"
REPORT_BASENAME="$(basename "$REPORT_FILE" .md)"
STAGING_FILE="${DB_DIR}/_staging/${REPORT_BASENAME}.json"
STAGING_PROMPT_LINE=""
if [ -f "${DB_DIR}/knowledge-base.md" ]; then
    mkdir -p "${DB_DIR}/_staging"
    STAGING_PROMPT_LINE="케이스 스테이징 경로: ${STAGING_FILE}
"
fi

PROMPT="로그 분석 작업을 시작합니다.

압축 해제된 진단 아카이브 경로: ${EXTRACTED_DIR}
보고서 저장 경로: ${REPORT_FILE}
${STAGING_PROMPT_LINE}분석 시작 시각: ${ANALYSIS_START_TIME} (보고서 메타데이터의 분석 일시에 이 값을 사용하세요)
COMPLEXITY: ${COMPLEXITY:-moderate}

전처리 결과: ${EXTRACTED_DIR}/_preprocessed/ 디렉터리에 정제된 로그 파일이 있습니다.
환경 정보: ${EXTRACTED_DIR}/_env-hints.txt
파일 매니페스트: ${EXTRACTED_DIR}/_manifest.txt

CLAUDE.md의 분석 가이드라인을 따라 위 경로의 로그 파일들을 분석하고,
지정된 보고서 저장 경로에 Write 도구로 보고서를 저장해 주세요.
COMPLEXITY 값에 따라 분석 깊이를 조정하세요 (CLAUDE.md의 'COMPLEXITY 기반 분석 깊이 분기' 표 참조)."

# ── Claude 실행 ────────────────────────────────────────────────────────────
# --dangerously-skip-permissions : 자동화 실행 — 모든 도구 권한 자동 승인
# -p                             : print 모드 — 비대화형, 결과를 stdout으로 출력
# Claude는 CLAUDE.md를 읽고, 지정된 경로의 파일들을 Read/Grep으로 분석 후
# Write 도구로 보고서를 생성한다
echo ""
info "Claude 분석 시작..."
echo "────────────────────────────────────────────────────────────────"
# --output-format stream-json --verbose : 매 줄 한 JSON 이벤트
# tee로 전체 스트림을 보존하면서 jq로 텍스트만 골라 stdout에 표시
MAIN_STREAM="$WORKSPACE/_main-stream.jsonl"
claude --dangerously-skip-permissions -p "$PROMPT" --model "$MODEL" \
    --output-format stream-json --verbose 2>&1 \
    | tee "$MAIN_STREAM" \
    | jq -r --unbuffered '
        select(.type == "assistant")
        | (.message.content // .content // [])[]?
        | select(.type == "text")
        | .text
      ' 2>/dev/null || true
echo "────────────────────────────────────────────────────────────────"

# 마지막 result 이벤트에서 usage 추출
MAIN_USAGE=$(jq -c 'select(.type == "result") | .usage // empty' "$MAIN_STREAM" 2>/dev/null | tail -1)
log_tokens "main" "$MODEL" "$MAIN_USAGE"

# ── 결과 확인 ──────────────────────────────────────────────────────────────
if [ -f "$REPORT_FILE" ]; then
    echo ""
    info "분석 완료!"
    echo -e "  보고서: ${GREEN}${REPORT_FILE}${NC}"
    echo ""
    # 보고서 첫 30줄 미리보기
    echo "──── 보고서 미리보기 ────"
    head -30 "$REPORT_FILE"
    echo "..."
    echo "(전체 보고서: $REPORT_FILE)"

    # ── 케이스 DB promote (staging → cases.jsonl, db/ 활성 + staging 생성 시) ──
    if [ -f "${DB_DIR}/knowledge-base.md" ] && [ -f "$STAGING_FILE" ]; then
        if python3 "${DB_DIR}/promote_cases.py" "$DB_DIR" "$STAGING_FILE"; then
            info "케이스 DB 갱신됨 (cases.jsonl + knowledge-base.md)"
        else
            warn "케이스 promote 실패 — staging 파일 보존: $STAGING_FILE"
        fi
    fi
else
    warn "보고서 파일이 생성되지 않았습니다. Claude 출력을 확인하세요."
    warn "Claude가 Write 도구를 사용하지 않았을 수 있습니다."
fi
