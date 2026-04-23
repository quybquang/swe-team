---
name: swe-team
description: Run the swe-team pipeline on a requirement. Plans, implements, verifies, and opens a PR into the integration branch. Usage `/swe-team <requirement-text-or-url>` or `/swe-team` to be prompted.
---

# /swe-team

You are the entry point for a **swe-team** run. Your job: accept a requirement, set up the run, and hand off to the `swe-lead` agent.

The Single Source of Truth is `SPEC.md` at the repo root. Every rule below is derived from it — read `SPEC.md` before making decisions if in doubt.

## 1. Parse input

The argument after `/swe-team` is the requirement. It is one of:

- **Plain text** — use as-is.
- **URL** — fetch the ticket body:
  - Linear (`linear.app/...`) → MCP Linear tool, read issue description + comments.
  - GitHub issue (`github.com/.../issues/N`) → `gh issue view <N> --repo <owner/repo> --json title,body,comments`.
  - Notion — MCP Notion `fetch` tool.
- **Empty** — prompt the user to paste the requirement inline, then treat as plain text.

Flags (optional):
- `--define` — force DEFINE phase even if ambiguity score is low.
- `--skip-define` — skip DEFINE even if high.
- `--base <branch>` — override base branch for this run.
- `--draft` — open PR as draft.

## 2. Preflight

1. Confirm current directory is a git repo (`git rev-parse --git-dir`).
2. Confirm working tree clean (if `gh.require_clean_working_tree: true` in `swe-team.config.json`). Else abort with message.
3. Confirm `swe-team.config.json` exists at repo root. If not, instruct user to run `scripts/install.sh`.
4. Confirm base branch exists (`git rev-parse --verify <base>`).
5. Confirm `.claude/swe-team/` directory exists.

## 3. Create run

```bash
run_id="$(date -u +%Y-%m-%d-%H%M)-$(echo "<short-slug-from-req>" | tr -cd 'a-z0-9-' | cut -c1-30)"
run_dir=".claude/swe-team/runs/$run_id"
mkdir -p "$run_dir/build"
```

Write `run.json`:

```json
{
  "run_id": "<run_id>",
  "started_at": "<ISO-8601>",
  "requirement": { "kind": "text|linear|github_issue|notion", "text_or_url": "...", "fetched_content": "..." },
  "branch": "<prefix><slug>-<run_id>",
  "base_branch": "<base>",
  "status": "running",
  "version": "<VERSION from .claude/swe-team/VERSION>"
}
```

Seed `budget.json`, `tasks.json` (empty), `phase_state.json` (`{"phase": null, "replan_count": 0}`), `events.jsonl` (empty), `verification.jsonl` (empty).

Update symlink: `.claude/swe-team/runs/current` → `$run_dir` (so hooks find the active run without needing the id).

## 4. Compute assertion baseline

Before the run starts, record the assertion count on the base branch — the mechanical verifier compares HEAD against this.

```bash
git stash -u 2>/dev/null || true
git checkout <base>
count=$(grep -rhoE '\b(expect|assert|should|require)\b' \
  $(ls -d <test_globs> 2>/dev/null) 2>/dev/null | wc -l | tr -d ' ')
echo "$count" > "$run_dir/baseline_assertions.txt"
git checkout -
git stash pop 2>/dev/null || true
```

## 5. Create the working branch

```bash
git checkout -b "<branch>"
```

## 6. Hand off to swe-lead

Spawn the `swe-lead` subagent with the Task tool. The task description should be:

> Run a swe-team pipeline. Run directory: `.claude/swe-team/runs/<run_id>/`. Base branch: `<base>`. Requirement: `<requirement text or fetched content>`. Flags: `<flags>`. Follow SPEC.md phases: DEFINE (conditional) → PLAN → BUILD → VERIFY → SHIP. You are the orchestrator. Spawn swe-coder, swe-verifier-mech, swe-verifier-sem, and swe-pr via the Task tool. Respect all guards in SPEC §8. Re-read `run.json`, `tasks.json`, `phase_state.json` at every turn.

Do NOT spawn swe-coder or verifiers directly from this command — that is swe-lead's job.

## 7. On return

When swe-lead returns:

- Success: print the PR URL from `pr.json` and the run summary (tasks done, verification pass, budget used).
- `needs_split`: print `suggested-breakdown.md` content and advise re-running per suggestion.
- Failure / abort: print the last `blocker`, `stuck`, or abort reason from `events.jsonl`; the run dir remains for inspection.

## 8. Cleanup

Remove the `runs/current` symlink. Leave the run directory in place (audit trail).

## Invariants

- Never bypass preflight.
- Never spawn BUILD agents directly; always through swe-lead.
- Never auto-merge PRs. Human review is the gate.
- If any preflight fails, abort before touching git.
