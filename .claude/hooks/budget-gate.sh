#!/usr/bin/env bash
# budget-gate.sh — PreToolUse(Task) hook
#
# Reads budget.json from the current run. If we've hit the ceiling, block
# spawning new subagents. Emits a budget_warn event at warn_pct and a
# budget_stop event at 100%.
#
# Exit codes:
#   0 — allow
#   2 — block (budget exhausted)

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RUN="$ROOT/.claude/swe-team/runs/current"
[[ -d "$RUN" ]] || exit 0  # No active run; not our concern.

BUDGET="$RUN/budget.json"
CFG="$ROOT/swe-team.config.json"
[[ -f "$BUDGET" && -f "$CFG" ]] || exit 0

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
RUN_ID="$(basename "$(readlink "$RUN" 2>/dev/null || echo "$RUN")")"

read MAX_T MAX_USD WARN_PCT < <(python3 -c "
import json
c = json.load(open('$CFG'))
b = c.get('budget', {})
print(b.get('max_tokens', 2000000), b.get('max_usd', 15), b.get('warn_pct', 80))
")

read TOTAL_T TOTAL_USD < <(python3 -c "
import json
b = json.load(open('$BUDGET'))
print(b.get('total_tokens', 0), b.get('total_usd', 0))
")

PCT_T=$(awk -v a="$TOTAL_T"   -v b="$MAX_T"   'BEGIN{printf "%.0f", (b>0?a/b*100:0)}')
PCT_U=$(awk -v a="$TOTAL_USD" -v b="$MAX_USD" 'BEGIN{printf "%.0f", (b>0?a/b*100:0)}')
PCT=$(( PCT_T > PCT_U ? PCT_T : PCT_U ))

emit_event() {
  local kind="$1"
  printf '{"kind":"%s","ts":"%s","run_id":"%s","agent":"system","pct":%d,"tokens":%d,"usd":%s}\n' \
    "$kind" "$(now)" "$RUN_ID" "$PCT" "$TOTAL_T" "$TOTAL_USD" \
    >> "$RUN/events.jsonl"
}

if (( PCT >= 100 )); then
  emit_event "budget_stop"
  echo "swe-team: budget exhausted (${PCT}%) — spawn blocked" >&2
  exit 2
elif (( PCT >= WARN_PCT )); then
  # Only emit warn once per crossing — guard against repeats
  if ! grep -q '"kind":"budget_warn"' "$RUN/events.jsonl" 2>/dev/null; then
    emit_event "budget_warn"
  fi
fi

exit 0
