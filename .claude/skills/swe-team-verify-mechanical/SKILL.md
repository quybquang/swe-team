---
name: swe-team:verify-mechanical
description: Deterministic mechanical verification of a swe-team commit — runs tests, lint, typecheck, gaming-detection shell commands, and emits a verification event whose evidence matches verification-schema.json#mech. No LLM judgment.
---

# Verify Mechanical

## Overview
The mech tier is the first evidence gate after BUILD. It runs purely deterministic shell checks against the just-made commit. The agent (Haiku) does not judge — it executes, captures exit codes and hashes, and emits a verification event. `verified: true` only when every SPEC §9.1 rule passes. Gaming detection (deleted tests, new skips, assertion count regression) runs via the companion skill `swe-team:detect-gaming`.

## When to Use
- `swe-verifier-mech` has been spawned after a `swe-coder` commit.
- `phase_state.json.phase == "VERIFY"` with an active `task_id`.
- Retrying after the coder addressed a prior mech failure (same task, new commit SHA).

## When NOT to Use
- No new commit since the last mech verdict — you'd just re-emit the same evidence.
- The task is still `in_progress` with no commit — wait for the coder.
- You are a sem verifier, lead, coder, or PR agent — this skill is mech-only.

## Process
1. Re-read anchors (mech verifier scope, SPEC §3.6).
   ```bash
   TASK_ID="$TASK_ID_FROM_PROMPT"
   jq --arg tid "$TASK_ID" '.tasks[] | select(.id==$tid)' \
     .claude/swe-team/runs/current/tasks.json > /tmp/task.json
   COMMIT_SHA=$(git rev-parse HEAD)
   BASE=$(jq -r .base_branch .claude/swe-team/runs/current/run.json)
   ```
2. Load commands from config.
   ```bash
   TEST_CMD=$(jq -r .verification.test_cmd swe-team.config.json)
   LINT_CMD=$(jq -r .verification.lint_cmd swe-team.config.json)
   TC_CMD=$(jq -r .verification.typecheck_cmd swe-team.config.json)
   TEST_GLOBS=$(jq -r '.verification.test_globs | join(" ")' swe-team.config.json)
   ```
3. Run tests; hash stdout+stderr.
   ```bash
   OUT=$(eval "$TEST_CMD" 2>&1); TEST_EXIT=$?
   TEST_SHA="sha256:$(printf '%s' "$OUT" | shasum -a 256 | awk '{print $1}')"
   ```
4. Run lint and typecheck.
   ```bash
   eval "$LINT_CMD" >/dev/null 2>&1; LINT_EXIT=$?
   eval "$TC_CMD"   >/dev/null 2>&1; TC_EXIT=$?
   ```
5. Count assertions at HEAD and compare to baseline cached at run start.
   ```bash
   ASSERT_COUNT=$(git grep -nE '\b(expect|assert|should|require)\(' -- $TEST_GLOBS | wc -l)
   BASELINE=$(cat .claude/swe-team/runs/current/assertion_baseline.txt)
   ```
   If no baseline exists yet, compute it on `$BASE`:
   ```bash
   if [ ! -f .claude/swe-team/runs/current/assertion_baseline.txt ]; then
     git stash -u >/dev/null; git checkout "$BASE"
     git grep -nE '\b(expect|assert|should|require)\(' -- $TEST_GLOBS | wc -l \
       > .claude/swe-team/runs/current/assertion_baseline.txt
     git checkout - >/dev/null; git stash pop >/dev/null || true
     BASELINE=$(cat .claude/swe-team/runs/current/assertion_baseline.txt)
   fi
   ```
6. Invoke `swe-team:detect-gaming` to populate `deleted_test_files` and `new_skip_or_only_count`.
7. Apply verdict rule (SPEC §9.1). `verified=true` iff all of:
   - `test_exit == 0`, `lint_exit == 0`, `typecheck_exit == 0`
   - `len(deleted_test_files) == 0`
   - `new_skip_or_only_count == 0`
   - `assertion_count >= assertion_baseline`
8. Emit the verification event. Every `evidence` field is required by `verification-schema.json#mech`.
   ```bash
   jq -nc \
     --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
     --arg ts "$(date -u +%FT%TZ)" \
     --arg tid "$TASK_ID" \
     --argjson verified $VERIFIED \
     --arg sha "$COMMIT_SHA" \
     --argjson te $TEST_EXIT --arg tsha "$TEST_SHA" \
     --argjson ac $ASSERT_COUNT --argjson ab $BASELINE \
     --argjson del "$DELETED_JSON" --argjson skp $NEW_SKIP \
     --argjson le $LINT_EXIT --argjson tc $TC_EXIT \
     --arg reason "$REASON" \
     '{kind:"verification", ts:$ts, run_id:$rid, agent:"swe-verifier-mech",
       task_id:$tid, tier:"mech", verified:$verified,
       evidence:{commit_sha:$sha, test_exit:$te, test_output_sha256:$tsha,
                 assertion_count:$ac, assertion_baseline:$ab,
                 deleted_test_files:$del, new_skip_or_only_count:$skp,
                 lint_exit:$le, typecheck_exit:$tc, reason:$reason}}' \
     >> .claude/swe-team/runs/current/verification.jsonl
   ```
9. If `allow_flaky_retry` and `test_exit != 0`, retry up to 2 times before declaring fail; record `flaky_retries` in evidence.

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "The test already passed last run; I'll reuse the hash." | The commit SHA has changed. Re-run. Evidence is per-commit. |
| "Lint failure is just a warning; I'll mark verified." | Verdict rule requires `lint_exit == 0`. No warnings-as-errors bargaining. |
| "Assertion count dropped by 1 but it was a duplicate." | Baseline comparison is global; your theory about "duplicates" has no evidence field. Fail closed. |
| "Typecheck command errored out for env reasons." | Non-zero exit is non-zero exit. If the env is broken, that is a run-level infra issue — don't paper over it by returning verified. |
| "I'll skip gaming detection; the coder wouldn't do that." | Threat model §12 exists because LLMs do exactly that. Always run `detect-gaming`. |
| "The stdout is huge; I'll hash a prefix." | Full stdout+stderr. The hash's whole job is to detect any change. |

## Red Flags
- `test_output_sha256` identical across 3+ attempts for the same task → `identical_test_output` stuck signal; escalate.
- `assertion_count > baseline + 50` in one commit → possible test inflation to pad count; flag for sem review.
- Lint or typecheck command is empty/`skip` but SPEC says the repo supports it — fix the config, do not silently pass.
- `deleted_test_files` non-empty and coder has not emitted a blocker → gaming; fail hard.

## Verification
After this skill completes:
- One new line in `verification.jsonl` with `tier:"mech"` and all required fields from `verification-schema.json#mech`.
- Evidence includes non-null `commit_sha`, `test_output_sha256`, both counts, all three exit codes, both arrays.
- If `verified:false`, `evidence.reason` is a non-empty string naming the failing rule.
- `assertion_baseline.txt` exists in run dir.
