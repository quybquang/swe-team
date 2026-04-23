#!/usr/bin/env bash
# capture-test-output.sh — PostToolUse(Bash) hook
#
# When the bash command was a test runner (npm test / pnpm test / yarn test /
# pytest / go test / vitest / jest), capture the output, hash it, append an
# observation event with stdout_sha256, and check for `identical_test_output`
# stuck pattern (3 consecutive identical hashes).
#
# Exit 0 always — advisory.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RUN="$ROOT/.claude/swe-team/runs/current"
[[ -d "$RUN" ]] || exit 0

INPUT="$(cat)"

CMD="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except: print("")' 2>/dev/null)"

[[ -n "$CMD" ]] || exit 0

# Only react to test commands
case "$CMD" in
  *"npm test"*|*"pnpm test"*|*"yarn test"*|*"pytest"*|*"go test"*|*"vitest"*|*"jest"*)
    : ;;
  *)
    exit 0 ;;
esac

PHASE_STATE="$RUN/phase_state.json"
TASK_ID="$(python3 -c "
try:
  import json
  print(json.load(open('$PHASE_STATE')).get('active_task') or '')
except: print('')
" 2>/dev/null)"
[[ -n "$TASK_ID" ]] || TASK_ID="unscoped"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
RUN_ID="$(basename "$(readlink "$RUN" 2>/dev/null || echo "$RUN")")"

# tool_response.stdout from input
STDOUT="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  r = d.get("tool_response", {})
  if isinstance(r, dict):
    out = r.get("stdout") or r.get("output") or ""
  else:
    out = str(r)
  print(out)
except: print("")' 2>/dev/null)"

EXIT_CODE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  r = d.get("tool_response", {})
  if isinstance(r, dict):
    print(r.get("exit_code", r.get("returncode", -1)))
  else:
    print(-1)
except: print(-1)' 2>/dev/null)"

SHA="sha256:$(printf '%s' "$STDOUT" | shasum -a 256 | cut -d' ' -f1)"

LOG="$RUN/build/task-$TASK_ID.jsonl"
mkdir -p "$(dirname "$LOG")"

# Truncate summary to 200 chars
SUMMARY="$(printf '%s' "$STDOUT" | tail -c 200 | tr -d '\n' | tr -d '"' | cut -c1-200)"

python3 -c "
import json
e = {
  'kind': 'observation',
  'ts': '$(now)',
  'run_id': '$RUN_ID',
  'agent': 'swe-coder',
  'task_id': '$TASK_ID',
  'tool': 'Bash',
  'exit_code': int('$EXIT_CODE') if '$EXIT_CODE'.lstrip('-').isdigit() else -1,
  'stdout_sha256': '$SHA',
  'summary': '''$SUMMARY'''
}
print(json.dumps(e))
" >> "$LOG"

# identical_test_output detection: last 3 observations on this task
RECENT=$(grep '"tool": "Bash"' "$LOG" 2>/dev/null | tail -3 | python3 -c "
import sys, json
hashes = []
for line in sys.stdin:
  try:
    e = json.loads(line)
    if e.get('stdout_sha256'):
      hashes.append(e['stdout_sha256'])
  except: pass
print(' '.join(hashes))
" 2>/dev/null)

LIMIT=$(python3 -c "
try:
  import json
  print(json.load(open('$ROOT/swe-team.config.json')).get('limits',{}).get('stuck_identical_output',3))
except: print(3)
" 2>/dev/null)

COUNT=$(printf '%s\n' $RECENT | sort -u | wc -l | tr -d ' ')
TOTAL=$(printf '%s\n' $RECENT | wc -w | tr -d ' ')

if [[ "$TOTAL" -ge "$LIMIT" && "$COUNT" -eq 1 ]]; then
  python3 -c "
import json
e = {
  'kind': 'stuck',
  'ts': '$(now)',
  'run_id': '$RUN_ID',
  'agent': 'system',
  'task_id': '$TASK_ID',
  'pattern': 'identical_test_output',
  'details': {'sha': '$SHA', 'consecutive': $TOTAL}
}
print(json.dumps(e))
" >> "$RUN/events.jsonl"
fi

exit 0
