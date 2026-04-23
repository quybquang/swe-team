---
name: swe-team:verify-semantic
description: Semantic verification of a swe-team commit — acceptance matching with file:line citations, scope audit against touch_files, adversarial logic review. Only runs after mech passes. Auto-loads for swe-verifier-sem in VERIFY phase.
---

# Verify Semantic

## Overview
Mech proves "tests pass, nothing was deleted." Sem proves "the change actually implements what the task says." The sem verifier (Sonnet) reads the diff, maps each acceptance bullet to evidence in the diff with `file:line` citations, and audits the scope — every changed file must be in `touch_files`. Invokes `swe-team:anti-rationalize` before finalizing the verdict to reject hedging language.

## When to Use
- `swe-verifier-sem` spawned after a mech verdict with `verified:true` for the same commit.
- Per-commit semantic pass (per-task, in BUILD→VERIFY cycle).
- Whole-PR sem sweep (different evidence shape — see SPEC §9.3; use `verification-schema.json#pr_gate`).

## When NOT to Use
- Mech tier returned `verified:false` — don't run sem; mech blocks first.
- You are mech, coder, lead, or PR — this skill is sem-only.
- The diff is empty — escalate to lead as blocker; no commit = nothing to verify.

## Process
1. Re-read anchors (sem scope, SPEC §3.6).
   ```bash
   TASK_ID="$TASK_ID_FROM_PROMPT"
   jq --arg tid "$TASK_ID" '.tasks[] | select(.id==$tid)' \
     .claude/swe-team/runs/current/tasks.json > /tmp/task.json
   BASE=$(jq -r .base_branch .claude/swe-team/runs/current/run.json)
   SHA=$(jq -r .last_commit_sha /tmp/task.json)
   # the mech verdict we depend on
   jq -c --arg tid "$TASK_ID" \
     'select(.task_id==$tid and .tier=="mech") | .' \
     .claude/swe-team/runs/current/verification.jsonl | tail -n 1
   ```
2. Compute the scope diff.
   ```bash
   CHANGED=$(git diff --name-only "$BASE".."$SHA")
   TOUCH=$(jq -r '.touch_files[]' /tmp/task.json)
   OUT_OF_SCOPE=$(comm -23 <(echo "$CHANGED" | sort) <(echo "$TOUCH" | sort))
   [ -z "$OUT_OF_SCOPE" ] && SCOPE_CLEAN=true || SCOPE_CLEAN=false
   ```
3. For each acceptance bullet (`A1`, `A2`, ...), read the diff and locate the exact `file:line` that satisfies it.
   ```bash
   git diff "$BASE".."$SHA" | less
   ```
   Build arrays `acceptance_met` and `acceptance_missing`. Citations go in the `reasoning` field and MUST be of the form `path/to/file.ts:42`.
4. Write the draft `reasoning` string (≤500 chars). Must include a citation for every entry in `acceptance_met`.
5. Invoke `swe-team:anti-rationalize` with the draft verdict. If it rejects, fix the reasoning and re-invoke. Max 2 retries.
6. Apply verdict rule (SPEC §9.2). `verified=true` iff:
   - `acceptance_missing == []`
   - `scope_diff_clean == true`
   - `reasoning_cites_evidence == true`
7. Emit the verification event.
   ```bash
   jq -nc \
     --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
     --arg ts "$(date -u +%FT%TZ)" \
     --arg tid "$TASK_ID" --argjson v $VERIFIED \
     --arg sha "$SHA" \
     --argjson met "$MET_JSON" --argjson miss "$MISS_JSON" \
     --argjson clean $SCOPE_CLEAN --argjson oos "$OOS_JSON" \
     --argjson cites $CITES --arg reasoning "$REASONING" \
     '{kind:"verification", ts:$ts, run_id:$rid, agent:"swe-verifier-sem",
       task_id:$tid, tier:"sem", verified:$v,
       evidence:{commit_sha:$sha, acceptance_met:$met, acceptance_missing:$miss,
                 scope_diff_clean:$clean, out_of_scope_files:$oos,
                 reasoning_cites_evidence:$cites, reasoning:$reasoning}}' \
     >> .claude/swe-team/runs/current/verification.jsonl
   ```

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "The acceptance is met because it's obvious from the diff." | Cite `file:line` or it did not happen. `reasoning_cites_evidence=false` fails the verdict. |
| "This file outside touch_files is just a formatter autofix." | Still out of scope. `scope_diff_clean=false`. Coder must emit a blocker, not silently expand scope. |
| "Acceptance A2 is close enough." | Binary: met or missing. "Close enough" is hedging; anti-rationalize will reject. |
| "The reasoning is 700 chars but it's all important." | Hard cap 500 chars. Summarize. |
| "Mech already passed, so sem is a formality." | Mech catches gaming; sem catches wrong solution. Do the work. |
| "I'll mark scope_diff_clean=true because the extra file is small." | Scope is binary. Out-of-scope files go in `out_of_scope_files`. |

## Red Flags
- `reasoning` contains "probably", "should work", "looks correct", "seems fine", "I think" — anti-rationalize will reject.
- Every acceptance cited with the same `file:line` — likely the coder only did one thing and you're over-counting.
- `out_of_scope_files` non-empty but coder did not emit a `blocker` — gaming.
- The mech verdict for this commit doesn't exist — don't invent one; escalate.
- Diff is enormous (>500 lines) for a task the plan sized `S` — plan/code mismatch; raise for re-plan.

## Verification
After this skill completes:
- One new line in `verification.jsonl` with `tier:"sem"` and all fields from `verification-schema.json#sem`.
- `evidence.reasoning` ≤500 chars and contains at least one `file:line` token per entry in `acceptance_met`.
- `evidence.reasoning_cites_evidence` is `true` only if anti-rationalize accepted.
- `scope_diff_clean` matches set math: `CHANGED ⊆ touch_files`.
- A prior mech verdict with the same `commit_sha` and `verified:true` exists.
