# Anti-Patterns — Catalog of Failure Modes

> Each entry: symptom, why it happens, how swe-team detects or prevents it. Cite SPEC section or hook where relevant.

---

## Test Deletion Gaming

**Symptom**: Test suite "passes" because failing tests were removed.

**Why it happens**: Under iteration pressure, an LLM interprets "make tests pass" as "ensure the test runner exits 0," not "satisfy the assertions."

**Prevention**: Mech verifier (SPEC §9.1) requires `deleted_test_files == []`, computed as `git diff --diff-filter=D` on test globs. Non-empty list → `verified: false, reason: "tests deleted"`.

---

## `.skip` / `.only` Injection

**Symptom**: Tests appear to pass, but one or more are marked `.skip`, `xit`, `xdescribe`, or fenced with `.only`.

**Why it happens**: Same root cause as deletion — the LLM finds the cheapest path to a green exit.

**Prevention**: Mech verifier requires `new_skip_or_only_count == 0` in the diff (SPEC §9.1). Grep-based check in `swe-team:detect-gaming` skill. Any new `.skip|.only|xit|xdescribe` = verdict fail.

---

## Weakened Assertions

**Symptom**: Tests "pass" but assertions were loosened (`toBe(x)` → `toBeDefined()`, removed lines within a `it()` block).

**Why it happens**: An LLM minimizes the change to reach green. Replacing an assertion it can't satisfy is the shortest patch.

**Prevention**: `assertion_count >= assertion_baseline` across the run (SPEC §9.1). Baseline is captured at run start. Net decrease anywhere → verdict fail. Counts via `grep -rE '\b(expect|assert|should|require)\b'`.

---

## Hallucinated Completion

**Symptom**: Agent claims "I implemented the feature and all tests pass," but no commit exists, or tests were not actually run.

**Why it happens**: LLMs sometimes narrate completion as a completion. Context window contains the *intent*, not the action.

**Prevention**: SPEC §3.5 ground-truth rule. A claim is valid only if an accompanying `verification` event exists with `verified: true` and `commit_sha`. `phase-exit-verify.sh` (SPEC §7.2) blocks VERIFY phase exit if any task lacks both mech+sem verified events.

---

## Scope Creep ("While I'm Here…")

**Symptom**: Commit touches files outside `touch_files`: formatting changes, adjacent refactors, "cleanups" unrelated to the task.

**Why it happens**: LLMs want to be helpful. Addyosmani's incremental-implementation skill names this: "If you notice something worth improving outside your task scope, note it — don't fix it" (research §1 pattern 3).

**Prevention**: Sem verifier `scope_diff_clean` field (SPEC §9.2). Any file in the commit's diff not in `tasks.json[T_i].touch_files` → `out_of_scope_files` populated → verdict fail. Coder-loop skill instructs Rule 0.5: Scope Discipline (adopted from addyosmani).

---

## Infinite / Near-Infinite Loop

**Symptom**: Agent makes the same edit repeatedly; test output sha is identical across attempts; nothing progresses.

**Why it happens**: The LLM can't find a fix, re-tries the same approach, no learning between attempts.

**Prevention**: Stuck detection (SPEC §8):
- 2 consecutive identical commit diffs → `stuck` event → abort task
- 3 consecutive identical `stdout_sha256` → `stuck` → abort
- `swe-team:detect-stuck` skill (invoked by `track-file-edit.sh` and `capture-test-output.sh` hooks)

---

## Context Rot

**Symptom**: Over many turns, agent starts contradicting earlier conclusions, forgets constraints, or repeats already-rejected approaches.

**Why it happens**: Context window accumulates noise. Earlier high-signal content is pushed out by low-signal retries.

**Prevention**: SPEC §3.5 + §3.6: agents re-read structured state files on every turn rather than trusting in-window memory. Per-agent context slicing bounds input size. `swe-team-context-prime` skill reassembles a compact brief for each agent spawn.

---

## Hedging Language in Verdicts

**Symptom**: Verifier writes "probably passes," "should work," "looks correct" — no concrete evidence.

**Why it happens**: LLMs default to politeness. Uncertainty gets smoothed into "should."

**Prevention**: `swe-team:anti-rationalize` skill (SPEC §9.4). Explicit rejection of hedging tokens (`probably`, `should work`, `looks correct`, `seems fine`, `I think`) unless accompanied by evidence fields. Rejected verdict forces re-run with stricter grounding.

---

## Premature Abstraction

**Symptom**: Coder introduces a generic utility, config knob, or abstraction layer the task didn't ask for.

**Why it happens**: Pattern-matching from training data: "production code has abstractions." LLMs optimize for code that looks mature.

**Prevention**: Scope check in sem verifier (§9.2). `acceptance_met` requires matching specific acceptance bullets; abstractions that satisfy no bullet are out-of-scope. Coder-loop skill explicitly: "Satisfy the acceptance list verbatim; no more, no less."

---

## Replan Thrashing

**Symptom**: Plan is re-written many times; task list churns without progress.

**Why it happens**: Lead conflates "task is hard" with "plan is wrong" and responds with re-plan instead of iteration.

**Prevention**: SPEC §5.2 — re-plan is append-only (never rewrite/delete existing tasks), versioned, capped at 2 per run. `phase_state.replan_count > 2` → abort (`failed`). `swe-team:replan` skill enforces append-only discipline.

---

## File Churn

**Symptom**: Same file edited 5+ times within one task. Each edit "fixes" something the previous edit broke.

**Why it happens**: The LLM is not converging; each patch creates a new issue it then tries to patch.

**Prevention**: `track-file-edit.sh` hook tallies edits per file per task; >5 edits triggers `stuck` event (SPEC §8). Lead receives the event and decides: continue, re-plan, or abort.

---

## Identical-Output Stuck

**Symptom**: Test output hash unchanged across 3 attempts; lint output unchanged; typecheck unchanged. No signal of learning.

**Why it happens**: The LLM is in a local minimum and cannot see a new approach.

**Prevention**: `capture-test-output.sh` stores `stdout_sha256`. `detect-stuck` skill compares across attempts in `build/task-<id>.jsonl`. 3 identical = `stuck` → task abort.

---

## Evidence-Free Verdict

**Symptom**: Verification event exists but evidence fields are empty, partial, or generic ("tests passed").

**Why it happens**: LLM treats the evidence schema as optional documentation rather than a contract.

**Prevention**: Schema validation (`.claude/references/verification-schema.json`) enforced by `phase-exit-verify.sh`. Missing required fields → hook exit 2 → phase cannot close. SPEC §9.1 and §9.2 enumerate required fields; any missing → verdict is rejected.

---

## Secrets in Commits

**Symptom**: `.env`, `credentials.json`, API keys, or private-key blobs appear in a swe-team commit diff.

**Why it happens**: Coder reads a file containing secrets during exploration, later includes it in context when making an edit, doesn't distinguish secret content from source code.

**Prevention**: MVP relies on the target repo's `.gitignore` and any user pre-commit hooks (SPEC §12 — marked P2 for a verifier-side scan). Coder-loop skill explicitly: "Never stage files matching `.env*`, `*.pem`, `*.key`, `credentials*`." Threat model acknowledges this is a MVP gap.

---

## Force-Push / Destructive Git

**Symptom**: `git push --force`, `git reset --hard`, `git branch -D`, `rm -rf .git`, or `git rebase -i` on a swe-team branch.

**Why it happens**: The coder tries to "clean up" history or recover from a bad commit.

**Prevention**: `guard-destructive-git.sh` (SPEC §7.2) matches these patterns via `PreToolUse` + `Bash` matcher; exit 2 blocks the call. Exception list is tight: only non-destructive `git` verbs are allowed freely.

---

## Dependency on Conversation Context

**Symptom**: Agent references "as I mentioned above" or "from the earlier discussion" — but the referenced content is in a previous, now-compacted, turn.

**Why it happens**: The LLM treats the conversation as persistent memory.

**Prevention**: SPEC §3.5 ground-truth rule. Context-prime skill reinjects `run.json` + tasks + recent events at every spawn. Subagents spawn with isolated context, so "earlier discussion" never exists for them — the spawning agent must pass evidence explicitly.

---

## Cross-Task Interference

**Symptom**: Task T2's commit undoes or contradicts T1's commit. Whole-PR diff shows oscillations.

**Why it happens**: Tasks are reviewed in isolation; no agent looks at cross-task behavior until SHIP.

**Prevention**: Whole-PR VERIFY pass (SPEC §9.3). `cross_task_conflicts` field; sem verifier looks at the full `git diff <base>..HEAD` and flags same-function edits across tasks. Blocking threshold: `cross_task_conflicts == []` required for SHIP.

---

## Ambiguity Ignored

**Symptom**: Requirement is vague ("make it faster", "clean up the code"), but the agent proceeds without clarification, producing arbitrary changes.

**Why it happens**: LLMs prefer to act over to ask.

**Prevention**: DEFINE phase (SPEC §5.1) with ambiguity scoring. Score ≥ 3 runs DEFINE, which forces expansion of the requirement into concrete acceptance bullets before PLAN. Short requirements (<80 chars), missing action verbs, missing concrete nouns all add to the score.

---

## Budget Blowup

**Symptom**: Token or USD spend exceeds ceiling; run continues generating cost.

**Why it happens**: Loops, replans, large contexts compound cost without bound.

**Prevention**: Two-tier budget guard (SPEC §8):
- Soft warn at 80% (`budget_warn` event, run continues)
- Hard stop at 100% (`budget_stop`, hook exit 2 blocks further Task spawns)
- `budget-gate.sh` runs `PreToolUse` on `Task`, reads `budget.json` cumulative counters.

---

## Blind Flaky-Test Retries

**Symptom**: A real failure masquerades as flakiness; retries hide a genuine bug.

**Why it happens**: "If it passes on retry, it must be flaky" is a seductive heuristic.

**Prevention**: SPEC §8 flaky retry cap = 2 attempts. Third attempt counts as real failure, returns to coder. Configurable via `verification.allow_flaky_retry` (SPEC §10).

---

## Wrong-Model Verdict

**Symptom**: Haiku-sized verifier "approves" a semantically subtle bug because reasoning depth is insufficient.

**Why it happens**: Verifier model is under-specced for the judgment it's being asked to make.

**Prevention**: SPEC §4 model rationale: mech uses Haiku only because it runs deterministic shell checks (LLM formats evidence only). Sem uses Sonnet — same family as coder, per research §10 pattern 1 ("use same or stronger model as judge"). Haiku is never asked to make semantic judgments.

---

## Agent Pretends to Use a Tool It Didn't

**Symptom**: Agent output says "I ran the tests and they passed," but no `Bash` invocation appears in the event log.

**Why it happens**: Hallucinated tool calls — an LLM narrates a tool call as if it happened.

**Prevention**: `capture-test-output.sh` is the sole source of truth for test results — it fires only when an actual `Bash` tool call completes. A `verification` event without a corresponding `observation` with `stdout_sha256` is schema-invalid → rejected at phase exit.

---

*Cross-reference: `SPEC.md` for contract details, `docs/EVAL.md` for how we test these detections hold across the seed corpus, `docs/TELEMETRY.md` for jq queries to spot these patterns in a live run.*
