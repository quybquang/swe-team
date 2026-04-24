---
name: swe-team:retro
description: Post-run retrospective. Runs after swe-pr emits run_complete. Analyzes the completed run — budget efficiency, failure patterns, replan triggers, verification outcomes — and appends compact learnings to .claude/swe-team/learnings.jsonl. Future runs' swe-lead reads the last N learnings at startup.
---

# Retro

## Overview

`swe-team:retro` is the reflection gate at the end of every run. It reads the run's event log, verification records, budget expenditure, and git log, then distils 2–5 compact lessons into `.claude/swe-team/learnings.jsonl`. This is the mechanism by which the agent team improves across runs: each project session teaches the next.

Without retro, every run starts cold. With retro, swe-lead loads project-specific patterns ("clarify always needed for booking features", "mech fails on this stack until test env is seeded", "semantic verifier consistently flags missing null-guard in controllers") and adjusts planning and verification upfront.

The file `.claude/swe-team/learnings.jsonl` is **persistent** (not in `runs/` — it lives next to `config.json` and survives between runs). It is project-local and included in `.gitignore` by default.

## When to Use

- `run.json.status == "succeeded"` AND a `run_complete` event exists in `events.jsonl`.
- Also runs on `status == "failed"` or `"aborted"` — failures teach more than successes.
- `config.retro.enabled == true` (default: `true`).
- Called by swe-lead immediately after `swe-pr` returns.

## When NOT to Use

- `config.retro.enabled == false`.
- `run.json.status == "running"` — run is not yet terminal.
- A `retro_complete` event already exists in `events.jsonl` for this `run_id` (idempotent guard).
- The run was so early (aborted at CLARIFY or PLAN) that there is no BUILD or VERIFY data to learn from — skip retro silently.

## Process

1. Re-read the complete run record.
   ```bash
   cat .claude/swe-team/runs/current/run.json
   cat .claude/swe-team/runs/current/tasks.json
   cat .claude/swe-team/runs/current/events.jsonl
   cat .claude/swe-team/runs/current/verification.jsonl
   cat .claude/swe-team/runs/current/budget.json
   ```
2. Compute run metrics.
   ```bash
   # Total tasks
   TOTAL=$(jq '.tasks | length' .claude/swe-team/runs/current/tasks.json)
   DONE=$(jq '[.tasks[] | select(.status=="done")] | length' .claude/swe-team/runs/current/tasks.json)
   FAILED=$(jq '[.tasks[] | select(.status=="failed")] | length' .claude/swe-team/runs/current/tasks.json)

   # Replan count
   REPLANS=$(jq '[.[] | select(.kind=="replan")] | length' .claude/swe-team/runs/current/events.jsonl)

   # Mech failures
   MECH_FAILS=$(jq '[.[] | select(.kind=="verification" and .tier=="mech" and .verified==false)] | length' .claude/swe-team/runs/current/verification.jsonl)

   # Budget used
   TOKENS=$(jq .tokens_used .claude/swe-team/runs/current/budget.json)
   USD=$(jq .usd_used .claude/swe-team/runs/current/budget.json)
   ```
3. Identify the top failure patterns. For each `replan` event, extract `.reason`. For each `verification` with `verified:false`, extract `.evidence.reason`. Group by theme.
4. Identify what worked well. For tasks that reached `done` in ≤1 iteration and passed mech+sem first try, note what made them clean (small size, specific acceptance, familiar file domain).
5. Read `.claude/swe-team/learnings.jsonl` to check for duplicates. Do not write a learning that duplicates one already recorded for the same project (same lesson text or same root cause).
   ```bash
   LEARNINGS_FILE=".claude/swe-team/learnings.jsonl"
   [ -f "$LEARNINGS_FILE" ] && cat "$LEARNINGS_FILE" || echo "[]"
   ```
6. Draft 2–5 learnings. Each learning must:
   - Be specific to THIS project/codebase, not generic ("always add types" is generic; "this repo's controllers require explicit null-guard on `req.params.id` — mech fails without it" is specific).
   - Carry a `scope` tag: `planning` | `verification` | `requirement` | `build`.
   - Carry an `evidence_run_id` linking back to this run.
   - Be actionable: swe-lead must be able to read it and change a decision.
7. Append each learning to `learnings.jsonl`:
   ```bash
   LEARNINGS_FILE=".claude/swe-team/learnings.jsonl"
   touch "$LEARNINGS_FILE"
   jq -nc \
     --arg rid "$RUN_ID" \
     --arg ts "$(date -u +%FT%TZ)" \
     --arg scope "planning" \
     --arg lesson "<lesson text>" \
     --arg evidence_run_id "$RUN_ID" \
     '{kind:"learning",ts:$ts,evidence_run_id:$evidence_run_id,scope:$scope,lesson:$lesson}' \
     >> "$LEARNINGS_FILE"
   ```
8. Emit `retro_complete` event:
   ```bash
   jq -nc \
     --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
     --argjson total $TOTAL --argjson done $DONE \
     --argjson replans $REPLANS --argjson mech_fails $MECH_FAILS \
     --argjson lessons $(jq 'length' "$LEARNINGS_FILE") \
     '{kind:"retro_complete",ts:$ts,run_id:$rid,agent:"swe-lead",
       metrics:{tasks_total:$total,tasks_done:$done,replans:$replans,mech_fails:$mech_fails},
       lessons_written:$lessons}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```

## How swe-lead Reads Learnings at Startup

At the start of every run, swe-lead reads the most recent N=10 learnings:

```bash
LEARNINGS_FILE=".claude/swe-team/learnings.jsonl"
if [ -f "$LEARNINGS_FILE" ]; then
  tail -10 "$LEARNINGS_FILE" | jq -r '"[learning] " + .scope + ": " + .lesson'
fi
```

These are injected into swe-lead's context as `[learning]`-prefixed lines before CLARIFY. swe-lead MUST reference relevant learnings when creating the plan (`tasks.json` descriptions may cite `[learning: <scope>]`).

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "This was a clean run; nothing to learn." | Even a clean run teaches which task sizes were accurate, which file domains were faster, what the budget efficiency was. Write ≥1 metric-based lesson. |
| "I'll summarize generic best practices." | Generic lessons don't help future runs. If the lesson applies to any repo, don't write it. Write only what's specific to this codebase. |
| "The learnings file is getting long; I'll skip writing." | The file is append-only; swe-lead only reads the last N=10. Length is irrelevant. |
| "The run failed so there's nothing positive to note." | Failed runs produce the richest learnings — what caused the blocker, why the replan didn't fix it. Write the failure pattern explicitly. |
| "I'll duplicate a learning from last run because it's still relevant." | Duplication wastes the N=10 window. Check for existing lessons in step 5. Update or reference the existing entry instead. |

## Red Flags

- `learnings.jsonl` contains >50 entries and all are from the same `run_id` — the retro is looping or misfiring.
- A learning says "ensure X" without citing the specific file/pattern where X was violated — too vague; rewrite.
- `retro_complete` event emitted but no new lines added to `learnings.jsonl` — they must be written together.
- A learning for scope `requirement` that blames the user ("user gave bad requirements") — reframe as an actionable pattern ("requirements without acceptance criteria → add `--clarify` flag").

## Verification

After this skill completes:
- `.claude/swe-team/learnings.jsonl` has ≥1 new line with `kind:"learning"` and `evidence_run_id` matching this run.
- `events.jsonl` contains `{kind:"retro_complete"}` with `lessons_written ≥ 1`.
- No learning in the file duplicates an existing one for the same `lesson` text.
- Every learning has non-empty `scope` and `lesson` fields.
