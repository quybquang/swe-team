---
name: swe-team:decompose-tasks
description: Produce a tasks.json for the PLAN phase that validates against tasks-schema.json and enforces size gates (max 10 files/task, 15 tasks/run, 500 LOC estimate). Auto-loads when swe-lead enters PLAN.
---

# Decompose Tasks

## Overview
Turns the requirement (and optional `spec.md` from DEFINE) into an authoritative `tasks.json`. Each task produces exactly one commit and is verifiable in isolation. Gates are strict: overshooting any limit yields `status=needs_split` and halts the run instead of producing a bad plan. A bad plan is the single biggest cause of gaming downstream, so this skill fails closed.

## When to Use
- `swe-lead` has entered PLAN (`phase_state.json.phase == "PLAN"`).
- `tasks.json` does not yet exist for this run, OR `version == 1` and needs the initial write.
- Immediately after a successful DEFINE exit.

## When NOT to Use
- A `tasks.json` already exists and the intent is to add tasks — use `swe-team:replan` instead (append-only).
- You are inside BUILD and just hit a blocker — that is also `swe-team:replan`.
- You want to rewrite existing tasks — forbidden; re-plan is append-only.

## Process
1. Re-read anchors.
   ```bash
   cat .claude/swe-team/runs/current/run.json
   [ -f .claude/swe-team/runs/current/spec.md ] && cat .claude/swe-team/runs/current/spec.md
   cat swe-team.config.json
   ```
2. Emit `phase_enter`.
   ```bash
   RUN_ID=$(jq -r .run_id .claude/swe-team/runs/current/run.json)
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
     '{kind:"phase_enter", ts:$ts, run_id:$rid, agent:"swe-lead", phase:"PLAN"}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```
3. Draft the task list. For each task, populate every required field from `tasks-schema.json`:
   - `id`: `T1`, `T2`, ...
   - `title`: ≤120 chars, imperative verb.
   - `description`: enough context that a coder reading this alone understands the change.
   - `size`: `S` / `M` / `L` per LOC estimate (S≤50, M≤150, L≤400).
   - `touch_files`: 1–10 entries; each must exist in the repo OR be a new file under an existing directory.
   - `acceptance`: ≥1 string, each independently testable.
   - `status`: `pending`.
   - `depends_on`: task IDs only; must form a DAG.
4. Validate `touch_files` against the repo.
   ```bash
   for f in $TOUCH_FILES; do
     parent=$(dirname "$f")
     [ -e "$f" ] || [ -d "$parent" ] || { echo "BAD touch_file: $f"; exit 1; }
   done
   ```
5. Enforce size gates from `swe-team.config.json.limits`:
   - `len(tasks) ≤ max_plan_tasks` (default 15).
   - Each `task.touch_files` length ≤ `max_files_per_task` (default 10).
   - Sum of size-bucket LOC estimates ≤ `max_plan_loc` (default 500). S=50, M=150, L=400.
   - If any gate fails: write `suggested-breakdown.md` describing how to split, set `run.json.status = "needs_split"`, emit `phase_exit ok:false`, and exit.
6. Write `tasks.json` with `version: 1`. Validate against the schema.
   ```bash
   cat .claude/swe-team/runs/current/tasks.json | jq . >/dev/null  # syntactic
   # optionally: ajv validate -s .claude/references/tasks-schema.json -d tasks.json
   ```
7. Emit `phase_exit`.
   ```bash
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
     '{kind:"phase_exit", ts:$ts, run_id:$rid, agent:"swe-lead", phase:"PLAN", ok:true}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "I'll add acceptance bullets later when I know more." | Schema requires `acceptance.minItems: 1`. A task without acceptance is unverifiable and will be gamed. Write them now. |
| "This task touches 12 files but they're all small." | `max_files_per_task` is 10. Split it. The gate exists because scope sprawl is the #1 verifier-evasion pattern. |
| "The total plan is 520 LOC but close enough to 500." | The gate is a hard `>`. Emit `needs_split`. The user will decide, not you. |
| "I'll reuse T3 and change its description." | Rewriting is forbidden (re-plan is append-only). On first PLAN this is legal, but on any subsequent change you must create T_{n+1}. |
| "touch_files can include paths I'll create later." | Yes, but the parent directory must exist. A path under a non-existent directory is a fabrication. |
| "depends_on forms a cycle but it's fine." | Cycles deadlock BUILD. Fix the DAG. |

## Red Flags
- A task's `acceptance` bullet begins with "Tests pass" or "Code works" — these are tautologies, not acceptance.
- Two tasks list the same file in `touch_files` — cross-task conflict risk.
- A single `L` task whose removal would put the plan under 500 LOC — split it; L is a smell in MVP.
- `depends_on` chain of length > 3 — likely over-decomposed.
- Task title and description are identical — no useful information.

## Verification
After this skill completes:
- `.claude/swe-team/runs/current/tasks.json` exists, `version: 1`, validates against `tasks-schema.json`.
- Every task has `acceptance.length >= 1`, `touch_files.length <= 10`, required fields populated.
- `len(tasks) <= config.limits.max_plan_tasks`.
- Sum of estimated LOC ≤ `config.limits.max_plan_loc`.
- `events.jsonl` has matched `phase_enter`/`phase_exit` for PLAN.
- If gates failed: `run.json.status == "needs_split"` and `suggested-breakdown.md` exists in run dir.
