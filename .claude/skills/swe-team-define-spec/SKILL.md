---
name: swe-team:define-spec
description: Expand an ambiguous requirement into a structured spec with acceptance bullets and file hints. Auto-loads during the DEFINE phase of a swe-team run when the requirement's ambiguity score is at or above the threshold.
---

# Define Spec

## Overview
The DEFINE phase turns a vague user requirement (e.g. "make it dark mode friendly") into a structured spec that the PLAN phase can decompose deterministically. This skill runs only when the ambiguity score (SPEC §5.1) is ≥ 3, or when the user passes `--define`. Output is a `spec.md` file in the run directory plus `phase_enter`/`phase_exit` events in `events.jsonl` and a human-readable acceptance list. Without this skill, under-specified requirements cascade into bad plans, which cascade into gaming the verifier. This is the first evidence gate.

## When to Use
- `swe-lead` is at the start of a run and `phase_state.json.phase == "DEFINE"`.
- Ambiguity score ≥ 3: requirement < 80 chars, or no action verb, or no concrete noun, or fetched URL body < 200 chars.
- User passed `/swe-team --define` (force).
- A `blocker` event reports `reason: spec_gap` and re-plan needs a clarified requirement slice.

## When NOT to Use
- Ambiguity score < 3 and `force_define == false` — skip DEFINE and go straight to PLAN.
- `config.phases.skip_define == true`.
- The requirement is a URL whose fetched body is already long and well-structured (ticket with acceptance criteria) — treat it as the spec.
- You are in BUILD, VERIFY, or SHIP — DEFINE cannot run mid-flight.

## Process
1. Re-read the anchor files (ground-truth rule, SPEC §3.5).
   ```bash
   cat .claude/swe-team/runs/current/run.json
   cat .claude/swe-team/runs/current/phase_state.json
   ```
2. Emit the phase-enter event.
   ```bash
   RUN_ID=$(jq -r .run_id .claude/swe-team/runs/current/run.json)
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
     '{kind:"phase_enter", ts:$ts, run_id:$rid, agent:"swe-lead", phase:"DEFINE"}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```
3. Compute the ambiguity score from `run.json.requirement.text` (or `.fetched_content`). Record the raw score as a number — do not hand-wave.
4. Draft `spec.md` in the run dir. It MUST contain these sections:
   - `## Summary` — one paragraph restating intent.
   - `## Acceptance` — numbered list, each bullet independently testable.
   - `## File Hints` — probable files/dirs (grep the repo; do not fabricate paths).
   - `## Out of Scope` — explicit exclusions.
   - `## Open Questions` — at most 3; each must be answerable from the repo alone, not the user.
5. Grep-validate every `File Hints` entry.
   ```bash
   while read f; do
     [ -e "$f" ] || echo "MISSING: $f"
   done < <(grep -oE '[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|py|go|md)' .claude/swe-team/runs/current/spec.md)
   ```
   Any `MISSING:` line fails the skill — remove the path from `spec.md` before proceeding.
6. Emit phase-exit.
   ```bash
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
     '{kind:"phase_exit", ts:$ts, run_id:$rid, agent:"swe-lead", phase:"DEFINE", ok:true}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "The requirement is clear enough to me." | Ambiguity is computed mechanically (score ≥ 3) — your opinion does not override the score. |
| "I'll write acceptance as I go in PLAN." | PLAN requires ≥1 acceptance per task. Without a spec-level acceptance set, task-level acceptance is invented on the fly and drifts from intent. Write them now. |
| "File hints are just guesses — I'll skip grep validation." | Unvalidated file hints hallucinate paths. Step 5 is a hard gate. |
| "Open Questions can include things only the user can answer." | The user is not in the loop. Any question not answerable from the repo is a `run_abort`, not a DEFINE output. |
| "I'll just copy the requirement text into spec.md." | Summary ≠ copy-paste. If your Summary is identical to the requirement, DEFINE added nothing and you should have skipped. |

## Red Flags
- Ambiguity score ≥ 5 AND fetched URL body is empty — consider `run_abort` with `reason: requirement_not_fetchable` instead of guessing.
- More than 3 Open Questions — the requirement is not ready; abort and tell the user.
- File hints include paths that don't exist after grep check.
- Acceptance bullets contain subjective adjectives ("better", "nicer", "cleaner") with no measurable criterion.

## Verification
After this skill completes:
- `.claude/swe-team/runs/current/spec.md` exists and has the 5 required sections.
- `events.jsonl` contains a matched pair: `{kind:"phase_enter", phase:"DEFINE"}` then `{kind:"phase_exit", phase:"DEFINE", ok:true}` per `event-schema.json`.
- Every acceptance bullet is independently testable (no compound "and" joins hiding two criteria).
- `phase_state.json.phase` has been advanced to `PLAN`.
- No `MISSING:` paths remain in `spec.md`.
