# swe-team — Specification (SoT)

> **Status**: v0.2.0
> **Last updated**: 2026-04-24
> **Authority**: This document is the Single Source of Truth. All code, configs, schemas, and agent prompts MUST derive from it. If code and spec disagree, the spec is right and the code is a bug.

---

## Table of Contents

1. [Mission](#1-mission)
2. [Architecture](#2-architecture)
3. [State Schema](#3-state-schema)
4. [Agent Roster](#4-agent-roster)
5. [Phase Flow](#5-phase-flow)
6. [Skills Catalog](#6-skills-catalog)
7. [Hooks Contract](#7-hooks-contract)
8. [Guards & Stop Conditions](#8-guards--stop-conditions)
9. [Verification Protocol](#9-verification-protocol)
10. [Config Schema](#10-config-schema)
11. [Package & Install](#11-package--install)
12. [Threat Model](#12-threat-model)
13. [Out of Scope (MVP)](#13-out-of-scope-mvp)
14. [Glossary](#14-glossary)

---

## 1. Mission

`swe-team` is a Claude Code-native, distributable agent-team package. A user submits a requirement — plain text or a ticket URL — through a single slash command. A coordinated group of agents plans the work, writes code, verifies it, and opens a Pull Request against the repo's integration branch (default `dev`). Humans review and merge the PR. All state is file-based, checked into `.claude/`, and portable across machines and teammates.

**Non-goals**: replacing human review; autonomous merge; autonomous deploy; writing greenfield projects from scratch.

**Design axioms** (in priority order):

1. **Docs-as-Code / SoT discipline** — this spec is authoritative. Drift between spec and code is a bug in the code.
2. **Evidence over assertion** — every "done" claim must carry mechanical evidence (SHA, test output hash, assertion count).
3. **Claude Code-native** — use Task, Skill, Hooks, `.claude/agents/`, `.claude/commands/`, `.claude/skills/` as documented. Never reinvent primitives.
4. **Human gate at PR only** — no gates mid-flow unless a guard fires.
5. **Minimal-viable autonomy** — autonomous in happy path; deterministic escape hatches when signals appear.

---

## 2. Architecture

### 2.1 High-level flow

```
User
  │  /swe-team <requirement | URL>
  ▼
┌─────────────────────────────────────────────┐
│  Orchestration main thread                  │
│  (slash command + swe-lead agent)           │
└─────────────────────────────────────────────┘
  │
  │  Task tool spawn (sequential, isolated ctx)
  │
  ├─► swe-lead           (DEFINE → PLAN → re-plan)
  │
  ├─► swe-coder × N      (BUILD loop per task)
  │
  ├─► swe-verifier-mech  (VERIFY tier 1 — deterministic)
  │
  ├─► swe-verifier-sem   (VERIFY tier 2 — reasoning, gated on mech pass)
  │
  └─► swe-pr             (SHIP — gh pr create)

  Persistent state: .claude/swe-team/runs/<run-id>/
```

### 2.2 Why multi-agent (not single-agent long-horizon)

Long-horizon single agents fail on *error accumulation*: a small mistake at step 3/20 compounds into unrecoverable state at step 15/20. Phase boundaries with evidence gates localize errors. Trade-off: context coherence loss. Mitigation: the original requirement is re-read at every agent startup (§ 3.5).

### 2.3 Why Claude Code-native

Claude Code provides: isolated-context subagents (Task tool), file-based agent definitions (`.claude/agents/*.md`), hooks (`PreToolUse`, `PostToolUse`, `SubagentStop`, `Stop`, `SessionStart`), skills (auto-invoked by description match), slash commands, and project-over-global settings merging. `swe-team` composes these primitives. No custom runtime, no Python daemon, no external queue.

---

## 3. State Schema

### 3.1 Run directory layout

```
.claude/swe-team/runs/<run-id>/
├── run.json                  # run metadata (id, started_at, requirement, status)
├── tasks.json                # authoritative task list (append-only updates)
├── phase_state.json          # current phase, active task, counters
├── events.jsonl              # system + lead events
├── pre-flight-brief.md       # clarify output: clarified req, key decisions, out-of-scope
├── assumptions.md            # autonomous-mode assumptions (omitted in interactive mode)
├── spec.md                   # DEFINE output: acceptance bullets, file hints, open questions
├── build/
│   └── task-<task_id>.jsonl  # one file per task (coder actions/observations)
├── verification.jsonl        # mech + sem + security_review verdicts
├── budget.json               # cumulative tokens + USD
└── pr.json                   # final PR metadata (url, number, branch)

.claude/swe-team/
├── learnings.jsonl           # PERSISTENT — cross-run lessons (NOT under runs/)
├── config.json               # per-project config override
└── config.default.json       # defaults shipped with the package
```

**Split rationale**: concurrent appends from independent agents/hooks can race. Per-phase / per-task files eliminate the race without file locks. `events.jsonl` is reserved for system and lead; coder writes to `build/task-<id>.jsonl`; verifiers write to `verification.jsonl`.

`<run-id>` format: `YYYY-MM-DD-HHmm-<shortslug>` (e.g. `2026-04-23-2215-dark-mode`).

### 3.2 `run.json`

```jsonc
{
  "run_id": "2026-04-23-2215-dark-mode",
  "started_at": "2026-04-23T22:15:03Z",
  "requirement": { "kind": "text", "text": "..." },
  // OR: { "kind": "linear", "url": "...", "fetched_content": "..." }
  // OR: { "kind": "github_issue", "url": "...", "fetched_content": "..." }
  "branch": "swe/dark-mode-2026-04-23-2215",
  "base_branch": "dev",
  "status": "running",  // running | succeeded | failed | aborted
  "version": "0.1.0"
}
```

### 3.3 `tasks.json` (authoritative task list)

```jsonc
{
  "version": 1,                    // bumped on each re-plan
  "tasks": [
    {
      "id": "T1",
      "title": "Add ThemeContext",
      "description": "Create React context exposing theme state + setter.",
      "size": "S",                 // S | M | L
      "touch_files": ["src/contexts/ThemeContext.tsx"],
      "acceptance": [
        "Context exports { theme, setTheme }.",
        "Default value reads from localStorage key 'theme'."
      ],
      "status": "pending",         // pending | in_progress | done | failed
      "depends_on": [],            // task IDs
      "parallelizable_with": []    // P2 — MVP ignores
    }
  ]
}
```

### 3.4 Event schema (`events.jsonl`, `build/task-*.jsonl`)

All events are line-delimited JSON. Every event has:

```jsonc
{
  "kind": "<event kind>",
  "ts": "ISO-8601 UTC",
  "run_id": "<run-id>",
  "agent": "swe-lead" | "swe-coder" | "swe-verifier-mech" | "swe-verifier-sem" | "swe-pr" | "system",
  // kind-specific fields follow
}
```

**Kinds** (exhaustive):

| kind | Fields | Emitter |
|---|---|---|
| `phase_enter` | `phase`: `CLARIFY\|DEFINE\|PLAN\|BUILD\|VERIFY\|SHIP\|RETRO` | swe-lead / system |
| `phase_exit` | `phase`, `ok`: bool | swe-lead / system |
| `action` | `task_id`, `tool`, `target` (file or command), `args_summary` | coder / lead |
| `observation` | `task_id`, `tool`, `exit_code`, `stdout_sha256`, `summary` (≤200 chars) | coder (via hook) |
| `verification` | `task_id`, `tier`: `mech\|sem`, `verified`: bool, `evidence`: object (§ 9) | verifier-mech / verifier-sem |
| `security_review` | `security_verdict`: `pass\|warn\|fail`, `security_issues`: array | verifier-sem (via security-review skill) |
| `blocker` | `task_id`, `reason`, `proposed_resolution` | coder |
| `replan` | `count`, `reason`, `appended_task_ids`: string[] | swe-lead |
| `budget_warn` | `pct`, `tokens`, `usd` | system (hook) |
| `budget_stop` | `tokens`, `usd` | system (hook) |
| `stuck` | `task_id`, `pattern`: see § 8, `details` | system (hook) |
| `run_complete` | `pr_url`, `branch` | swe-pr |
| `run_abort` | `reason` | swe-lead / system |
| `retro_complete` | `metrics`: `{tasks_total, tasks_done, replans, mech_fails}`, `lessons_written`: int | swe-lead (via retro skill) |
| `learning` | `scope`: `planning\|verification\|requirement\|build`, `lesson`: string, `evidence_run_id` | appended to `learnings.jsonl` NOT events.jsonl |

### 3.5 Ground-truth rule (anti-hallucination)

The LLM MUST NOT trust its context window as the record of what has happened. The events files are the record. Any claim of work done ("I implemented X") must be accompanied by a `verification` event with `verified: true` and `evidence` that a hook or other agent can mechanically confirm. Claims without evidence are hallucinations and are discarded by the phase-exit gate.

Each agent, at the start of its turn, re-reads:

1. `run.json` (original requirement — immutable anchor)
2. `tasks.json` (current plan)
3. `phase_state.json` (what's active)
4. The relevant slice of event logs (per § 3.6)

---

### 3.6 Context condensation per agent

| Agent | Reads |
|---|---|
| `swe-lead` | `run.json`, `tasks.json`, `phase_state.json`, last N=50 events from `events.jsonl`, all `blocker` + `verification` entries, last N=10 learnings from `learnings.jsonl` |
| `swe-coder` (task T_i) | `run.json`, `tasks.json` entry for T_i only, `build/task-T_i.jsonl`, files in `touch_files` |
| `swe-verifier-mech` | `tasks.json` entry for T_i, `git diff <base>..HEAD` for T_i commit, raw test/lint output |
| `swe-verifier-sem` | `tasks.json` entry for T_i, `git diff` for T_i commit, mech verdict, `run.json.requirement` |
| `swe-verifier-sem` (whole-PR) | `run.json`, `tasks.json`, full `git diff <base>..HEAD`, `verification.jsonl` (all) |
| `swe-pr` | `run.json`, `tasks.json`, `verification.jsonl` (all), `git log <base>..HEAD`, `security_review` event |

Each agent receives the above as structured text injected into its spawn prompt by the caller (main thread or swe-lead). Nothing else.

---

## 4. Agent Roster

All agents live in `.claude/agents/`. Frontmatter fields: `name`, `description`, `tools`, `model`. `tools` is an explicit allowlist; if omitted, the agent inherits the main thread's tools (not used here — we always restrict).

| Agent | Model | Description (routes Task tool here) | Tools | Lifecycle |
|---|---|---|---|---|
| `swe-lead` | `opus` | Orchestrates a swe-team run: plan, re-plan, phase transitions, final review. Invoke when the user runs `/swe-team` or when a coder hits a blocker. | `Read, Write, Edit, Grep, Glob, Bash, Task, Skill` | Spawned by `/swe-team` command |
| `swe-coder` | `sonnet` | Implements one swe-team task (identified by task_id). Produces exactly one commit. Invoke from swe-lead during BUILD. | `Read, Write, Edit, Grep, Glob, Bash, Skill` | Spawned per task |
| `swe-verifier-mech` | `haiku` | Mechanical verification of a swe-team commit: tests, lint, typecheck, test-gaming heuristics. Deterministic. Invoke from swe-lead during VERIFY. | `Read, Bash, Skill` | Spawned per task commit |
| `swe-verifier-sem` | `sonnet` | Semantic verification of a swe-team commit: acceptance match, scope audit, adversarial logic review. Runs only if mech passes. | `Read, Grep, Bash, Skill` | Spawned per task commit |
| `swe-pr` | `sonnet` | Opens the PR into the base branch with structured body derived from events + verification logs. Final phase of a swe-team run. | `Read, Bash, Skill` | Spawned once at SHIP |

**Model rationale**:

- `swe-lead`: Opus. Planning and re-planning are the highest-leverage reasoning in the pipeline.
- `swe-coder`: Sonnet. Code generation; Opus overkill given scoped tasks.
- `swe-verifier-mech`: Haiku. Runs deterministic shell checks; LLM only formats evidence. Haiku fine.
- `swe-verifier-sem`: Sonnet. Adversarial reasoning; Haiku insufficient (SWE-bench evidence).
- `swe-pr`: Sonnet. Synthesis from event log into natural-language PR body.

---

## 5. Phase Flow

```
/swe-team <req|url>
        │
        ▼
   [ingest]              # main thread: fetch URL (if any), create run dir, write run.json
        │
        ▼
 ┌───────────────┐
 │   CLARIFY     │  swe-lead — always runs (unless skip_clarify=true)
 └───────────────┘
   │
   │ interactive mode: ask user 3–5 questions, wait for answers
   │ autonomous mode:  grep repo, write assumptions.md
   │ output: pre-flight-brief.md
   │
   │ SIZE GATE: if clarify returns needs-split → abort (no DEFINE/PLAN)
   ▼
 ┌───────────────┐
 │   DEFINE?     │  conditional
 └───────────────┘
   │           │
   │ skip      │ run (ambiguity score ≥ threshold)
   │           │
   │           ▼
   │      swe-lead: expand requirement → spec.md (consults pre-flight-brief.md)
   │           │
   └─────┬─────┘
         ▼
 ┌───────────────┐
 │     PLAN      │  swe-lead
 └───────────────┘
   │
   │ output: tasks.json v1 (informed by pre-flight-brief.md + learnings.jsonl)
   │ gate: no task >10 files; every task has ≥1 acceptance
   │
   │ SIZE GATE: if total est. LOC > 500 OR task count > 15
   │   → write suggested-breakdown.md; abort with status=needs_split
   ▼
 ┌───────────────┐
 │     BUILD     │  loop over tasks sequentially
 └───────────────┘
   │
   │ for each task:
   │   swe-coder(task) → 1 commit on branch
   │   swe-verifier-mech(commit)
   │     fail → revision back to swe-coder (counts vs iter budget)
   │     pass → swe-verifier-sem(commit)
   │       fail (spec_gap | security_fail) → re-plan
   │       fail (other) → revision
   │       pass → mark task done
   │   if blocker event → swe-lead.replan() (max 2)
   │   if stuck event  → abort
   ▼
 ┌───────────────┐
 │    VERIFY     │  whole-PR sanity pass (swe-verifier-sem)
 └───────────────┘
   │
   │ input: full diff <base>..HEAD
   │ checks: requirement coverage %, cross-task conflicts, security verdict
   │   swe-team:security-review → OWASP + secret scan → pass|warn|fail
   │   warn: recorded in PR body, does NOT block
   │   fail: triggers re-plan targeting vulnerable code
   ▼
 ┌───────────────┐
 │     SHIP      │  swe-pr
 └───────────────┘
   │
   │ git push origin <branch>
   │ gh pr create --base <base> --body <generated + security_issues if warn>
   ▼
 ┌───────────────┐
 │     RETRO     │  swe-lead (always — even on fail/abort)
 └───────────────┘
   │
   │ analyze: budget efficiency, failure patterns, what worked
   │ append: ≥1 lesson to .claude/swe-team/learnings.jsonl
   │ emit: retro_complete event
   ▼
 [run terminal]
```

### 5.1 DEFINE trigger (heuristic)

Ambiguity score is the sum of:

- +2 if requirement < 80 chars
- +1 if no action verb matched (add, fix, remove, refactor, rename, migrate, update, document, test, revert)
- +1 if no concrete noun (file path, component name, route, table name)
- +1 if URL requirement was fetched but body was empty or very short (< 200 chars)

Threshold: `≥ 3` runs DEFINE; else skip. User can force with `/swe-team --define`.

### 5.2 Re-plan trigger

A `blocker` event from swe-coder or a `verification` fail with `reason=spec_gap` from swe-verifier-sem triggers swe-lead.replan():

- Append new tasks to `tasks.json` (increment `version`). Never rewrite/delete existing tasks.
- Increment `phase_state.replan_count`. If > 2, abort.
- Resume BUILD with the original coder instance killed; new coder spawned on the next task.

### 5.3 Iteration budget per task

| Size | Max BUILD iterations | Notes |
|---|---|---|
| S | 2 | One reroll allowed |
| M | 4 | |
| L | 6 | If L dominates Plan, re-size via re-plan |

"Iteration" = one swe-coder spawn that produces (or attempts) a commit. Verifier failures that return to coder count as iterations.

### 5.4 Run statuses

| Status | Meaning |
|---|---|
| `running` | In-flight |
| `succeeded` | PR opened |
| `needs_split` | Plan exceeded size gate; user must decide |
| `failed` | Unrecoverable (stuck, max replans, budget) |
| `aborted` | User-initiated or safety trip |

---

## 6. Skills Catalog

Skills live at `.claude/skills/<skill-name>/SKILL.md`. Each has the addyosmani format: `Overview → When to Use → When NOT to Use → Process → Anti-Rationalizations → Red Flags → Verification`.

| Skill | Directory | Phase | Invoked by | Purpose |
|---|---|---|---|---|
| `swe-team:clarify` | `swe-team-clarify` | CLARIFY | swe-lead | Pre-flight requirement clarification. Produces `pre-flight-brief.md`. Two modes: interactive (user Q&A) and autonomous (assumption-based). |
| `swe-team:define-spec` | `swe-team-define-spec` | DEFINE | swe-lead | Expand an ambiguous requirement into a spec with acceptance bullets and file hints. Reads `pre-flight-brief.md`. |
| `swe-team:decompose-tasks` | `swe-team-decompose-tasks` | PLAN | swe-lead | Produce tasks.json conforming to schema. Enforces size, touch_files, acceptance. |
| `swe-team:coder-loop` | `swe-team-coder-loop` | BUILD | swe-coder | Per-task edit→test→commit loop with iteration cap discipline. |
| `swe-team:verify-mechanical` | `swe-team-verify-mechanical` | VERIFY | swe-verifier-mech | Runs deterministic shell checks (tests, lint, typecheck) and computes evidence fields. |
| `swe-team:detect-gaming` | `swe-team-detect-gaming` | VERIFY | swe-verifier-mech | Exact shell checks for test deletion, new `.skip`/`.only`, assertion count drops. |
| `swe-team:verify-semantic` | `swe-team-verify-semantic` | VERIFY | swe-verifier-sem | Acceptance matching, scope audit, adversarial review. Requires evidence fields in verdict. |
| `swe-team:security-review` | `swe-team-security-review` | VERIFY | swe-verifier-sem | OWASP Top 10 + secret detection over full PR diff. Emits `security_verdict` (pass\|warn\|fail). fail blocks SHIP. |
| `swe-team:anti-rationalize` | `swe-team-anti-rationalize` | VERIFY | both verifiers | Forbid hedging. Reject verdicts using "probably"/"should work"/"looks correct" without evidence. |
| `swe-team:detect-stuck` | `swe-team-detect-stuck` | BUILD | system (hook) | Pattern match: identical commits, identical test sha, file churn, stall. |
| `swe-team:replan` | `swe-team-replan` | BUILD→PLAN | swe-lead | Append-only task addition, increments version, enforces cap. |
| `swe-team:budget-check` | `swe-team-budget-check` | all | system (hook) | Token + USD ceiling arithmetic. |
| `swe-team:condense-context` | `swe-team-condense-context` | all | spawning agent | Produce the per-agent context slice per § 3.6. |
| `swe-team:open-pr` | `swe-team-open-pr` | SHIP | swe-pr | `gh pr create` with structured body derived from events + verification logs. |
| `swe-team:retro` | `swe-team-retro` | RETRO | swe-lead | Post-run retrospective. Writes ≥1 lesson to `learnings.jsonl`. Runs on every terminal status. |
| `swe-team:context-prime` | `swe-team-context-prime` | all | any agent | Start-of-turn re-grounding: re-reads run dir anchors, injects recent events, surfaces active learnings. |

---

## 7. Hooks Contract

All hooks are shell scripts in `.claude/hooks/`. Registered in `.claude/settings.json` under `hooks`.

### 7.1 Event → script map

```jsonc
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": ".claude/hooks/init-run.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": ".claude/hooks/guard-destructive-git.sh" }] },
      { "matcher": "Task", "hooks": [{ "type": "command", "command": ".claude/hooks/budget-gate.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write", "hooks": [{ "type": "command", "command": ".claude/hooks/track-file-edit.sh" }] },
      { "matcher": "Bash",       "hooks": [{ "type": "command", "command": ".claude/hooks/capture-test-output.sh" }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": ".claude/hooks/phase-exit-verify.sh" }] }
    ]
  }
}
```

### 7.2 Hook contracts

Each hook receives the Claude Code standard hook JSON on stdin. It reads `.claude/swe-team/runs/current/` (a symlink to the active run dir, created by `init-run.sh`).

| Script | Reads | Writes | Exit codes |
|---|---|---|---|
| `init-run.sh` | none | Creates run dir, `run.json` stub, seeds `budget.json`, symlinks `runs/current` | 0 |
| `guard-destructive-git.sh` | stdin tool_input.command | nothing | 2 blocks on `git push --force`, `git reset --hard`, `git rebase -i`, `rm -rf .git`, `git branch -D` (unless on a swe-team branch) |
| `budget-gate.sh` | `budget.json` | `events.jsonl` (budget_warn/budget_stop) | 2 if ≥100% |
| `track-file-edit.sh` | stdin tool_input.file_path | `build/task-<active>.jsonl` (action event) | 0 (advisory; on churn >5× also writes stuck event) |
| `capture-test-output.sh` | stdin tool_input.command + tool_response | `build/task-<active>.jsonl` (observation event with sha) | 0 |
| `phase-exit-verify.sh` | stdin (subagent name), `verification.jsonl`, `tasks.json` | `events.jsonl` | 2 if VERIFY phase exit requested but not every task has mech+sem verified:true |

### 7.3 `runs/current` symlink

`init-run.sh` creates `.claude/swe-team/runs/current` → active run dir. All hooks read through this symlink so they don't need to know the run_id. The symlink is updated when a new run starts and deleted when a run completes.

---

## 8. Guards & Stop Conditions

| Guard | Default value | Trigger | Action |
|---|---|---|---|
| Max iterations per task | S=2, M=4, L=6 | Iteration count exceeded | Mark task `failed`; offer re-plan if budget allows |
| Max re-plans | 2 | `replan_count > 2` | Abort run (`failed`) |
| Plan size | 500 LOC est. OR 15 tasks | Computed in PLAN | `needs_split` status; write `suggested-breakdown.md` |
| Token ceiling | 2,000,000 tokens/run | `budget.json.total_tokens ≥ ceiling` | Hard stop |
| USD ceiling | $15/run | `budget.json.total_usd ≥ ceiling` | Hard stop |
| Budget warn | 80% of ceiling | Same | Emit `budget_warn`; continue |
| Stuck: identical commit diff | 2 consecutive | Hash of `git diff HEAD~1..HEAD` | Emit `stuck`; abort task; offer re-plan |
| Stuck: identical test sha | 3 consecutive | Same `stdout_sha256` across attempts | Emit `stuck`; abort task |
| Stuck: file churn | same file edited >5× in one task | PostToolUse(Edit\|Write) hook tally | Emit `stuck`; flag task; lead decides |
| Stuck: no verified event | 3 iterations without a `verification{verified:true}` | Hook tally | Emit `stuck`; abort task |
| Flaky test retry | 2 attempts | mech verifier | Third attempt = real fail; revert to coder |
| Destructive git | — | Guard hook patterns | Block (exit 2) |

All guard trips emit a typed event so the decision-maker (swe-lead or the abort handler) has an auditable trail.

---

## 9. Verification Protocol

### 9.1 Mechanical tier (swe-verifier-mech)

Every `verification` event with `tier=mech` MUST contain the following evidence object — all fields required:

```jsonc
{
  "commit_sha": "abc123...",                // git rev-parse HEAD after coder commit
  "test_exit": 0,                           // from `npm test` (or detected equivalent)
  "test_output_sha256": "sha256:...",       // of full test stdout+stderr
  "assertion_count": 47,                    // grep -rE '\b(expect|assert|should|require)\b' <test_dirs>
  "assertion_baseline": 45,                 // at run start, cached in run dir
  "deleted_test_files": [],                 // git diff --diff-filter=D on test globs
  "new_skip_or_only_count": 0,              // grep for added .skip/.only/xit/xdescribe in diff
  "lint_exit": 0,
  "typecheck_exit": 0
}
```

Verdict rule: `verified = true` iff:

- `test_exit == 0`
- `lint_exit == 0`
- `typecheck_exit == 0`
- `len(deleted_test_files) == 0`
- `new_skip_or_only_count == 0`
- `assertion_count >= assertion_baseline` (global across run — never net decrease)

Any violation → `verified: false` with a string `reason` field explaining which check failed.

### 9.2 Semantic tier (swe-verifier-sem)

Every `verification` event with `tier=sem` MUST contain:

```jsonc
{
  "commit_sha": "abc123...",
  "acceptance_met": ["A1", "A2"],   // IDs from tasks.json[T_i].acceptance (index-based: A1=first)
  "acceptance_missing": [],
  "scope_diff_clean": true,         // every file in `git diff` ∈ task.touch_files
  "out_of_scope_files": [],
  "reasoning_cites_evidence": true, // enforced by anti-rationalize skill
  "reasoning": "<≤500 chars, must cite file:line for each acceptance claim>"
}
```

Verdict rule: `verified = true` iff:

- `acceptance_missing == []`
- `scope_diff_clean == true`
- `reasoning_cites_evidence == true`

### 9.3 Whole-PR VERIFY pass (swe-verifier-sem, separate spawn)

After all tasks have per-commit mech+sem verified, one final sem pass runs over the full diff:

```jsonc
{
  "requirement_coverage_pct": 92,   // heuristic — sem agent judgment
  "cross_task_conflicts": [],       // e.g. task A and task B edit same function differently
  "drift_notes": "..."              // diff observed behavior vs run.json.requirement
}
```

Blocking threshold: `requirement_coverage_pct >= 70`, `cross_task_conflicts == []`, `security_verdict != "fail"`.

### 9.4 Security Review tier (swe-team:security-review, called within whole-PR pass)

A separate `security_review` event is appended to `verification.jsonl` by the security-review skill. Required fields:

```jsonc
{
  "kind": "security_review",
  "security_verdict": "pass",        // pass | warn | fail
  "security_issues": [               // empty if verdict=pass; non-empty otherwise
    {
      "severity": "high",            // critical | high | medium | low
      "category": "A03-Injection",   // OWASP category tag
      "file": "src/api/users.ts",
      "line": 42,
      "snippet": "query = 'SELECT * FROM users WHERE id=' + req.params.id"
    }
  ]
}
```

Verdict rule:
- Any `critical` or `high` issue → `security_verdict: fail` → whole-PR `verified:false` with `reason:"security_fail"` → swe-lead triggers replan.
- Any `medium` issue (no critical/high) → `security_verdict: warn` → SHIP proceeds; issues recorded in PR body for reviewer.
- Only `low` or no issues → `security_verdict: pass` → no PR annotation.

### 9.5 Anti-rationalization enforcement

The `swe-team:anti-rationalize` skill is invoked inside both verifier prompts. It rejects any verdict string that:

- Contains hedging tokens (`probably`, `should work`, `looks correct`, `seems fine`, `I think`) unless accompanied by explicit evidence fields.
- Omits `file:line` citations when claiming an acceptance is met.

A rejected verdict forces the verifier to re-run with stricter grounding.

---

## 10. Config Schema

File: `swe-team.config.json` at repo root. Schema: `.claude/references/config-schema.json`.

```jsonc
{
  "$schema": "./.claude/references/config-schema.json",
  "version": "0.2.0",
  "models": {
    "lead": "opus",
    "coder": "sonnet",
    "verifier_mech": "haiku",
    "verifier_sem": "sonnet",
    "pr": "sonnet"
  },
  "budget": {
    "max_tokens": 2000000,
    "max_usd": 15.00,
    "warn_pct": 80
  },
  "limits": {
    "max_iterations": { "S": 2, "M": 4, "L": 6 },
    "max_replans": 2,
    "stuck_identical_output": 3,
    "stuck_file_churn": 5,
    "max_files_per_task": 10,
    "max_plan_tasks": 15,
    "max_plan_loc": 500
  },
  "branch": {
    "base": "dev",
    "prefix": "swe/",
    "auto_detect_base": true
  },
  "verification": {
    "test_cmd": "auto",
    "lint_cmd": "auto",
    "typecheck_cmd": "auto",
    "test_globs": ["**/*.test.*", "**/*.spec.*", "**/tests/**", "**/test/**"],
    "allow_flaky_retry": true
  },
  "clarify": {
    "enabled": true,               // set false to skip CLARIFY entirely
    "mode": "autonomous",          // "autonomous" | "interactive"
    "max_questions": 5
  },
  "security": {
    "enabled": true,               // set false to skip OWASP scan
    "fail_on": ["critical", "high"],   // severities that block SHIP
    "warn_on": ["medium"]
  },
  "retro": {
    "enabled": true,               // set false to skip RETRO
    "max_learnings_per_run": 5,
    "learnings_window": 10         // how many past learnings swe-lead reads
  },
  "phases": {
    "define_threshold": 3,
    "force_define": false,
    "skip_define": false,
    "skip_clarify": false
  },
  "gh": {
    "pr_labels": ["ai-generated", "swe-team"],
    "pr_draft": false,
    "require_clean_working_tree": true
  }
}
```

### 10.1 Auto-detection (run at install and at run start)

| Field | Detection |
|---|---|
| `branch.base` | First existing of: `dev`, `develop`, `main`, `master` |
| `verification.test_cmd` | `package.json#scripts.test` → `pnpm test` / `npm test` / `yarn test` (pick by lockfile); else `go test ./...` (`go.mod`); else `pytest` (`pyproject.toml`/`requirements.txt`) |
| `verification.lint_cmd` | `package.json#scripts.lint`; else skip |
| `verification.typecheck_cmd` | `package.json#scripts.typecheck` or `tsc --noEmit` (if `tsconfig.json`); else skip |

`auto` means "re-detect each run." Explicit string = pinned.

---

## 11. Package & Install

### 11.1 Repo structure

```
swe-team/
├── README.md
├── SPEC.md                         # THIS FILE — SoT
├── CHANGELOG.md
├── LICENSE
├── VERSION                         # 0.1.0
├── scripts/
│   ├── install.sh                  # copy .claude/ into target + merge settings
│   └── uninstall.sh
├── .claude/                        # template
│   ├── settings.json
│   ├── commands/
│   │   └── swe-team.md
│   ├── agents/
│   │   ├── swe-lead.md
│   │   ├── swe-coder.md
│   │   ├── swe-verifier-mech.md
│   │   ├── swe-verifier-sem.md
│   │   └── swe-pr.md
│   ├── skills/
│   │   └── <12 skill directories>/SKILL.md
│   ├── references/
│   │   ├── event-schema.json
│   │   ├── tasks-schema.json
│   │   ├── verification-schema.json
│   │   ├── config-schema.json
│   │   ├── commit-conventions.md
│   │   ├── pr-template.md
│   │   └── security-checklist.md
│   ├── hooks/
│   │   ├── init-run.sh
│   │   ├── guard-destructive-git.sh
│   │   ├── budget-gate.sh
│   │   ├── track-file-edit.sh
│   │   ├── capture-test-output.sh
│   │   └── phase-exit-verify.sh
│   └── swe-team/
│       ├── VERSION
│       └── config.default.json
├── examples/
│   └── sample-requirement.md
└── tests/
    └── smoke/
        ├── run-all.sh
        ├── test-install.sh
        ├── test-hooks.sh
        └── test-schemas.sh
```

### 11.2 Install flow

```
./scripts/install.sh <target-dir>
```

1. Assert `<target-dir>` exists and is a git repo.
2. Assert no existing `.claude/agents/swe-*.md` (else warn + abort unless `--force`).
3. Copy `.claude/*` from package → `<target-dir>/.claude/*`.
4. If `<target-dir>/.claude/settings.json` exists, merge (deep-merge hooks arrays, project wins on key conflict).
5. Auto-detect stack; write `<target-dir>/swe-team.config.json`.
6. Write `<target-dir>/.claude/swe-team/VERSION` = package version.
7. Print "next steps" (how to run).

`./scripts/uninstall.sh <target-dir>` reverses step 3 (only files matching `swe-*` prefix; leaves user files alone) and removes `swe-team.config.json`.

### 11.3 Versioning

- Package is versioned in `VERSION` (SemVer, v0.x until first stable).
- Installed copy records the version in `<target>/.claude/swe-team/VERSION`.
- `install.sh --upgrade` compares versions and runs migrations if needed (MVP: simple overwrite with prompt).

---

## 12. Threat Model

| Threat | Mitigation |
|---|---|
| Coder deletes tests to "pass" | Mech verifier — `deleted_test_files == []` required |
| Coder adds `.skip` to tests | Mech verifier — `new_skip_or_only_count == 0` |
| Coder lowers assertion count | Mech verifier — `assertion_count >= baseline` |
| Coder modifies files outside scope | Sem verifier — `scope_diff_clean` / `out_of_scope_files` |
| Coder claims done without commit | Mech verifier — `commit_sha` required and must resolve |
| Lead claims done without verifications | `phase-exit-verify.sh` blocks VERIFY exit |
| Events truncated by context | Agents re-read files on each turn (§ 3.5) |
| Race on log append | Per-task file split (§ 3.1) |
| Destructive git commands | `guard-destructive-git.sh` |
| Runaway cost | Budget guard (tokens + USD) |
| Infinite loop | Stuck detection (§ 8) |
| Secret commit | P2 — MVP relies on existing repo `.gitignore` / user hooks |
| Supply-chain tamper of package | User reviews `.claude/` as checked-in code |
| PR merged autonomously | Out of scope — human gate at PR review is the enforcement |

---

## 13. Out of Scope (MVP)

- Parallel coder instances
- Run resumability after crash (events can be replayed manually)
- Multi-repo / monorepo awareness beyond the current repo
- Non-GitHub remotes (GitLab, Bitbucket)
- Custom model endpoints (Bedrock, Vertex) — uses Claude Code's configured provider
- Secret-scanning as a verifier
- Running inside Docker / sandbox
- Web UI for run inspection
- Feedback learning loop (past-run outcomes biasing planner)
- GitHub Actions integration (triggering `/swe-team` from an issue comment)
- Upgrading live `.claude/` in place (`install.sh --upgrade` stub only)

---

## 14. Glossary

- **Run** — one invocation of `/swe-team`; has a run_id and a directory.
- **Task** — a single unit of work in `tasks.json`. Produces one commit.
- **Verification (mech)** — deterministic shell checks + evidence struct.
- **Verification (sem)** — LLM-adjudicated acceptance + scope check.
- **Evidence** — structured fields in a verification event that any other process can recompute.
- **Re-plan** — append-only addition to `tasks.json`, capped at 2 per run.
- **Stuck** — any one of four pattern matches indicating no progress.
- **Blocker** — coder-emitted signal that the task as specified is infeasible; triggers re-plan.
- **Budget** — total tokens + USD across all agents in a run.

---

*End of SPEC. Implementation artifacts (agents, skills, hooks, install scripts, tests) derive from this document and must stay in sync. Any conflict is resolved by updating the code, not the spec, unless the spec itself is found to be wrong — in which case the spec is updated first and code follows.*

---

## 15. Appendix A — Research-derived refinements

> Source: `docs/research-oss-best-practices.md`. Each amendment refines an existing canonical section without rewriting it. Promote into the canonical section when implemented; until then, treat as ratified intent.

### A.1 Prompt-caching-aware spawn prompt layout (refines §3.6)

**Source**: research §10 pattern 2 (Anthropic engineering blog), §7 pattern 2 (Aider).
**Rationale**: Up to ~90% cost reduction on repeated prefixes. Each agent spawn re-includes the agent definition, the relevant skill bodies, and `run.json` — these are byte-identical across spawns of the same agent type within a run. Placing them at the top of the spawn prompt (before the per-task variable slice) maximizes cache hit rate. The new `swe-team-context-prime` skill emits its brief in this order. Document this prompt-layout discipline in §3.6 alongside the read-slice table.

### A.2 Eval harness as CI gate (refines §13)

**Source**: research §10 pattern 3 (Anthropic engineering blog).
**Rationale**: Behavioral regressions in agent systems are invisible without an eval loop. `docs/EVAL.md` defines a 5-task seed corpus (E1–E5) with mechanical grading (PR opened, tests pass, scope respected, no hallucination, cost in budget). v0.1 ships the directory layout and 2 runnable tasks; v0.2 adds the remaining 3 tasks plus a `compare-to-baseline` regression gate. This moves "eval" off the §13 out-of-scope list as `tests/eval/` lands.

### A.3 MCP scoped tools for verifiers (refines §4 tool allowlists)

**Source**: research §9 pattern 2 (Model Context Protocol).
**Rationale**: Verifiers currently receive `Bash` to run `git diff`, tests, lint. Bash is a wide blast radius — a prompt-injection through test stdout could induce arbitrary shell. Replacing `Bash` on `swe-verifier-mech` and `swe-verifier-sem` with scoped MCP servers (`git`, `filesystem`) shrinks blast radius without changing semantic capability. Optional MVP, recommended for v0.2. Coder retains full Bash (it must run arbitrary install commands).

### A.4 ACI-style edit preference (refines §6 coder-loop skill)

**Source**: research §4 pattern 1 (SWE-agent / Princeton).
**Rationale**: SWE-agent's structured `edit <start_line> <end_line> <replacement>` reduces off-by-one bugs and unintended changes vs. raw file overwrite. Claude Code's `Edit` tool is the equivalent. The `swe-team:coder-loop` skill should explicitly instruct: prefer `Edit` for modifying existing files; reserve `Write` for new files only. This tightens scope diffs and makes `scope_diff_clean` (§9.2) a stricter signal in practice.

### A.5 Structured event log replayability (refines §13 + §3.4)

**Source**: research §3 pattern 1 (OpenHands EventStream).
**Rationale**: §13 currently lists "run resumability after crash" as out of scope. The events on disk already form a replayable trace — the only missing piece is a `scripts/replay-run.sh` that reconstructs a run's state from `events.jsonl + build/task-*.jsonl + verification.jsonl` without re-spawning agents (read-only inspection). This unlocks post-mortem debugging without graduating to full crash-resume. Promote when implemented.

### A.6 Tabular anti-rationalization format (refines §6 anti-rationalize skill)

**Source**: research §1 pattern 2 (addyosmani/agent-skills).
**Rationale**: addyosmani's skills use a two-column `Rationalization | Reality` table. Tabular format is more parse-stable for LLMs than prose. The `swe-team:anti-rationalize` skill should adopt the tabular form, listing concrete hedging tokens in column 1 and the required evidence in column 2. Already applied in `docs/ANTI_PATTERNS.md` and `swe-team-context-prime/SKILL.md`; backport to anti-rationalize.

### A.7 Per-agent cost attribution in `budget.json` (refines §3.1, §10)

**Source**: research §10 pattern 2 + Cognition critique §8 ("cost scales super-linearly").
**Rationale**: §10 budget tracks totals only. Adding `by_agent` breakdown (lead / coder / verifier-mech / verifier-sem / pr) lets us see *which* agent drives cost in a stuck run, and validates the model-selection rationale in §4 with empirical data. Hook update is a one-line addition in `budget-gate.sh`. Schema extension recorded in `docs/TELEMETRY.md` §5.

### A.8 Verb-first skill descriptions (refines §6)

**Source**: research §2 pattern 3 (Anthropic Claude Code docs).
**Rationale**: Claude Code's auto-invocation matches skills by description. Verb-first descriptions ("Assembles…", "Runs when…", "Detects…") match more reliably than noun-first. Audit existing skill descriptions in §6 for compliance; update where needed. New `swe-team-context-prime` skill already follows this convention.

---

*End of Appendix A. Refinements promote into their canonical sections as they ship; this appendix is the staging area, not parallel authority.*
