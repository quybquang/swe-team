#!/usr/bin/env bash
# tests/smoke/test-hooks.sh
# Exercise each hook script end-to-end with synthetic inputs.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
git init -q
git config user.email test@swe-team.local
git config user.name  test
git commit --allow-empty -q -m "init"

# Seed minimal swe-team layout
mkdir -p .claude/hooks .claude/swe-team/runs/r1/build
cp "$ROOT/.claude/hooks/"*.sh .claude/hooks/
chmod +x .claude/hooks/*.sh
ln -sfn r1 .claude/swe-team/runs/current

cat > swe-team.config.json <<'JSON'
{"version":"0.1.0","models":{"lead":"opus","coder":"sonnet","verifier_mech":"haiku","verifier_sem":"sonnet","pr":"sonnet"},"budget":{"max_tokens":2000000,"max_usd":15,"warn_pct":80},"limits":{"max_iterations":{"S":2,"M":4,"L":6},"max_replans":2,"stuck_identical_output":3,"stuck_file_churn":5,"max_files_per_task":10,"max_plan_tasks":15,"max_plan_loc":500},"branch":{"base":"dev","prefix":"swe/","auto_detect_base":true},"verification":{"test_cmd":"echo ok","lint_cmd":"","typecheck_cmd":"","test_globs":["**/*.test.*"],"allow_flaky_retry":true},"phases":{"define_threshold":3,"force_define":false,"skip_define":false},"gh":{"pr_labels":[],"pr_draft":false,"require_clean_working_tree":true}}
JSON

cat > .claude/swe-team/runs/r1/phase_state.json <<'JSON'
{"phase":"BUILD","active_task":"T1","replan_count":0}
JSON

cat > .claude/swe-team/runs/r1/budget.json <<'JSON'
{"total_tokens":0,"total_usd":0}
JSON

touch .claude/swe-team/runs/r1/events.jsonl
touch .claude/swe-team/runs/r1/verification.jsonl

# --- guard-destructive-git --------------------------------------------------

echo "test: guard blocks force push"
echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' \
  | ./.claude/hooks/guard-destructive-git.sh 2>/dev/null \
  && { echo "FAIL: force push not blocked"; exit 1; }
echo "  ok"

echo "test: guard allows normal command"
echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  | ./.claude/hooks/guard-destructive-git.sh
echo "  ok"

echo "test: guard blocks git reset --hard"
echo '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}' \
  | ./.claude/hooks/guard-destructive-git.sh 2>/dev/null \
  && { echo "FAIL: reset --hard not blocked"; exit 1; }
echo "  ok"

# --- budget-gate ------------------------------------------------------------

echo "test: budget gate allows when under"
echo '{}' | ./.claude/hooks/budget-gate.sh
echo "  ok"

echo "test: budget gate blocks when over"
cat > .claude/swe-team/runs/r1/budget.json <<'JSON'
{"total_tokens":2500000,"total_usd":20}
JSON
echo '{}' | ./.claude/hooks/budget-gate.sh 2>/dev/null \
  && { echo "FAIL: over-budget not blocked"; exit 1; }
# restore
echo '{"total_tokens":0,"total_usd":0}' > .claude/swe-team/runs/r1/budget.json
echo "  ok"

# --- track-file-edit --------------------------------------------------------

echo "test: track-file-edit appends action"
echo '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}' \
  | ./.claude/hooks/track-file-edit.sh
grep -q '"kind": "action"' .claude/swe-team/runs/r1/build/task-T1.jsonl
grep -q '"target": "src/a.ts"'  .claude/swe-team/runs/r1/build/task-T1.jsonl
echo "  ok"

echo "test: track-file-edit churn emits stuck"
for i in 1 2 3 4 5 6; do
  echo '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}' \
    | ./.claude/hooks/track-file-edit.sh
done
grep -q '"pattern": "file_churn"' .claude/swe-team/runs/r1/events.jsonl \
  || { echo "FAIL: churn stuck not emitted"; exit 1; }
echo "  ok"

# --- capture-test-output ----------------------------------------------------

echo "test: capture-test-output records observation"
echo '{"tool_name":"Bash","tool_input":{"command":"npm test"},"tool_response":{"stdout":"tests passed","exit_code":0}}' \
  | ./.claude/hooks/capture-test-output.sh
grep -q '"kind": "observation"' .claude/swe-team/runs/r1/build/task-T1.jsonl
echo "  ok"

# --- phase-exit-verify ------------------------------------------------------

echo "test: phase-exit blocks when verifications missing"
cat > .claude/swe-team/runs/r1/tasks.json <<'JSON'
{"version":1,"tasks":[{"id":"T1","title":"x","description":"y","size":"S","touch_files":["a"],"acceptance":["a"],"status":"done"}]}
JSON
echo '{"phase":"VERIFY"}' > .claude/swe-team/runs/r1/phase_state.json
cat > .claude/swe-team/runs/r1/phase_state.json <<'JSON'
{"phase":"VERIFY","active_task":"T1","replan_count":0}
JSON
echo '{}' | ./.claude/hooks/phase-exit-verify.sh 2>/dev/null \
  && { echo "FAIL: phase exit not blocked when missing"; exit 1; }
echo "  ok"

echo "test: phase-exit passes when both tiers verified"
cat > .claude/swe-team/runs/r1/verification.jsonl <<'JSON'
{"kind":"verification","ts":"2026-04-23T00:00:00Z","run_id":"r1","agent":"swe-verifier-mech","task_id":"T1","tier":"mech","verified":true,"evidence":{}}
{"kind":"verification","ts":"2026-04-23T00:00:01Z","run_id":"r1","agent":"swe-verifier-sem","task_id":"T1","tier":"sem","verified":true,"evidence":{}}
JSON
echo '{}' | ./.claude/hooks/phase-exit-verify.sh
echo "  ok"

echo "hooks: all checks passed"
