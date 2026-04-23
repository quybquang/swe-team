#!/usr/bin/env bash
# phase-exit-verify.sh — SubagentStop hook
#
# Runs when any subagent terminates. If the subagent that just finished
# brought us to the end of the VERIFY phase (i.e. swe-lead is signalling
# "ready to ship"), this hook asserts that every task in tasks.json has
# BOTH a mech and sem `verification` event with `verified:true`.
#
# Exit codes:
#   0 — allow phase exit (or N/A — not a verify exit)
#   2 — block: missing verifications

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RUN="$ROOT/.claude/swe-team/runs/current"
[[ -d "$RUN" ]] || exit 0

PHASE_STATE="$RUN/phase_state.json"
TASKS="$RUN/tasks.json"
VERI="$RUN/verification.jsonl"

[[ -f "$PHASE_STATE" && -f "$TASKS" ]] || exit 0

PHASE="$(python3 -c "
try:
  import json
  print(json.load(open('$PHASE_STATE')).get('phase','') or '')
except: print('')
" 2>/dev/null)"

# Only enforce when leaving VERIFY phase or attempting to enter SHIP
case "$PHASE" in
  VERIFY|SHIP) : ;;
  *) exit 0 ;;
esac

[[ -f "$VERI" ]] || {
  echo "swe-team: no verification.jsonl yet — cannot exit VERIFY" >&2
  exit 2
}

MISSING=$(python3 <<EOF
import json
tasks = json.load(open("$TASKS")).get("tasks", [])
veri = []
with open("$VERI") as f:
  for line in f:
    line = line.strip()
    if not line: continue
    try: veri.append(json.loads(line))
    except: pass

missing = []
for t in tasks:
  tid = t["id"]
  if t.get("status") == "failed":
    continue
  has_mech = any(v for v in veri if v.get("task_id")==tid and v.get("tier")=="mech" and v.get("verified") is True)
  has_sem  = any(v for v in veri if v.get("task_id")==tid and v.get("tier")=="sem"  and v.get("verified") is True)
  if not (has_mech and has_sem):
    missing.append(f"{tid}(mech={has_mech},sem={has_sem})")

print("\\n".join(missing))
EOF
)

if [[ -n "$MISSING" ]]; then
  echo "swe-team: phase exit blocked — missing verifications:" >&2
  echo "$MISSING" >&2
  exit 2
fi

exit 0
