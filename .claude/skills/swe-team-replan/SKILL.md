---
name: swe-team:replan
description: Append-only addition to tasks.json triggered by a coder blocker or a sem verifier spec_gap. Increments version, never rewrites or deletes existing tasks. Capped at 2 re-plans per run. swe-lead only.
---

# Re-plan

## Overview
When BUILD surfaces a fact that PLAN missed — a coder blocker, a sem `spec_gap` verdict, a stuck task whose remedy is more task granularity — swe-lead appends new tasks to `tasks.json` and bumps `version`. Never rewrites or deletes. Append-only is what makes re-plans auditable: the task list is a monotonic record. Cap is 2 per run; hitting the cap aborts.

## When to Use
- `swe-lead` is reacting to a `blocker` event from a coder.
- `swe-lead` is reacting to a sem verdict with `verified:false` where `reason` implies the spec/plan is wrong (not the code).
- `swe-lead` is reacting to a `stuck` event and determines re-decomposition is the right remedy.

## When NOT to Use
- First task-list creation — that is `swe-team:decompose-tasks`, not re-plan.
- Fixing a typo in an existing task's description — forbidden; make a new task.
- Any agent other than `swe-lead` is calling — re-plan authority is lead-only.
- `phase_state.replan_count >= config.limits.max_replans` (default 2) — abort instead.

## Process
1. Re-read anchors and check the cap.
   ```bash
   COUNT=$(jq -r .replan_count .claude/swe-team/runs/current/phase_state.json)
   MAX=$(jq -r .limits.max_replans swe-team.config.json)
   if [ "$COUNT" -ge "$MAX" ]; then
     jq -nc --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
            --arg ts "$(date -u +%FT%TZ)" \
            --arg r "max_replans_exceeded" \
       '{kind:"run_abort", ts:$ts, run_id:$rid, agent:"swe-lead", reason:$r}' \
       >> .claude/swe-team/runs/current/events.jsonl
     exit 1
   fi
   ```
2. Identify the trigger (blocker reason, sem spec_gap, or stuck details). Summarize in ≤200 chars.
3. Draft new task objects. Each MUST satisfy the full `tasks-schema.json` task shape:
   - New `id` values: continue the numbering (`T_{max+1}`, ...).
   - `touch_files` ≤ 10 entries, validated against repo.
   - `acceptance` ≥ 1, independently testable.
   - `status: "pending"`.
   - `depends_on` may include existing task IDs.
4. Append, do not rewrite. Use `jq` to merge:
   ```bash
   TMP=$(mktemp)
   jq --argjson new "$NEW_TASKS_JSON" \
      '.version += 1 | .tasks += $new' \
      .claude/swe-team/runs/current/tasks.json > "$TMP"
   mv "$TMP" .claude/swe-team/runs/current/tasks.json
   ```
5. Verify invariants:
   ```bash
   jq '.tasks | length' .claude/swe-team/runs/current/tasks.json   # <= max_plan_tasks
   # existing task IDs untouched?
   # (compare old .tasks[] to new .tasks[0:old_length])
   ```
6. Increment replan counter.
   ```bash
   jq '.replan_count += 1' .claude/swe-team/runs/current/phase_state.json > "$TMP" && \
     mv "$TMP" .claude/swe-team/runs/current/phase_state.json
   ```
7. Emit the `replan` event.
   ```bash
   jq -nc \
     --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
     --arg ts "$(date -u +%FT%TZ)" \
     --argjson c $((COUNT+1)) \
     --arg r "$REASON" \
     --argjson ids "$APPENDED_IDS_JSON" \
     '{kind:"replan", ts:$ts, run_id:$rid, agent:"swe-lead",
       count:$c, reason:$r, appended_task_ids:$ids}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```
8. Resume BUILD on the first new pending task.

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "Let me restructure the old tasks; the new split is cleaner." | Rewriting is forbidden. Append only. Old tasks stay as-is; new tasks supersede via dependency graph if needed. |
| "I'll just edit T3's acceptance a little." | No. Make `T_{n+1}` with the correct acceptance; mark T3 `failed` if needed. |
| "Count is already 2 but this one is small." | Cap is a hard gate. Abort. The run is unsalvageable; human review is the exit. |
| "I can skip incrementing version since nothing else changed." | `version` bump is the audit trail. Without it, downstream tools can't detect the re-plan. |
| "I'll add 5 new tasks to be safe." | `max_plan_tasks` still applies post-append. Check total len; trim the replan. |
| "The coder's blocker reason is vague; I'll just guess." | If you can't identify the trigger in ≤200 chars, you don't have enough info — investigate or abort. |

## Red Flags
- Old task IDs appear different in the new file than the old — you rewrote; revert immediately.
- `version` did not increment — abort.
- Appended task has `touch_files` overlapping a task already `done` — cross-task conflict risk.
- `appended_task_ids` is empty but a `replan` event was emitted — incoherent; undo.
- Trigger reason is "just in case" — re-plans require an event-backed cause.

## Verification
After this skill completes:
- `.claude/swe-team/runs/current/tasks.json` has `version` incremented by exactly 1.
- Old tasks (first N entries) are bitwise identical to the pre-replan state.
- New tasks all validate against `tasks-schema.json`.
- `total_tasks <= config.limits.max_plan_tasks`.
- `phase_state.replan_count` incremented by 1, still `<= max_replans`.
- One new `replan` event in `events.jsonl` with `count`, `reason`, `appended_task_ids` populated.
