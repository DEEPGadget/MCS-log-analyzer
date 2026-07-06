# MCS Log Analyzer — Claude Harness

## 권한 정책

- **허용**: `Read` (압축 해제 경로 전체), `Grep` (패턴 검색), `Write` (`reports/` 경로만)
- **Approval 필요**: 기존 보고서 파일 덮어쓰기 (같은 이름의 `.md`가 이미 존재하는 경우)
- **금지**: `reports/` 외부 경로에 파일 쓰기, 시스템 명령 실행

### Plan Mode 사용 기준

아카이브 안에 파일이 200개를 초과하거나(`--detail` 모드 수집본) `var-log-archived/` 디렉터리가 존재하면,
분석을 바로 시작하지 말고 **Plan Mode로 먼저 탐색 범위를 확정**한 뒤 실행한다.

### AskUserQuestion 사용 기준

다음 상황에서는 분석을 멈추고 사용자에게 질문한다:
- 압축 해제 경로에 아카이브 루트 디렉터리가 2개 이상 존재하는 경우 (어느 것을 분석할지)
- 보고서 저장 경로에 동일한 파일이 이미 존재하는 경우 (덮어쓸지 여부)

---

## 프로젝트 목적

Manycore 고객사 서버에서 `deepgadget-log-grabber.sh`로 수집된 진단 아카이브(`.tar.gz`)를 분석하여
잠재적 문제를 탐지하고 한국어 보고서를 생성하는 시스템이다.

`analyze.sh`가 아카이브를 압축 해제한 후 Claude를 자동 실행한다.
Claude는 이 파일의 지침에 따라 로그를 읽고 `reports/` 디렉터리에 보고서를 작성해야 한다.

---

## 참조 파일 (분석 시작 시 한 번씩만 Read)

분석 워크플로는 이 CLAUDE.md에서 정의하지만, 구체적인 임계값·서식은 별도 파일에 있다:

- **`judgment-rules.md`** — 1~4순위 판정 기준 (SMART RAW_VALUE, NVMe 키, ECC, 환경 노이즈 패턴 등)
- **`report-template.md`** — 보고서 출력 형식과 섹션 구성
- **`correlation-guide.md`** — 시간 상관관계 분석 방법

이 세 파일은 프로젝트 루트(`/home/deepgadget/MCS-log-analyzer/`)에 있다.

추가로, **케이스 DB가 있으면**(`db/knowledge-base.md` 존재) Pass 1.5에서 이를 Read하여
과거 사례를 사전지식으로 활용한다 (아래 "Pass 1.5" 참조). `db/`가 없으면 무시한다.

---

## 분석 실행 방법

`analyze.sh`가 다음 형식으로 Claude를 호출한다:
```
압축 해제 경로: /tmp/mcs-log-XXXXX/<archive-root>
보고서 저장 경로: /home/deepgadget/MCS-log-analyzer/reports/<이름>.md
케이스 스테이징 경로: /home/deepgadget/MCS-log-analyzer/db/_staging/<이름>.json   (db/ 존재 시에만)
COMPLEXITY: simple | moderate | complex   (analyze.sh의 Haiku triage 결과)
```

### COMPLEXITY 기반 분석 깊이 분기

`COMPLEXITY` 값에 따라 분석 깊이를 조정한다. 값이 prompt에 없으면 `moderate`로 가정.

| 값 | Pass 2 deep-dive | 시간 상관관계 분석 | 보고서 형식 |
|----|------------------|-------------------|-------------|
| `simple` | **생략** (Pass 1만 수행) | **생략** ("이벤트 묶음 없음"으로 한 줄 기록) | `report-template.md`의 모든 섹션 유지하되 각 섹션 내용을 짧게 (불필요한 상세 설명 생략) |
| `moderate` | Critical/Warning 발견 영역만 | 가능하면 1~2개 묶음 작성 | 표준 |
| `complex` | 풀세트 (원본 journalctl Grep, nvidia-bug-report 등) | 다중 소스 교차 확인 필수, 인과관계 추론 | 표준 (상세) |

`simple`인데 Pass 1에서 예상치 못한 Critical 신호를 발견하면 그 영역만 Pass 2를 수행한다.

### Pass 1 — Triage (빠른 탐색)

**성능 가이드 — 병렬 Read 필수**: 아래 1~6번 단계의 Read 작업은 서로 의존성이 없다.
**가능한 한 단일 응답 블록 안에서 모든 Read 도구를 동시에 호출**하라
(한 응답에 Read를 여러 번 포함). 순차 Read는 turn 수를 늘려 cache_read 토큰을
크게 증가시키므로 금지. 파일이 존재하지 않으면 그 Read만 실패하고 나머지는 계속된다.

1. `_manifest.txt`를 Read하여 아카이브 전체 파일 구조와 크기를 파악한다
2. `_env-hints.txt`를 Read하여 환경 정보(`ENV_TYPE`, 호스트명)를 확인한다
3. **인벤토리 소스 먼저 Read** (이후 분석의 컨텍스트가 되므로 우선 파악):
   - `_preprocessed/_hw-summary.txt` — 메인보드/CPU/메모리 요약 (hw-list.txt 직접 Grep 불필요)
   - `_preprocessed/_nvidia-summary.txt` — GPU 요약 (nvidia-smi.txt 직접 Read 불필요)
   - `gpu-serials.txt` — GPU 시리얼 + Bus ID (있는 경우)
   - `drives-and-storage/lsblk.txt` — 스토리지 장치 목록
   - `ibstat.txt` — InfiniBand 상태 (없으면 "없음")
4. **작은 파일 Read** (대부분 수십 줄 이하):
   - `_preprocessed/_ecc-summary.txt` — GPU ECC/리매핑 요약 (gpu-memory-errors/ 3개 통합)
   - `_preprocessed/_smart-summary.txt` — 모든 드라이브 핵심 SMART 속성. 드라이브 타입은 `[NVMe]` / `[SATA]` 태그로 표시. **Pass 2에서 Critical SMART 이슈 발견 시에만** 해당 드라이브 원본 `smartctl-*.txt`를 Read한다
   - `drives-and-storage/df.txt`
   - `drives-and-storage/mdstat.txt`
   - `sensors.txt`
   - `uptime.txt`
   - `_preprocessed/_systemctl-summary.txt` — failed 서비스 + 운영 관련 서비스 masked 여부
   - `bmc-info/ipmi-elist.txt`
5. **전처리 파일 Read** (`_preprocessed/` 디렉터리):
   - `journalctl-boots.txt` — `-- Boot` 마커 목록 (재부팅 시점 + 줄번호)
   - `journalctl-boot-context.txt` — 각 Boot 경계 직전 40줄/직후 10줄
   - `journalctl-critical.txt` — 유형별로 dedup·크기 제한된 크리티컬 이벤트 요약. 시간 상관관계 분석에 이 파일의 타임스탬프를 사용
   - `journalctl-errors.txt` — 광범위 패턴 빈도표 (타임스탬프 없음). 시간 정보는 critical.txt 또는 density.txt 참조
   - `journalctl-service-loops.txt` — 재시작 루프 서비스 요약. **counter가 1000 이상인 서비스가 있으면 soft lockup/OOM 등 CPU 이슈와 인과관계 검토**
   - `journalctl-lifecycle.txt` — 시스템 종료/재부팅 등 구조적 이벤트
   - `journalctl-density.txt` — 시간대별 로그 밀도 (비정상 폭주 구간)
   - `syslog-errors.txt` / `kern-errors.txt`
   - `dmesg-critical.txt` — dmesg-errors.txt가 대형(500줄+)인 경우에만 존재
   - `dmesg-crash-context.txt` — 원본 dmesg에서 BUG/Oops/panic/Call Trace 추출. **비어있지 않으면 크래시 발생 — 반드시 내용 확인**
   - `dmesg-full-errors.txt` — 원본 dmesg의 에러/경고 필터 (err 미만 레벨 포함)
6. `system-logs/dmesg-errors.txt`는 전처리 파일(`dmesg-critical.txt`)이 없으면 원본을 직접 Read (보통 소형)

**중요**: 원본 `journalctl.txt`, `syslog`, `kern.log`를 직접 Read하거나 전체 Grep하지 않는다.
전처리 파일로 충분하며, 원본은 `complex` 케이스의 Pass 2에서 특정 시간대만 조회할 때 사용한다.

판정 기준은 `judgment-rules.md`를 참조한다.

### Pass 1.5 — 케이스 조회 (과거 사례 대조)

Pass 1에서 메인보드 모델·`model_code`·호스트명·초기 증상을 파악한 직후, 과거 진단 이력을
사전지식으로 활용한다. **`db/knowledge-base.md`가 없으면 이 단계 전체를 건너뛴다.**

1. `db/knowledge-base.md`를 Read하여:
   - **섹션 A (플랫폼 패턴)** — 이번 아카이브의 메인보드 모델과 일치하는 항목 확인 (고객사 무관 반복 결함)
   - **섹션 C (모델 코드 인덱스)** — 같은 `model_code`/호스트의 과거 케이스 수와 recurring 이슈
   - **섹션 D (시그니처 역인덱스)** — Pass 1에서 본 로그 토큰과 겹치는 항목
2. 호스트명이 과거 케이스에 있으면 `db/cases.jsonl`을 그 host로 Grep하여 시계열을 확인한다
   (예: `grep '"host":"RNDGPU02"' db/cases.jsonl`). 같은 host의 미해결 반복이면 보고서에
   **"N번째 재발, 이전 권고 조치 미이행"** 으로 명시한다.
3. **Pass 2 조준**: KB가 지목한 알려진 패턴(예: 이 보드의 PCIe BERT fatal, 이 host의 synosnap)을
   Pass 2의 우선 확인 대상으로 삼는다.

**가드레일 (필수)** — 과거 사례는 **가설**일 뿐이다:
- 반드시 이번 아카이브의 실제 로그로 재확인한다. 증거가 없으면 "과거와 달리 이번엔 미발견"으로 기록.
- KB에 있다는 이유만으로 없는 이슈를 만들지 않는다. KB에 없는 새 이슈도 평소대로 발굴한다.
- 보고서 본문의 근거는 언제나 **이번 아카이브의 로그 인용**이어야 한다 (과거 케이스 인용으로 대체 금지).

### Pass 2 — Deep-dive (상세 분석, `moderate`/`complex`만)

7. Pass 1에서 Critical 또는 Warning이 발견된 영역에 대해서만 추가 조사:
   - `journalctl-density.txt`에서 비정상 밀도 구간이 발견되면, 해당 시간대를 원본 `journalctl.txt`에서 Grep하여 문맥 확인 (`complex`만)
   - **soft lockup 발견 시**: `journalctl-service-loops.txt`의 높은 restart counter 서비스를 확인하고, 해당 서비스의 PID와 lockup 직전(~5분) 타임라인을 원본 `journalctl.txt`에서 Grep하여 인과관계를 명확히 기록
   - SMART Critical이면 해당 드라이브의 전체 smartctl 출력 정밀 검토
   - GPU 에러 발견 시 `nvidia-bug-report.log` 관련 섹션 Grep (파일이 존재하는 경우)
   - PCIe Link Speed 확인 시 `nvidia-bug-report.log`에서 `LnkSta` / `LnkCap` Grep
8. 4순위 보조 정보 파일 확인 (`apt-history.log` 등)
9. 발견한 모든 문제를 심각도별로 분류
10. **시간 상관관계 분석**: `correlation-guide.md`를 따라 이벤트 묶음을 구성

### 보고서 저장

보고서를 Write하기 전에 다음을 확인한다:

1. **심각도 일관성**: 같은 유형의 이슈가 다른 심각도로 분류되어 있지 않은지 확인
2. **보고서 구조 검증**: `report-template.md`의 섹션 순서·필수 섹션이 모두 포함되었는지 확인
3. **보고서 형식**: `report-template.md` 구조를 따라 `Write` 도구로 지정된 경로에 저장
4. stdout에 1~3줄 요약 출력
5. **케이스 DB 적재 (staging)** — prompt에 `케이스 스테이징 경로`가 있을 때만 수행:
   보고서를 `db/SCHEMA.md` 형식의 케이스 레코드 1줄(minified JSON)로 추출하여 그 경로에 `Write`한다.
   - `case_id`(`<YYMMDD>-<gpu>-<host>`), `report_file`, `host`, `model_code`, `model`, `hw`,
     `summary`, `issues[]`(각 이슈에 `signature` grep 토큰 포함)를 채운다.
   - `recurring`은 전부 `false`로 둔다 (promote 단계에서 host별로 재계산됨).
   - 이 파일은 analyze.sh가 검증 후 `cases.jsonl`로 promote한다. 추출 실패는 보고서에 영향 없음(무시).

---

## 분석 시 주의사항

1. **환경 감지**: `_env-hints.txt`의 `ENV_TYPE` 값을 사용. 파일이 없을 때의 수동 판별 절차와 환경별 노이즈 패턴은 `judgment-rules.md`의 "환경 감지 및 노이즈 패턴" 섹션 참조. 판별 결과는 보고서 상단 메타데이터에 기록 (`**환경:** WSL2 / VM (QEMU) / 베어메탈`)
2. **중복 제거**: 같은 패턴이 반복되면 "N회 반복"으로 집약하여 기록
3. **근거 제시**: 모든 이슈에 실제 로그 내용을 인용
4. **없는 파일**: 파일이 아카이브에 없으면 해당 항목은 "파일 없음"으로 처리
5. **아카이브 구조**: 루트 디렉터리 이름은 아카이브마다 다를 수 있음 (예: `Manycore-bug-report/`, `customer-abc/`)
