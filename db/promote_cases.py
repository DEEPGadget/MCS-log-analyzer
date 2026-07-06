#!/usr/bin/env python3
"""staging 케이스를 cases.jsonl 로 promote (검증 → dedup append → 재계산 → KB 재생성).

analyze.sh가 보고서 생성 성공 후 호출한다:
    python3 db/promote_cases.py <db_dir> <staging_file.json>

동작:
  1. staging JSON 검증 (필수 키). 실패 시 exit 1 (analyze.sh가 staging 보존 + 경고).
  2. case_id 중복이면 skip (멱등). 아니면 source="auto-analyze" 붙여 cases.jsonl append.
  3. recompute_recurring.py + generate_kb.py 재실행 (recurring 재계산 + KB 재생성).
  4. staging 파일을 _staging/promoted/ 로 이동.

오염 완충: 자동 적재 레코드는 source="auto-analyze" 로 표시되므로 사후 필터/삭제가 쉽다.
"""
import json, sys, os, subprocess, shutil

REQUIRED = ("case_id", "report_file", "host", "model_code", "issues")

def fail(msg):
    print(f"[promote] 실패: {msg}", file=sys.stderr)
    sys.exit(1)

if len(sys.argv) != 3:
    fail("사용법: promote_cases.py <db_dir> <staging_file>")
db_dir, staging = sys.argv[1], sys.argv[2]
cases_path = os.path.join(db_dir, "cases.jsonl")

# 1. staging 파싱 (코드펜스가 섞여 있으면 방어적으로 제거)
try:
    raw = open(staging, encoding="utf-8").read().strip()
    if raw.startswith("```"):
        raw = raw.split("```")[1]
        if raw.startswith("json"):
            raw = raw[4:]
        raw = raw.strip()
    rec = json.loads(raw)
except Exception as e:
    fail(f"staging JSON 파싱 불가: {e}")

missing = [k for k in REQUIRED if k not in rec or rec[k] in (None, "", [])]
if missing:
    fail(f"필수 키 누락: {missing}")
if not isinstance(rec["issues"], list):
    fail("issues 가 배열이 아님")

# 2. dedup + append
existing_ids = set()
if os.path.exists(cases_path):
    with open(cases_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    existing_ids.add(json.loads(line)["case_id"])
                except Exception:
                    pass

if rec["case_id"] in existing_ids:
    print(f"[promote] 이미 존재하는 case_id={rec['case_id']} — append 생략")
else:
    rec.setdefault("source", "auto-analyze")
    for iss in rec["issues"]:
        iss.setdefault("recurring", False)
    with open(cases_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"[promote] append: {rec['case_id']} (issues={len(rec['issues'])})")

# 3. recompute + KB 재생성
py = sys.executable
subprocess.run([py, os.path.join(db_dir, "recompute_recurring.py"), cases_path], check=True)
kb_path = os.path.join(db_dir, "knowledge-base.md")
with open(kb_path, "w", encoding="utf-8") as kb:
    subprocess.run([py, os.path.join(db_dir, "generate_kb.py"), cases_path],
                   check=True, stdout=kb)
print(f"[promote] cases.jsonl + knowledge-base.md 갱신 완료")

# 4. staging 파일 이동
promoted_dir = os.path.join(db_dir, "_staging", "promoted")
os.makedirs(promoted_dir, exist_ok=True)
shutil.move(staging, os.path.join(promoted_dir, os.path.basename(staging)))
