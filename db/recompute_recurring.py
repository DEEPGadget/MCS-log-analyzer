#!/usr/bin/env python3
"""cases.jsonl 후처리: recurring 플래그를 cross-case 기준으로 표준화.

정의: 어떤 이슈가 recurring=true 이려면, 같은 host의 더 이른 케이스(collected_at/analyzed_at
기준)에 '같은 category' 이면서 'signature 토큰이 하나 이상 겹치는' 이슈가 존재해야 한다.
각 host의 첫 케이스는 정의상 모두 recurring=false.

사용: python3 db/recompute_recurring.py db/cases.jsonl  (in-place 재작성)
"""
import json, sys
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else "db/cases.jsonl"
with open(path, encoding="utf-8") as f:
    cases = [json.loads(l) for l in f if l.strip()]

def sort_key(c):
    return (c.get("collected_at") or c.get("analyzed_at") or "")

by_host = defaultdict(list)
for c in cases:
    by_host[c.get("host", "unknown")].append(c)

for host, group in by_host.items():
    group.sort(key=sort_key)
    for idx, case in enumerate(group):
        earlier = group[:idx]
        # 이전 케이스들의 (category -> set(signature tokens)) 누적
        prior = defaultdict(set)
        for e in earlier:
            for iss in e.get("issues", []):
                prior[iss.get("category")].update(t.lower() for t in iss.get("signature", []))
        for iss in case.get("issues", []):
            toks = {t.lower() for t in iss.get("signature", [])}
            iss["recurring"] = bool(idx > 0 and toks & prior.get(iss.get("category"), set()))

# 원래 파일 순서(입력 순서)를 보존하여 재작성
with open(path, "w", encoding="utf-8") as f:
    for c in cases:
        f.write(json.dumps(c, ensure_ascii=False, separators=(",", ":")) + "\n")

# 요약 출력
rec = [(c["case_id"], iss["title"]) for c in cases for iss in c.get("issues", []) if iss.get("recurring")]
print(f"cases={len(cases)}  recurring_issues={len(rec)}")
for cid, title in rec:
    print(f"  {cid}  {title}")
