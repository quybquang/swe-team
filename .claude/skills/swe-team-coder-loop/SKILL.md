---
name: swe-team:coder-loop
description: Per-task edit-test-commit loop for swe-coder. Implements exactly one task from tasks.json, produces exactly one commit on files listed in touch_files, and emits action/observation events. Auto-loads when swe-coder spawns during BUILD.
---

# Coder Loop

## Overview
One `swe-coder` spawn = one task = one commit. This skill enforces that contract. It loads a single task from `tasks.json`, reads only the files in `touch_files`, writes the minimum change needed to satisfy acceptance, runs a local test subset, and commits. If blocked, it emits a `blocker` event instead of guessing. Iteration caps (S=2, M=4, L=6) are hard — exceeding them marks the task failed.

## When to Use
- `swe-coder` has just been spawned by `swe-lead` with a specific `task_id` in the prompt.
- `phase_state.json.phase == "BUILD"` and `phase_state.active_task == T_i`.
- Coming back to retry a task after a verifier failure — increment iteration count, do not start fresh.

## When NOT to Use
- You are `swe-lead`, `swe-verifier-*`, or `swe-pr` — you will never spawn as a coder.
- Multiple `task_id`s are in scope — spawn one coder per task; this skill owns one and only one.
- The task's `depends_on` contains a task with `status != done` — escalate to lead; do not run.

## Process
1. Re-read anchors. Coder-scoped reads only (SPEC §3.6).
   ```bash
   cat .claude/swe-team/runs/current/run.json
   jq --arg tid "$TASK_ID" '.tasks[] | select(.id==$tid)' \
     .claude/swe-team/runs/current/tasks.json > /tmp/my-task.json
   cat /tmp/my-task.json
   BUILD_LOG=".claude/swe-team/runs/current/build/task-${TASK_ID}.jsonl"
   [ -f "$BUILD_LOG" ] && tail -n 50 "$BUILD_LOG"
   ```
2. Check iteration count against cap.
   ```bash
   ITER=$(jq -r '.iteration_count // 0' /tmp/my-task.json)
   SIZE=$(jq -r .size /tmp/my-task.json)
   case "$SIZE" in S) CAP=2 ;; M) CAP=4 ;; L) CAP=6 ;; esac
   [ "$ITER" -ge "$CAP" ] && { echo "iter cap hit"; exit 1; }
   ```
3. Read each file in `touch_files` with the Read tool. Do not read anything else (scope discipline).
4. Emit an `action` event before each edit.
   ```bash
   RUN_ID=$(jq -r .run_id .claude/swe-team/runs/current/run.json)
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" --arg tid "$TASK_ID" --arg f "$FILE" \
     '{kind:"action", ts:$ts, run_id:$rid, agent:"swe-coder", task_id:$tid, tool:"Edit", target:$f}' \
     >> "$BUILD_LOG"
   ```
5. Implement the change. Rules:
   - Only edit files in `touch_files`.
   - Do not delete tests.
   - Do not add `.skip` / `.only` / `xit` / `xdescribe` to existing tests.
   - If logic requires a file NOT in `touch_files`, stop and emit `blocker`.
6. Run the test subset that covers this task. Capture the hash.
   ```bash
   TEST_CMD=$(jq -r .verification.test_cmd swe-team.config.json)
   OUT=$(eval "$TEST_CMD" 2>&1); EXIT=$?
   SHA="sha256:$(printf '%s' "$OUT" | shasum -a 256 | awk '{print $1}')"
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" --arg tid "$TASK_ID" \
          --argjson ec $EXIT --arg sha "$SHA" \
     '{kind:"observation", ts:$ts, run_id:$rid, agent:"swe-coder", task_id:$tid,
       tool:"Bash", exit_code:$ec, stdout_sha256:$sha, summary:"test subset"}' \
     >> "$BUILD_LOG"
   ```
7. Stage only `touch_files`, then commit.
   ```bash
   git add -- $(jq -r '.touch_files[]' /tmp/my-task.json)
   git diff --cached --name-only | while read f; do
     jq --arg f "$f" '.touch_files | index($f)' /tmp/my-task.json | grep -q '^null$' && \
       { echo "out-of-scope staged: $f"; git reset -- "$f"; }
   done
   git commit -m "$(jq -r '.title' /tmp/my-task.json) [${TASK_ID}]"
   ```
8. If blocked at any step, emit `blocker` and exit cleanly — do not loop.
   ```bash
   jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" --arg tid "$TASK_ID" \
          --arg r "$REASON" --arg p "$PROPOSAL" \
     '{kind:"blocker", ts:$ts, run_id:$rid, agent:"swe-coder", task_id:$tid,
       reason:$r, proposed_resolution:$p}' \
     >> "$BUILD_LOG"
   ```

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "I need to edit one file outside touch_files, just briefly." | No. Emit a `blocker`. swe-lead decides via re-plan. Scope creep is a mech+sem fail. |
| "The failing test is flaky; let me re-run it three times." | Flaky retry is the verifier's call, not yours. Commit with honest results; let mech verify. |
| "I'll delete this old test; it's unrelated." | `deleted_test_files` must be `[]`. Mech verifier will fail you. |
| "git add -A is faster than listing touch_files." | `-A` can stage generated/config files that aren't yours. Step 7's per-file filter is required. |
| "Last iteration's work was fine; I'll ship it again." | If the prior iteration failed verification, the same commit will fail again (stdout_sha256 match = `stuck`). Change the code. |
| "Iteration cap is a guideline; one more try." | Cap is a hard gate; exit 1 and let lead decide. |

## Red Flags
- You edited a file not in `touch_files` — revert immediately.
- `git status` shows untracked files you didn't create for this task.
- Your test subset passed but the assertion count dropped — you probably weakened a test.
- Three iterations in and stdout_sha256 hasn't changed — this is `identical_test_output` stuck pattern.
- You're about to add `// eslint-disable` or `@ts-ignore` — stop; emit a `blocker`.

## Verification
After this skill completes:
- Exactly one new commit on the current branch, referencing this task's `id` in the message.
- `git diff --name-only HEAD~1..HEAD` ⊆ `task.touch_files`.
- `build/task-<task_id>.jsonl` contains at least one `action` and one `observation` event conforming to `event-schema.json`.
- `tasks.json[T_i].iteration_count` has been incremented.
- `tasks.json[T_i].last_commit_sha` set to the new commit SHA.
- OR a single `blocker` event is present and no commit was made.
