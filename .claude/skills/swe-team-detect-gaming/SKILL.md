---
name: swe-team:detect-gaming
description: Exact shell checks for test-gaming patterns — deleted test files, newly added .skip/.only/xit/xdescribe, assertion count regression. Invoked by swe-team:verify-mechanical to populate evidence fields.
---

# Detect Gaming

## Overview
LLM coders under pressure reach for the three classic shortcuts: delete a failing test, slap `.skip` on it, or soften the assertion. This skill runs deterministic shell queries to detect all three. It returns structured counts that the mech verifier embeds in its evidence object. There is no judgment — only shell.

## When to Use
- Invoked from inside `swe-team:verify-mechanical` as a sub-step.
- Any time a new mech verdict is being produced for a fresh commit.
- Also useful standalone when auditing a run post-hoc.

## When NOT to Use
- Outside of VERIFY phase — the base commit reference is only meaningful relative to the task's verification.
- Without a valid `base_branch` in `run.json` — you need a diff range.
- As a replacement for sem verification — it only catches mechanical gaming, not subtle logic softening.

## Process
1. Load the diff range and test globs.
   ```bash
   BASE=$(jq -r .base_branch .claude/swe-team/runs/current/run.json)
   TEST_GLOBS=$(jq -r '.verification.test_globs | join(" ")' swe-team.config.json)
   ```
2. List deleted test files between `$BASE` and `HEAD`.
   ```bash
   DELETED=$(git diff --name-only --diff-filter=D "$BASE"..HEAD -- $TEST_GLOBS)
   DELETED_JSON=$(printf '%s\n' "$DELETED" | jq -R . | jq -s 'map(select(length>0))')
   ```
3. Count newly added `.skip`, `.only`, `xit`, `xdescribe`, `test.skip`, `it.skip` inside test files.
   ```bash
   NEW_SKIP=$(git diff "$BASE"..HEAD -- $TEST_GLOBS \
     | grep -E '^\+' \
     | grep -vE '^\+\+\+ ' \
     | grep -cE '\.(skip|only)\b|\b(xit|xdescribe|test\.skip|it\.skip|describe\.skip|describe\.only)\b' \
     || true)
   ```
4. Establish or read the assertion baseline (one-time per run, cached).
   ```bash
   BASELINE_FILE=".claude/swe-team/runs/current/assertion_baseline.txt"
   if [ ! -f "$BASELINE_FILE" ]; then
     CUR=$(git rev-parse HEAD)
     git stash -u >/dev/null 2>&1 || true
     git checkout "$BASE" -- .
     git grep -nE '\b(expect|assert|should|require)\(' -- $TEST_GLOBS | wc -l \
       | tr -d ' ' > "$BASELINE_FILE"
     git checkout "$CUR" -- .
     git stash pop >/dev/null 2>&1 || true
   fi
   BASELINE=$(cat "$BASELINE_FILE")
   ```
5. Count assertions at HEAD.
   ```bash
   ASSERT_COUNT=$(git grep -nE '\b(expect|assert|should|require)\(' -- $TEST_GLOBS | wc -l | tr -d ' ')
   ```
6. Return the structured result for the mech verifier to embed:
   ```json
   {
     "deleted_test_files": ["..."],
     "new_skip_or_only_count": 0,
     "assertion_count": 47,
     "assertion_baseline": 45
   }
   ```
7. If any of the following fails, the mech verifier will mark `verified:false`; this skill never decides on its own:
   - `DELETED_JSON != []`
   - `NEW_SKIP > 0`
   - `ASSERT_COUNT < BASELINE`

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "Deleting a test is fine because it was obsolete." | Obsoleteness is an LLM theory. Mech fails closed. If truly obsolete, coder should emit a blocker and let the lead decide via re-plan. |
| "`.skip` is temporary." | "Temporary" has no evidence field. Count it. Fail the commit. |
| "Assertion count is lower because I refactored 3 tests into one." | Possible — but the mech tier cannot distinguish. It fails; sem tier can justify via citations. Not this skill's job. |
| "I can eyeball the diff faster than running grep." | Eyeballing is how gaming slips past. This skill's whole value is being mechanical. |
| "Baseline should be re-computed each verdict." | No. Baseline is per-run. Recomputing means an earlier deletion becomes invisible. |

## Red Flags
- `DELETED` non-empty — immediately a gaming signal.
- `NEW_SKIP > 0` with no corresponding `blocker` event explaining why.
- Assertion count oscillates across attempts (up, down, up) — coder is flailing.
- Baseline file is missing mid-run — someone deleted state; treat as infra failure, abort.

## Verification
After this skill returns its structured counts:
- `deleted_test_files` is a JSON array (possibly empty) of strings.
- `new_skip_or_only_count` is a non-negative integer.
- `assertion_count` and `assertion_baseline` are non-negative integers.
- `.claude/swe-team/runs/current/assertion_baseline.txt` exists.
- All four values are ready to populate the `verification-schema.json#mech` evidence fields `deleted_test_files`, `new_skip_or_only_count`, `assertion_count`, `assertion_baseline`.
