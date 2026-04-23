---
name: swe-team:context-prime
description: Assembles the minimal per-agent context slice from the current run directory and returns a compact brief suitable for injection at the start of every swe-team agent turn. Runs at the start of any swe-lead, swe-coder, swe-verifier-mech, swe-verifier-sem, or swe-pr spawn, and whenever an agent re-reads state mid-turn.
---

# swe-team:context-prime

## Overview

Every swe-team agent must re-ground itself on each turn by reading structured run state, not by trusting its context window (SPEC §3.5). This skill produces that grounding: a compact, stable-prefix brief that combines the original requirement, the active task, the current phase, a bounded event tail, and the per-task verification history. The brief is injected at the top of each agent spawn prompt so that identical prefixes across spawns hit prompt caching (research §7 pattern 2, §10 pattern 2).

This is the swe-team equivalent of Aider's always-loaded `CONVENTIONS.md` (research §7 pattern 1) — but parameterized per run and per agent role.

## When to Use

- At the start of every swe-lead, swe-coder, swe-verifier-mech, swe-verifier-sem, or swe-pr spawn.
- Whenever an agent mid-turn needs to re-check "what is the current state" after a tool call that may have moved the run forward.
- Before emitting a `verification`, `replan`, or `run_complete` event — verify the state you are reporting on still matches what's on disk.

## When NOT to Use

- Not for hook scripts — hooks read files directly; skills are for LLM agents.
- Not during the initial `/swe-team` ingest phase, before `run.json` exists. The invoking slash command creates the run dir first, then spawns swe-lead, and only then does context-prime have a dir to read.
- Not inside verifier evidence blocks — evidence fields (SPEC §9) come from deterministic checks, not from a context brief.
- Not as a substitute for reading actual source files when the task requires them. The brief tells you **what state the run is in**, not **what the code contains**. For code, read source via Read/Grep.
- Not for runs outside `.claude/swe-team/runs/`. If no `runs/current` symlink exists, abort and surface "no active swe-team run."

## Process

### Step 1. Resolve the run directory

Read the symlink `.claude/swe-team/runs/current`. This points at the active run dir. If missing, abort with error "no active swe-team run."

### Step 2. Load immutable anchors

Read in full (these are small and always needed — SPEC §3.6 context-source rule):

- `run.json` — original requirement, branch, base_branch, status, version.
- `phase_state.json` — current phase, active task id, replan_count, iteration counters.

### Step 3. Load role-specific slice

Per SPEC §3.6, pull only what the current agent role needs:

| Agent (from spawn prompt) | Additional reads |
|---|---|
| `swe-lead` | full `tasks.json`, tail of `events.jsonl` (last 50 lines), all `blocker` events, all `verification` rows |
| `swe-coder` (task T_i) | only `tasks.json` entry for T_i, full `build/task-T_i.jsonl`, list of files in T_i.touch_files (names only, not contents) |
| `swe-verifier-mech` | `tasks.json` entry for active task, `git diff <base>..HEAD` (names + line counts only), raw last test/lint command output referenced by latest observation |
| `swe-verifier-sem` | `tasks.json` entry for active task, `git diff` file list, latest mech verdict for this task, `run.json.requirement` verbatim |
| `swe-pr` | `run.json`, full `tasks.json`, all `verification.jsonl`, `git log --oneline <base>..HEAD` |

### Step 4. Tail the event log

For agents that need recent context (swe-lead, verifiers): read last 20 lines of `events.jsonl` (not 50 — tighter window prevents bloat). For swe-coder, read last 20 lines of `build/task-<active>.jsonl` instead.

### Step 5. Format the brief

Emit a compact string using this template (markdown, ≤ 2KB when task + events are small):

```
# swe-team context — <run_id>

**Requirement** (immutable anchor, from run.json):
<requirement.text or fetched_content, truncated to 500 chars>

**Phase**: <phase_state.phase>
**Active task**: <phase_state.active_task_id> — <tasks[active].title> (size: <size>, iter: <n>/<cap>)
**Replans used**: <replan_count>/<max_replans>
**Branch**: <branch> (base: <base_branch>)

## Active task acceptance
- A1: <first acceptance>
- A2: <second acceptance>
  ...

## Touch files (scope boundary)
- <path1>
- <path2>

## Recent events (last 20, most recent last)
<tsv: ts | agent | kind | summary>

## Latest verdicts for this task
- mech: <verified|-> <reason if not verified>
- sem:  <verified|-> <reason if not verified>
```

### Step 6. Return, do not act

This skill produces text. It does not decide next action. The agent receiving the brief decides.

### Step 7. Never summarize the requirement

The requirement block is quoted verbatim (subject to a hard character cap). LLM summarization here would reintroduce the hallucination vector SPEC §3.5 prevents.

## Anti-Rationalizations

| Rationalization | Reality |
|---|---|
| "I already have this in my context from the previous turn." | No — agents re-read on every turn per SPEC §3.5. The previous turn's context is not authoritative. |
| "The requirement is obvious; I'll paraphrase it for brevity." | Paraphrasing is the first step toward drift. Quote verbatim. |
| "Reading all these files wastes tokens." | Reading is cheap; reconstructing a hallucinated state is expensive (failed commits, wasted verifier calls, bad PR). Tokens spent priming < tokens spent recovering. |
| "I'll skip the event tail; nothing important happened." | That's your assumption. The tail is how you detect a stuck pattern before your own actions feed it. |
| "For a swe-coder, tasks.json is fine in full." | No — SPEC §3.6 restricts coder to only its task entry. Seeing other tasks invites out-of-scope edits. |
| "The brief can be 10KB — it's fine." | No — the brief competes for context with source files. Keep ≤ 2KB on happy path. |

## Red Flags

- `run.json` not read but agent references the requirement → re-run this skill.
- Event tail absent from the brief → stuck detection blind spot; re-run.
- Agent outputs "as discussed earlier" or "from the previous turn" → ignored SPEC §3.5; force re-read.
- Brief larger than 4KB → slicing rule violated; restrict per role.
- Mixed-role reads (e.g. swe-coder reading verification.jsonl) → leaks cross-task context; strip.
- Requirement paraphrased, not quoted → hallucination vector; replace with verbatim quote from run.json.

## Verification

Before handing the brief to the agent, confirm:

1. `run.json` was actually read this turn (log the file stat). If not, fail.
2. Requirement block in the brief is a prefix of `run.json.requirement.text` or `.fetched_content` (string match, not paraphrase).
3. Phase in the brief matches `phase_state.json.phase` exactly.
4. Active task id in the brief exists in `tasks.json` with matching title and size.
5. For the current agent role, only the reads listed in SPEC §3.6 were performed — no others.
6. Total brief length ≤ 2048 chars on S-sized tasks, ≤ 4096 on M/L.
7. The brief begins with content identical across spawns of the same agent type in this run (to hit prompt caching — research §10 pattern 2).

If any check fails, regenerate the brief before the agent proceeds. A failed brief is worse than no brief because it misleads with false authority.

---

*See SPEC §3.5 (ground-truth rule), §3.6 (per-agent context source table), `docs/AGENT_DESIGN.md` §2 (context engineering rationale), research §7 and §10 (Aider + Anthropic eng patterns this skill is modeled on).*
