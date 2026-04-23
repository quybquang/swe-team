---
name: swe-team:condense-context
description: Assemble the minimal per-agent context slice per SPEC section 3.6 — requirement, task, relevant events — as a string ready to inject into a Task tool prompt. Called by the spawning agent before every subagent spawn.
---

# Condense Context

## Overview
Each subagent spawn in Claude Code is a fresh context. To prevent hallucination and stay inside the token budget, the spawning agent must inject only the slice of state relevant to the target agent (SPEC §3.6). This skill returns that slice as a printable string to paste into the Task prompt. Without it, each coder gets the entire events log and regresses toward single-agent long-horizon failure modes.

## When to Use
- About to call the `Task` tool to spawn any swe-team subagent (coder, verifier-mech, verifier-sem, pr).
- swe-lead assembling the prompt for the next phase's first subagent.
- Refreshing a context slice after a re-plan (existing slice may be stale).

## When NOT to Use
- Talking to the user directly — no subagent involved, no condensation needed.
- Reading files for the spawning agent's own reasoning — this skill is for the CHILD, not the parent.
- Building the PR body — that is `swe-team:open-pr`, which aggregates everything, not condenses.

## Process
1. Determine target agent type and (if applicable) `task_id`.
2. Assemble the slice per SPEC §3.6:

**For `swe-coder` (task `T_i`)**:
```bash
RUN_JSON=$(jq -c . .claude/swe-team/runs/current/run.json)
TASK=$(jq --arg tid "$TASK_ID" -c '.tasks[] | select(.id==$tid)' \
  .claude/swe-team/runs/current/tasks.json)
BUILD_LOG=".claude/swe-team/runs/current/build/task-${TASK_ID}.jsonl"
RECENT=""
[ -f "$BUILD_LOG" ] && RECENT=$(tail -n 30 "$BUILD_LOG")
FILES_CONTENT=""
for f in $(echo "$TASK" | jq -r '.touch_files[]'); do
  [ -f "$f" ] && FILES_CONTENT+="--- $f ---"$'\n'"$(cat "$f")"$'\n'
done
```

**For `swe-verifier-mech`**:
```bash
TASK=$(jq --arg tid "$TASK_ID" -c '.tasks[] | select(.id==$tid)' \
  .claude/swe-team/runs/current/tasks.json)
BASE=$(jq -r .base_branch .claude/swe-team/runs/current/run.json)
DIFF=$(git diff "$BASE"..HEAD)
```

**For `swe-verifier-sem`**:
```bash
TASK=$(jq --arg tid "$TASK_ID" -c '.tasks[] | select(.id==$tid)' \
  .claude/swe-team/runs/current/tasks.json)
BASE=$(jq -r .base_branch .claude/swe-team/runs/current/run.json)
DIFF=$(git diff "$BASE"..HEAD)
MECH=$(jq -c --arg tid "$TASK_ID" \
  'select(.task_id==$tid and .tier=="mech")' \
  .claude/swe-team/runs/current/verification.jsonl | tail -n 1)
REQ=$(jq -c .requirement .claude/swe-team/runs/current/run.json)
```

**For `swe-pr`**:
```bash
RUN_JSON=$(jq -c . .claude/swe-team/runs/current/run.json)
TASKS_JSON=$(jq -c . .claude/swe-team/runs/current/tasks.json)
VERIFICATION=$(cat .claude/swe-team/runs/current/verification.jsonl)
BASE=$(jq -r .base_branch .claude/swe-team/runs/current/run.json)
GIT_LOG=$(git log --oneline "$BASE"..HEAD)
```

**For `swe-lead`** (re-entry after a subagent returns):
```bash
RUN_JSON=$(jq -c . .claude/swe-team/runs/current/run.json)
TASKS_JSON=$(jq -c . .claude/swe-team/runs/current/tasks.json)
PHASE=$(jq -c . .claude/swe-team/runs/current/phase_state.json)
LAST50=$(tail -n 50 .claude/swe-team/runs/current/events.jsonl)
BLOCKERS=$(jq -c 'select(.kind=="blocker")' \
  .claude/swe-team/runs/current/events.jsonl \
  .claude/swe-team/runs/current/build/task-*.jsonl 2>/dev/null)
VERIF=$(cat .claude/swe-team/runs/current/verification.jsonl)
```

3. Render the slice as a structured string:
   ```
   # Context for <agent-name> (<task_id if applicable>)

   ## run.json (requirement anchor)
   <RUN_JSON>

   ## Task
   <TASK>

   ## <agent-specific section>
   <DIFF | MECH | RECENT | ...>
   ```
4. Return the string to the caller. The caller pastes it verbatim into the `Task` prompt before appending the agent-specific instructions.
5. Never include state NOT listed in SPEC §3.6 for that agent.

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "Giving the coder the full events log can't hurt." | It can — error accumulation scales with irrelevant context. §3.6 is minimal by design. |
| "I'll skip reading run.json; the task has enough info." | Ground-truth rule (§3.5) requires anchor re-read. Keep `run.json` in every slice. |
| "touch_files are too large; I'll summarize." | Source summaries drift. Pass the raw file contents; truncation is the target agent's job if needed. |
| "Verifier doesn't need the mech result — let it compute fresh." | Sem is gated on mech passing. Sem must see the mech verdict (commit_sha matching). |
| "I can skip this skill; the Task prompt will be fine." | Without condensation, each spawn carries unbounded context. Cost and correctness both suffer. |

## Red Flags
- Returned slice exceeds a reasonable size (say, 30k chars) — file contents are too big; coder should use `Read` tool on demand instead of inlining.
- Slice for a verifier includes `events.jsonl` — wrong; verifiers don't read lead's event log.
- Slice for a coder includes other tasks' `build/task-*.jsonl` — scope leak.
- Missing `run.json` — ground-truth anchor stripped; re-add.

## Verification
After this skill returns:
- A single string has been produced, formatted with the sections specified per agent type above.
- For coder: includes `run.json`, one task, tail of that task's build log, and contents of `touch_files`.
- For mech: includes task, base branch, diff.
- For sem: includes task, diff, mech verdict, `requirement`.
- For pr: includes `run.json`, full `tasks.json`, full `verification.jsonl`, `git log <base>..HEAD`.
- For lead: includes `run.json`, `tasks.json`, `phase_state.json`, last 50 events, all blockers, all verifications.
- Nothing beyond the SPEC §3.6 allowances appears in the slice.
