---
name: swe-team:clarify
description: Pre-flight requirement clarification. Runs before DEFINE phase to surface ambiguities, missing scope, and unstated constraints. Produces pre-flight-brief.md that DEFINE and PLAN consume. Two modes — interactive (user present) and autonomous (assumptions only).
---

# Clarify

## Overview

`swe-team:clarify` is the first gate in a run. It converts a raw user requirement into a clarified brief before any spec-writing or task decomposition begins. Unlike `swe-team:define-spec` (which expands a requirement into structured acceptance criteria), `clarify` surfaces gaps that are **unknowable from the repo alone** — business intent, priority tradeoffs, out-of-scope decisions, and ambiguous pronouns. A good pre-flight brief eliminates 80% of replans caused by misunderstood scope.

Two operating modes:

- **Interactive** (`mode: "interactive"`): swe-lead presents 3–5 focused questions to the user and waits for replies before proceeding. Use when a human is at the terminal (detected by `--interactive` flag or absence of `--autonomous` flag).
- **Autonomous** (`mode: "autonomous"`): swe-lead makes explicit assumptions and writes them to `assumptions.md`. No user interaction. Use when running unattended.

Output in both modes: `pre-flight-brief.md` in the run directory. DEFINE reads this file; if absent, DEFINE falls back to the raw requirement (no error).

## When to Use

- A new run has been initialized (`run.json` exists, phase is `PRE-DEFINE`).
- `config.clarify.enabled == true` (default: `true`).
- The requirement contains ANY of: pronouns without clear referents ("it", "this", "the feature"), comparative adjectives ("better", "faster", "cleaner"), missing actors ("user can…" — which user role?), or no success criterion.
- The requirement is a URL and the fetched content lacks acceptance criteria.
- User has passed `--clarify` flag explicitly.

## When NOT to Use

- `config.clarify.enabled == false`.
- Requirement already has explicit acceptance criteria (numbered list or bullet `[ ]` checkboxes) — the brief already exists in the requirement.
- You are NOT in `PRE-DEFINE` phase.
- A `pre-flight-brief.md` already exists in the run dir from a previous clarify pass (idempotent guard).
- The requirement is a single-action command on a specific named file (e.g. "rename `foo` to `bar` in `src/utils.ts`") — unambiguous; skip.

## Process

### Shared (both modes)

1. Re-read anchors.
   ```bash
   cat .claude/swe-team/runs/current/run.json
   ```
2. Extract the raw requirement text (or fetched content if URL).
3. Score ambiguity per SPEC §5.1. Record the score.
4. Grep the repo for referents. For every noun in the requirement, confirm it exists in the codebase:
   ```bash
   grep -r "<noun>" --include="*.ts" --include="*.tsx" --include="*.py" --include="*.go" -l 2>/dev/null | head -5
   ```
5. Identify the minimum set of questions whose answers would let DEFINE produce unambiguous acceptance bullets. Cap at 5. Questions must be answerable in 1–2 sentences.
6. Emit `phase_enter` for `CLARIFY`:
   ```bash
   RUN_ID=$(jq -r .run_id .claude/swe-team/runs/current/run.json)
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
     '{kind:"phase_enter",ts:$ts,run_id:$rid,agent:"swe-lead",phase:"CLARIFY"}' \
     >> .claude/swe-team/runs/current/events.jsonl
   ```

### Interactive mode

7. Present questions to the user as a numbered list. Label the session:
   ```
   swe-team needs 3 quick clarifications before planning:

   1. <question>
   2. <question>
   3. <question>

   (Reply with numbered answers, or type SKIP to proceed with autonomous assumptions.)
   ```
8. Wait for user reply. If user replies `SKIP`, switch to autonomous mode.
9. Parse user answers. Map each answer to the question it resolves. Store in `clarify_qa` structure.
10. If any answer reveals that the requirement is fundamentally infeasible (e.g. "the API doesn't exist yet"), emit `run_abort` with `reason: "requirement_infeasible — <detail>"` and stop.

### Autonomous mode

7. For each question identified in step 5, write a best-effort assumption based on:
   - Existing code patterns (e.g. if auth uses JWT, assume new features follow JWT pattern).
   - The repo's dominant conventions (detected via grep).
   - Conservative interpretation (smallest valid scope, not largest).
8. Document each assumption with the evidence that justified it.

### Write output (both modes)

9. Write `pre-flight-brief.md`:
   ```markdown
   # Pre-flight Brief

   **Run**: <run_id>
   **Mode**: interactive | autonomous
   **Ambiguity score**: <n>

   ## Clarified Requirement
   <1–3 sentence restatement that resolves all pronouns and adds actors>

   ## Key Decisions
   | Question | Answer / Assumption | Source |
   |---|---|---|
   | <question> | <answer> | user / repo-grep / convention |

   ## Explicit Out of Scope
   - <item confirmed out of scope>

   ## Constraints Surfaced
   - <constraint, e.g. "must not break existing /api/v1 endpoints">
   ```
10. Emit `phase_exit` for `CLARIFY`:
    ```bash
    jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
      '{kind:"phase_exit",ts:$ts,run_id:$rid,agent:"swe-lead",phase:"CLARIFY",ok:true}' \
      >> .claude/swe-team/runs/current/events.jsonl
    ```
11. Set `phase_state.json.phase = "DEFINE"` (or `PLAN` if ambiguity score < 3 and DEFINE would be skipped).

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "I can infer the intent from context — no questions needed." | If you can infer it, write it as an assumption in autonomous mode with the evidence. Inference without documentation is a hallucination risk. |
| "Asking questions slows things down." | A misunderstood requirement costs a full replan cycle (typically 2–4× the budget of one clarify round). |
| "The user said 'just do it' so I'll skip clarify." | Autonomous mode was designed for exactly this. Don't skip — switch modes. |
| "I'll ask 10 questions to be thorough." | Cap is 5. More than 5 means the requirement needs to be split, not clarified — emit `needs_split` instead. |
| "I'll treat every question as high-priority and block on all of them." | Questions about implementation details (which file to touch) are NOT clarify questions — they're PLAN details. Only ask about scope, actors, and constraints. |

## Red Flags

- More than 5 questions generated → requirement is under-specified; consider `run_abort` with `reason: "requirement_too_vague"` and ask user to provide a Linear/GitHub ticket.
- A question reveals the requirement conflicts with an existing system (e.g. "must replace X" but X is used in 30 files) → flag as high-complexity; bump plan size estimate.
- User's `SKIP` in interactive mode → note in brief as "autonomous assumptions used"; DEFINE and PLAN inherit higher uncertainty.
- `pre-flight-brief.md` written but `Key Decisions` table is empty → the skill ran but found nothing to clarify; valid only if ambiguity score was 0.

## Verification

After this skill completes:
- `.claude/swe-team/runs/current/pre-flight-brief.md` exists with all 5 required sections.
- `events.jsonl` contains a matched `{kind:"phase_enter", phase:"CLARIFY"}` then `{kind:"phase_exit", phase:"CLARIFY", ok:true}`.
- `phase_state.json.phase` is `DEFINE` or `PLAN` (not `CLARIFY`).
- No unresolved pronouns remain in `pre-flight-brief.md § Clarified Requirement`.
- If mode was `interactive`, at least one answer came from the user (not assumption).
