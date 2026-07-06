#!/usr/bin/env python3
"""cases.jsonl -> knowledge-base.md 결정론적 생성.

진단 휴리스틱을 판별력 순으로 분리한다:
  A. 플랫폼 패턴 — 같은 메인보드가 '2대 이상 호스트(=고객사 무관)'에서 반복하는 signature.
     보드가 1대 호스트뿐이면 '단일 머신 반복'(시계열)으로 라벨을 구분한다.
  B. 공통 운영 이슈 — 여러 보드(≥UNIVERSAL_BOARDS종)에 걸쳐 나오는 보편 토큰. 판별력이
     낮으므로 여기 한 번만 모으고, A/C에서는 제외해 진단 가치 높은 시그니처를 드러낸다.
  C. 모델 코드 인덱스.
  D. 증상 시그니처 역인덱스 — 보편 토큰 제외, 2개 이상 케이스에 걸친 토큰만.

사용: python3 db/generate_kb.py db/cases.jsonl > db/knowledge-base.md
"""
import json, sys
from collections import defaultdict, Counter

UNIVERSAL_BOARDS = 3   # 이 수 이상의 서로 다른 보드에 나오면 '보편(판별력 낮음)' 토큰

# 여러 실패 모드에 공통으로 붙는 boilerplate 상태 문자열 — 특정 결함을 지목하지 못하므로
# 플랫폼 패턴(A)/시그니처 역인덱스(D) 판별에서 제외한다.
GENERIC = {
    "Failed with result 'exit-code'", "Scheduled restart job", "restart counter is at",
    "status=1/FAILURE", "status=255/EXCEPTION", "Asserted", "active running",
    "loaded failed failed", "loaded failed", "failed", "Oops", "Call Trace",
    "-- Boot", "-- Boot --", "Powering Off", "Failed to start", "exit-code",
    "Failed with result 'exit-code'.", "No space left on device",
}

path = sys.argv[1] if len(sys.argv) > 1 else "db/cases.jsonl"
with open(path, encoding="utf-8") as f:
    cases = [json.loads(l) for l in f if l.strip()]

def when(c): return (c.get("collected_at") or c.get("analyzed_at") or "")[:10]
SEV = {"critical": 0, "warning": 1, "info": 2}
def board_of(c): return c["hw"]["mainboard"]["model"]

by_board = defaultdict(list)
by_model = defaultdict(list)
tok_boards = defaultdict(set)   # token -> {board}
sig_index = defaultdict(list)   # token -> [(case_id, issue)]
for c in cases:
    by_board[board_of(c)].append(c)
    by_model[c["model_code"]].append(c)
    for iss in c["issues"]:
        for t in iss["signature"]:
            tok_boards[t].add(board_of(c))
            sig_index[t].append((c["case_id"], iss))

universal = {t for t, bs in tok_boards.items() if len(bs) >= UNIVERSAL_BOARDS}
noise = universal | GENERIC   # A/D 판별에서 제외할 비판별 토큰 (B는 universal만 사용)

out = []
def w(s=""): out.append(s)
def clip(s, n): return s if len(s) <= n else s[:n].rstrip() + "…"

w("# 진단 지식베이스 (cases.jsonl 파생 — 자동 생성)")
w()
w("> `python3 db/generate_kb.py db/cases.jsonl > db/knowledge-base.md` 로 재생성. **직접 수정 금지.**")
w(f"> 케이스 {len(cases)}건 / 고유 호스트 {len(set(c['host'] for c in cases))}대 / "
  f"메인보드 {len(by_board)}종 / 보편 토큰 {len(universal)}개(≥{UNIVERSAL_BOARDS}보드).")
w(">")
w("> Pass 1.5에서 Read: (A) 같은 메인보드의 플랫폼 패턴, (B) 공통 운영 이슈, "
  "(C) 같은 model_code 이력, (D) 새 로그 토큰과 겹치는 판별력 있는 signature.")
w()

# ================= A. 플랫폼 패턴 / 단일 머신 반복 =================
w("## A. 플랫폼 패턴 (메인보드별)")
w()
w("판별 규칙: 보드에 **호스트 2대 이상**이면 그 중 ≥2대에 공통으로 나오는(보편 토큰 제외) "
  "signature = 고객사-무관 플랫폼 결함. 호스트가 1대뿐이면 그 머신의 시계열 반복.")
w()
def sort_board(kv):
    board, g = kv
    return (-len(set(c["host"] for c in g)), -len(g), board)
for board, group in sorted(by_board.items(), key=sort_board):
    hosts = sorted(set(c["host"] for c in group))
    customers = sorted(set(c["customer"] for c in group))
    w(f"### {board}")
    if len(hosts) >= 2:
        # 토큰별 등장 호스트 (이 보드 내)
        tok_h = defaultdict(set)
        for c in group:
            for iss in c["issues"]:
                for t in iss["signature"]:
                    if t not in noise:
                        tok_h[t].add(c["host"])
        cross = {t for t, hs in tok_h.items() if len(hs) >= 2}
        w(f"- **플랫폼 패턴** · 호스트 {len(hosts)}대({', '.join(hosts)}) · 고객사 {len(customers)}곳")
        # cross 토큰을 포함하는 이슈를 title 기준 dedupe, 심각도순
        cand = {}
        for c in group:
            for iss in c["issues"]:
                if cross & set(iss["signature"]):
                    key = (SEV[iss["severity"]], when(c))
                    if iss["title"] not in cand or key < cand[iss["title"]][0]:
                        cand[iss["title"]] = (key, iss)
        if cand:
            for _, iss in sorted(cand.values(), key=lambda kv: kv[0])[:6]:
                w(f"  - **[{iss['category']}] {iss['title']}** — "
                  f"{clip(iss['root_cause'],80)} → {clip(iss['fix'],60)}")
        else:
            w("  - (보편 토큰 외 공통 플랫폼 시그니처 없음)")
    else:
        host = hosts[0]
        w(f"- **단일 머신 반복** · 호스트 {host} ({len(group)}회: {', '.join(when(c) for c in group)}) "
          f"· 고객사 {customers[0]}")
        if len(group) >= 2:
            rec = {}
            for c in group:
                for iss in c["issues"]:
                    if iss.get("recurring") and iss["title"] not in rec:
                        rec[iss["title"]] = iss
            for iss in sorted(rec.values(), key=lambda i: SEV[i["severity"]])[:6]:
                w(f"  - **[{iss['category']}] {iss['title']}** — "
                  f"{clip(iss['root_cause'],80)} → {clip(iss['fix'],60)}")
            if not rec:
                w("  - (cross-case 반복 이슈 없음)")
        else:
            w("  - (단일 케이스 — 이력 없음)")
    w()

# ================= B. 공통 운영 이슈 (보편 토큰) =================
w(f"## B. 공통 운영 이슈 (≥{UNIVERSAL_BOARDS}종 보드 공통 — 거의 모든 서버 해당)")
w()
w("판별력은 낮지만 대부분의 서버에서 반복되는 운영 위생 항목. 새 서버에서도 기본 점검 대상.")
w()
w("| 토큰 | category | 케이스 | 대표 조치 |")
w("|---|---|---|---|")
uni_rows = []
for t in universal:
    recs = sig_index[t]
    ncase = len(set(cid for cid, _ in recs))
    best = min(recs, key=lambda r: SEV[r[1]["severity"]])[1]
    uni_rows.append((ncase, t, best["category"], best["fix"]))
for ncase, t, cat, fix in sorted(uni_rows, reverse=True)[:14]:
    tok = t.replace("|", "\\|")
    w(f"| `{tok}` | {cat} | {ncase} | {clip(fix,55)} |")
w()

# ================= C. 모델 코드 인덱스 =================
w("## C. 모델 코드 인덱스")
w()
w("| model_code | GPU | 케이스 | 호스트 | recurring 이슈 |")
w("|---|---|---|---|---|")
for mc, group in sorted(by_model.items(), key=lambda kv: -len(kv[1])):
    hosts = sorted(set(c["host"] for c in group))
    rec = sum(1 for c in group for iss in c["issues"] if iss.get("recurring"))
    m = group[0]["model"]
    w(f"| `{mc}` | {m['gpu']}×{m['gpu_count']} | {len(group)} | {', '.join(hosts)} | {rec} |")
w()

# ================= D. 증상 시그니처 역인덱스 (판별력 있는 것만) =================
w("## D. 증상 시그니처 역인덱스 (판별력 있는 토큰 → 사례)")
w()
w("보편 토큰(섹션 B) 제외, **2개 이상 케이스**에 걸친 토큰만. 새 로그에 아래가 보이면 "
  "해당 사례의 root_cause/fix 우선 검토.")
w()
w("| 시그니처 토큰 | category | 케이스 | 보드 | 대표 조치 |")
w("|---|---|---|---|---|")
rows = []
for t, recs in sig_index.items():
    if t in noise:
        continue
    cids = set(cid for cid, _ in recs)
    if len(cids) < 2:
        continue
    cat = Counter(iss["category"] for _, iss in recs).most_common(1)[0][0]
    fix = min(recs, key=lambda r: SEV[r[1]["severity"]])[1]["fix"]
    rows.append((len(cids), len(tok_boards[t]), t, cat, fix))
for ncase, nboard, t, cat, fix in sorted(rows, reverse=True)[:30]:
    tok = t.replace("|", "\\|")
    w(f"| `{tok}` | {cat} | {ncase} | {nboard} | {clip(fix,50)} |")
w()

sys.stdout.write("\n".join(out) + "\n")
