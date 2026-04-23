---
name: swe-team:detect-stuck
description: Pattern-match event logs for the four stuck signals defined in SPEC §8 — identical_commit, identical_test_output, file_churn, no_verified_progress — and emit a stuck event. Primarily hook-invoked, documented here so swe-lead can reason about it.
---

# Detect Stuck

## Overview
Four deterministic "no progress" patterns indicate the loop must abort instead of burning budget. This skill codifies the exact matching logic and emits a structured `stuck` event. The hooks (`track-file-edit.sh`, `capture-test-output.sh`, `phase-exit-verify.sh`) run simplified versions of this logic inline; the skill is the reference spec they implement and the tool swe-lead uses to triage a `stuck` event's `details`.

## When to Use
- Hook-invoked on PostToolUse(Bash|Edit|Write) after a new event is appended.
- swe-lead reading `events.jsonl` during re-plan decision — check stuck patterns before spawning a new coder.
- Post-hoc run audit.

## When NOT to Use
- Run has just started (< 3 observations total) — not enough data; any pattern match is a false positive.
- During DEFINE/PLAN/SHIP — stuck patterns apply to BUILD/VERIFY iteration.
- Detecting "slow" progress — this skill is only for the 4 binary patterns.

## Process
1. Load current active task.
   ```bash
   TASK_ID=$(jq -r .active_task .claude/swe-team/runs/current/phase_state.json)
   BUILD_LOG=".claude/swe-team/runs/current/build/task-${TASK_ID}.jsonl"
   VER_LOG=".claude/swe-team/runs/current/verification.jsonl"
   ```
2. **Pattern: `identical_commit`** — 2 consecutive commits on the task with identical diff hash.
   ```bash
   # Pull last 2 commit SHAs for this task from verification events
   SHAS=$(jq -r --arg tid "$TASK_ID" \
     'select(.task_id==$tid and .tier=="mech") | .evidence.commit_sha' \
     "$VER_LOG" | tail -n 2)
   if [ $(echo "$SHAS" | wc -l) -eq 2 ]; then
     H1=$(git diff $(echo "$SHAS" | head -n1)~1..$(echo "$SHAS" | head -n1) | shasum -a 256 | awk '{print $1}')
     H2=$(git diff $(echo "$SHAS" | tail -n1)~1..$(echo "$SHAS" | tail -n1) | shasum -a 256 | awk '{print $1}')
     [ "$H1" = "$H2" ] && PATTERN="identical_commit"
   fi
   ```
3. **Pattern: `identical_test_output`** — 3 consecutive mech verdicts for this task with identical `test_output_sha256`.
   ```bash
   LAST3=$(jq -r --arg tid "$TASK_ID" \
     'select(.task_id==$tid and .tier=="mech") | .evidence.test_output_sha256' \
     "$VER_LOG" | tail -n 3)
   UNIQ=$(echo "$LAST3" | sort -u | wc -l)
   [ $(echo "$LAST3" | wc -l) -eq 3 ] && [ "$UNIQ" -eq 1 ] && PATTERN="identical_test_output"
   ```
4. **Pattern: `file_churn`** — same file has >5 `action` events (`tool:Edit|Write`) in this task.
   ```bash
   CHURN=$(jq -r 'select(.kind=="action" and (.tool=="Edit" or .tool=="Write")) | .target' \
     "$BUILD_LOG" | sort | uniq -c | sort -rn | head -n 1)
   COUNT=$(echo "$CHURN" | awk '{print $1}')
   [ "${COUNT:-0}" -gt 5 ] && PATTERN="file_churn"
   ```
5. **Pattern: `no_verified_progress`** — 3 iterations on this task with no `verification{verified:true}` event.
   ```bash
   ITER=$(jq -r --arg tid "$TASK_ID" \
     'select(.id==$tid) | .iteration_count // 0' \
     .claude/swe-team/runs/current/tasks.json)
   VERIFIED_TRUE=$(jq -r --arg tid "$TASK_ID" \
     'select(.task_id==$tid and .verified==true) | .tier' "$VER_LOG" | wc -l)
   [ "$ITER" -ge 3 ] && [ "$VERIFIED_TRUE" -eq 0 ] && PATTERN="no_verified_progress"
   ```
6. If any pattern matched, emit the `stuck` event with structured `details`.
   ```bash
   jq -nc \
     --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
     --arg ts "$(date -u +%FT%TZ)" \
     --arg tid "$TASK_ID" --arg p "$PATTERN" \
     --argjson details "$DETAILS_JSON" \
     '{kind:"stuck", ts:$ts, run_id:$rid, agent:"system",
       task_id:$tid, pattern:$p, details:$details}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```
7. `details` shape per pattern:
   - `identical_commit`: `{ "commit_shas": [sha1, sha2], "diff_sha256": "..." }`
   - `identical_test_output`: `{ "test_output_sha256": "sha256:...", "attempts": 3 }`
   - `file_churn`: `{ "file": "path.ts", "edit_count": 7 }`
   - `no_verified_progress`: `{ "iterations": 3, "last_mech_verified": false }`

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "The coder just needs one more try." | The pattern is based on evidence of no change. Extra tries burn budget without information gain. |
| "identical_test_output is fine if the test is known-flaky." | Known flakiness is handled by `flaky_retries` in mech evidence, not by ignoring the stuck signal. |
| "File churn on one file is normal during debug." | `>5 edits` is the defined threshold. Respect the config value. |
| "I'll skip the detection to save log I/O." | Hooks are cheap. Skipping stuck detection is how you burn 10× the tokens on a doomed task. |
| "Only the hook should emit stuck; a skill call is redundant." | Hook emits on PostToolUse; swe-lead may also check during re-plan reasoning. Idempotent — duplicate events are deduped by timestamp. |

## Red Flags
- Two distinct patterns fire on the same task in one iteration — the task is deeply broken; abort, don't re-plan.
- `no_verified_progress` fires on iteration 2 (cap is 3) — either config was tuned too aggressively or ground truth is wrong; audit.
- `file_churn` on a file NOT in `touch_files` — that's out-of-scope editing AND stuck; double fail.

## Verification
After this skill runs:
- If no pattern matched, exit 0 with no event emitted.
- If a pattern matched, exactly one new `stuck` event in `events.jsonl` with `pattern` set to one of the four enum values from `event-schema.json`, `task_id` populated, and a non-empty `details` object.
- `details` follows the shape for its pattern (step 7).
- The event conforms to `event-schema.json` (kind/ts/run_id/agent/pattern required).
