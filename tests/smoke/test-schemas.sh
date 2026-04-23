#!/usr/bin/env bash
# tests/smoke/test-schemas.sh
# Validate each example event/task/verification/config against its schema.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REF="$ROOT/.claude/references"
export ROOT REF

command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
if ! python3 -c "import jsonschema" 2>/dev/null; then
  echo "installing jsonschema for this test run"
  python3 -m pip install --quiet --user jsonschema || {
    echo "SKIP: could not install jsonschema — install manually for schema tests"
    exit 0
  }
fi

python3 <<'PY'
import json, os
from jsonschema import Draft202012Validator, validate
REF  = os.environ["REF"]
ROOT = os.environ["ROOT"]

# 1. Schemas themselves are valid Draft 2020-12
for p in [
  f"{REF}/event-schema.json",
  f"{REF}/tasks-schema.json",
  f"{REF}/verification-schema.json",
  f"{REF}/config-schema.json",
]:
  s = json.load(open(p))
  Draft202012Validator.check_schema(s)
  print(f"ok: schema {os.path.basename(p)}")

# 2. Event samples
event_schema = json.load(open(f"{REF}/event-schema.json"))
samples = [
  {"kind":"phase_enter","ts":"2026-04-23T22:15:03Z","run_id":"2026-04-23-2215-demo","agent":"swe-lead","phase":"PLAN"},
  {"kind":"action","ts":"2026-04-23T22:15:04Z","run_id":"2026-04-23-2215-demo","agent":"swe-coder","task_id":"T1","tool":"Edit","target":"src/a.ts"},
  {"kind":"observation","ts":"2026-04-23T22:15:05Z","run_id":"2026-04-23-2215-demo","agent":"swe-coder","task_id":"T1","tool":"Bash","exit_code":0,"stdout_sha256":"sha256:" + "0"*64,"summary":"ok"},
  {"kind":"verification","ts":"2026-04-23T22:15:06Z","run_id":"2026-04-23-2215-demo","agent":"swe-verifier-mech","task_id":"T1","tier":"mech","verified":True,"evidence":{"commit_sha":"abcdef1","test_exit":0,"test_output_sha256":"sha256:" + "1"*64,"assertion_count":5,"assertion_baseline":5,"deleted_test_files":[],"new_skip_or_only_count":0,"lint_exit":0,"typecheck_exit":0}},
  {"kind":"stuck","ts":"2026-04-23T22:15:07Z","run_id":"2026-04-23-2215-demo","agent":"system","task_id":"T1","pattern":"file_churn","details":{"file":"src/a.ts"}},
  {"kind":"budget_warn","ts":"2026-04-23T22:15:08Z","run_id":"2026-04-23-2215-demo","agent":"system","pct":85,"tokens":1700000,"usd":12.5},
  {"kind":"run_complete","ts":"2026-04-23T22:15:09Z","run_id":"2026-04-23-2215-demo","agent":"swe-pr","pr_url":"https://github.com/x/y/pull/1","branch":"swe/demo"},
]
for ev in samples:
  validate(instance=ev, schema=event_schema)
  print(f"ok: event {ev['kind']}")

# 3. tasks.json
tasks_schema = json.load(open(f"{REF}/tasks-schema.json"))
doc = {"version": 1, "tasks": [{
  "id":"T1","title":"Do thing","description":"Desc.","size":"S",
  "touch_files":["src/a.ts"],"acceptance":["a1"],"status":"pending"
}]}
validate(instance=doc, schema=tasks_schema)
print("ok: tasks.json example")

# 4. verification evidence
veri_schema = json.load(open(f"{REF}/verification-schema.json"))
mech_evidence = {
  "commit_sha":"abcdef1","test_exit":0,"test_output_sha256":"sha256:" + "1"*64,
  "assertion_count":5,"assertion_baseline":5,"deleted_test_files":[],
  "new_skip_or_only_count":0,"lint_exit":0,"typecheck_exit":0
}
validate(instance=mech_evidence, schema=veri_schema)
print("ok: verification mech evidence")

sem_evidence = {
  "commit_sha":"abcdef1","acceptance_met":["A1"],"acceptance_missing":[],
  "scope_diff_clean":True,"out_of_scope_files":[],"reasoning_cites_evidence":True,
  "reasoning":"src/a.ts:12 implements A1"
}
validate(instance=sem_evidence, schema=veri_schema)
print("ok: verification sem evidence")

# 5. config.default.json
config_schema = json.load(open(f"{REF}/config-schema.json"))
cfg = json.load(open(f"{ROOT}/.claude/swe-team/config.default.json"))
cfg.pop("$schema", None)
validate(instance=cfg, schema=config_schema)
print("ok: config.default.json")
PY

echo "schemas: all validated"
