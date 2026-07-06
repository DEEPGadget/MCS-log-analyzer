# Case DB 스키마 (`cases.jsonl`)

보고서 1개 = JSONL 1줄. 기계 판독용(grep/jq), git append-friendly.
사람/Claude가 읽는 요약은 `knowledge-base.md`가 이 파일에서 파생된다.

## 최상위 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `case_id` | string | `<YYMMDD>-<gpu>-<host>` 형태의 안정적 키. 예: `260428-h200nvl4-rndgpu02` |
| `report_file` | string | `reports/` 내 원본 md 파일명 |
| `analyzed_at` | string | 보고서 상단 "분석 일시" (ISO8601, KST) |
| `collected_at` | string\|null | uptime 기준 부팅 시각(근사) 또는 grabber 수집 시각 |
| `customer` | string | 고객사명(내부용). 외부 공유 시 익명화 대상 |
| `host` | string | 호스트명 — **동일 물리 머신 추적의 1차 키** (같은 host = 같은 서버의 시계열) |
| `model_code` | string | 파일명의 모델 코드. 예: `dg5W-H200NVL-4` |
| `model` | object | `model_code` 디코딩 → `{gen, form, gpu, gpu_count}` |
| `env` | string | `bare-metal` \| `wsl2` \| `vm` |
| `hw` | object | 하드웨어 인벤토리 (아래) |
| `summary` | object | `{critical, warning, info}` 건수 |
| `issues` | array | 이슈 레코드 배열 (아래) — **진단 매칭의 핵심** |
| `source` | string? | 적재 경로. 수동 백필은 없음, `analyze.sh` 자동 적재는 `"auto-analyze"` (오염 사후 필터용) |

## `model` (model_code 디코딩)

`dg{gen}{form}-{gpu}-{count}` → `dg5W-H200NVL-4`:
- `gen`: 세대 정수 (5)
- `form`: `W`=워크스테이션 / `R`=랙 / `S`=(서버형 추정)
- `gpu`: GPU 코드 (`H200NVL`, `A6000`, `A100`, `4090`, `5090`)
- `gpu_count`: GPU 장수 (4)

## `hw`

```
mainboard: {vendor, model, bios}
cpu:       {model, sockets, cores, threads}
gpu:       {model, count, driver, cuda, mem_mib}
memory:    {total_gib, slots, populated, dimm}
storage:   [{dev, type, model, size, mount}]   // type: NVMe|SATA|HW-RAID|USB
ib:        {model, ports, state, speed} | null
nic:       [string]                            // 선택
```

## `issues[]`

진단 재사용의 핵심. 각 이슈는 "증상 시그니처 → 근본원인 → 조치".

| 필드 | 타입 | 설명 |
|------|------|------|
| `severity` | string | `critical` \| `warning` \| `info` |
| `category` | string | 통제 어휘 (아래) |
| `title` | string | 사람용 제목 |
| `signature` | array[string] | **grep 가능한 토큰** — 새 로그와 매칭하는 지문. 예: `["synosnap","NULL pointer dereference","handle_bdev_mount_event"]` |
| `component` | string | 관련 모듈/장치. 예: `synosnap (DKMS)`, `nvme_core`, `PSU1/PSU2` |
| `root_cause` | string | 추정 근본원인 (1~2문장) |
| `fix` | string | 권장 조치 요약 |
| `evidence` | string | 대표 출처 `파일:라인` |
| `recurring` | bool | 같은 host의 이전 케이스에도 나타난 반복 이슈면 true |

### `category` 통제 어휘

| category | 포함 |
|----------|------|
| `power` | PSU AC lost, VIN, 정전/순단 |
| `pcie` | AER correctable/uncorrectable/fatal, link 다운그레이드, BERT |
| `cpu` | CATERR/IERR, MCA/MCE, soft lockup |
| `gpu` | Xid, ECC/remapped rows, fabricmanager, FSP boot |
| `storage` | SMART, unsafe shutdown, mount 실패, df 임계 |
| `kernel` | Oops/BUG/panic, 서드파티 모듈 크래시 (synosnap 등) |
| `service` | systemd restart loop, kubelet/containerd, 서비스 failed |
| `memory` | cgroup OOM, DIMM 채널 |
| `thermal` | 온도 임계, 팬 |
| `network` | NIC link down, NFS, wait-online |
| `config` | unattended-upgrades, swap, secureboot 등 운영 설정 |

## 진단 매칭 방식 (`knowledge-base.md` + Pass 1.5)

새 아카이브 분석 시:
1. **HW 축** — 같은 `model_code`(또는 같은 `gpu`/`mainboard.model`) 케이스 조회 → 그 모델 고유 반복 이슈의 사전확률
2. **증상 축** — 새 로그에서 뽑은 토큰을 `issues[].signature`와 매칭 → 과거 `root_cause`/`fix` 인용
3. 같은 `host`가 있으면 시계열로 "미해결 반복" 여부 판정 (예: synosnap 3개월 연속)
