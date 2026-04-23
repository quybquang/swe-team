#!/usr/bin/env bash
# track-file-edit.sh — PostToolUse(Edit|Write) hook
#
# Appends an `action` event to the active task's build/task-<id>.jsonl.
# Tallies edits per file; emits a `stuck:file_churn` event if a single file
# is edited more than `stuck_file_churn` times in a single task.
#
# Exit code 0 always — advisory only.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RUN="$ROOT/.claude/swe-team/runs/current"
[[ -d "$RUN" ]] || exit 0

INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  ti = d.get("tool_input", {})
  print(ti.get("file_path") or ti.get("path") or "")
except Exception:
  print("")' 2>/dev/null)"

[[ -n "$FILE" ]] || exit 0

PHASE_STATE="$RUN/phase_state.json"
TASK_ID="$(python3 -c "
import json, sys
try:
  s = json.load(open('$PHASE_STATE'))
  print(s.get('active_task') or '')
except Exception:
  print('')
" 2>/dev/null)"
[[ -n "$TASK_ID" ]] || exit 0

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
RUN_ID="$(basename "$(readlink "$RUN" 2>/dev/null || echo "$RUN")")"
LOG="$RUN/build/task-$TASK_ID.jsonl"
mkdir -p "$(dirname "$LOG")"

TOOL="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_name",""))
except: print("")' 2>/dev/null)"

# Append action event
python3 -c "
import json
e = {
  'kind': 'action',
  'ts': '$(now)',
  'run_id': '$RUN_ID',
  'agent': 'swe-coder',
  'task_id': '$TASK_ID',
  'tool': '$TOOL',
  'target': '''$FILE'''
}
print(json.dumps(e))
" >> "$LOG"

# Churn detection
CFG="$ROOT/swe-team.config.json"
LIMIT=$(python3 -c "
try:
  import json
  print(json.load(open('$CFG')).get('limits',{}).get('stuck_file_churn', 5))
except: print(5)
" 2>/dev/null)

COUNT=$(grep -c "\"target\": \"$FILE\"" "$LOG" 2>/dev/null || echo 0)
if (( COUNT > LIMIT )); then
  python3 -c "
import json
e = {
  'kind': 'stuck',
  'ts': '$(now)',
  'run_id': '$RUN_ID',
  'agent': 'system',
  'task_id': '$TASK_ID',
  'pattern': 'file_churn',
  'details': {'file': '''$FILE''', 'edit_count': $COUNT, 'limit': $LIMIT}
}
print(json.dumps(e))
" >> "$RUN/events.jsonl"
fi

exit 0
