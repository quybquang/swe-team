# How swe-team Works

> Pipeline reference. Read this if you want to understand what happens between
> `/swe-team "..."` and the PR appearing.

---

## Phases at a glance

| # | Phase | Agent | Output |
|---|---|---|---|
| 0 | Ingest | main thread | `run.json`, run dir, `runs/current` symlink |
| 1 | Knowledge Search | swe-lead | `knowledge-context.md` |
| 2 | Clarify | swe-lead | `pre-flight-brief.md` |
| 3 | Define | swe-lead | `spec.md` |
| 4 | Adv-Spec | swe-lead | `adversarial-notes.md` |
| 5 | Plan | swe-lead | `tasks.json` v1 |
| 6 | Chal-Plan | swe-lead | `challenge-notes.md` |
| 7 | Build | swe-coder × N | commits on branch |
| 8 | Verify | swe-verifier-mech + swe-verifier-sem | `verification.jsonl` |
| 9 | Ship | swe-pr | PR via `gh pr create` |
| 10 | Retro | swe-lead | entry in `learnings.jsonl`, knowledge-write |

---

## Phase details

### 0 — Ingest

The `/swe-team` command runs on the main thread. It:

1. Fetches the requirement — plain text, or a Linear/GitHub URL.
2. Creates `.claude/swe-team/runs/<run-id>/` (format: `YYYY-MM-DD-HHmm-<shortslug>`).
3. Writes `run.json` with the requirement, target branch, and `status: "running"`.
4. Symlinks `.claude/swe-team/runs/current` → the new run dir so all hooks resolve without knowing the run-id.
5. Spawns `swe-lead`.

### 1 — Knowledge Search

swe-lead invokes `swe-team:knowledge-search`. It extracts 3–5 keywords from the requirement and fans out to every configured knowledge source:

- **local vault** — `grep -r` over `wiki/projects/<ns>/` and `wiki/engineering/`
- **Notion** — `notion-search` MCP
- **Confluence** — Atlassian MCP search
- **Linear** — `list_issues` filtered by keywords

Top 6 results are written to `knowledge-context.md`. CLARIFY and DEFINE read this file to ground their outputs in real business context.

Skipped silently if `knowledge.sources` is empty.

### 2 — Clarify

`swe-team:clarify` converts the raw requirement into a `pre-flight-brief.md` before any spec is written.

Two modes (set in config):

- **`autonomous`** (default) — greps the repo for referents, writes explicit assumptions with evidence.
- **`interactive`** — presents 3–5 forcing questions to the user; waits for replies.

If the requirement is fundamentally infeasible (e.g. depends on an API that doesn't exist), CLARIFY aborts with `reason: "requirement_infeasible"`. No code is written.

### 3 — Define

Runs only when the ambiguity score ≥ threshold (default 3). Score adds up:

- +2 if requirement < 80 chars
- +1 if no action verb (add, fix, remove, refactor…)
- +1 if no concrete noun
- +1 if fetched URL body < 200 chars

Output: `spec.md` — acceptance bullets, file hints, open questions. Reads `pre-flight-brief.md` and `knowledge-context.md`.

Force with `--define`; skip with `skip_define: true` in config.

### 4 — Adv-Spec ⚔

`swe-team:adversarial-spec-review` challenges the spec before any task decomposition. It looks for:

- Acceptance bullets that can't be mechanically verified
- Missing edge cases
- Contradictions with existing system behaviour
- Out-of-scope scope creep

On `critical` gap: aborts, asks swe-lead to re-DEFINE. On `warning`: annotates `adversarial-notes.md` and continues.

### 5 — Plan

`swe-team:decompose-tasks` produces `tasks.json` v1. Constraints enforced:

- ≤ 15 tasks
- ≤ 500 LOC estimated total
- ≤ 10 files per task
- Every task has ≥ 1 acceptance bullet

On size gate breach: writes `suggested-breakdown.md`, sets `status: needs_split`, stops.

### 6 — Chal-Plan ⚔

`swe-team:challenge-plan` reviews `tasks.json` for implementation risks:

- Tasks with high file-churn potential
- Ordering issues (task A must run before B, but B is first)
- Missing test tasks
- Tasks that touch shared state without a clear ownership boundary

Writes `challenge-notes.md`. swe-lead can reorder or split tasks before BUILD starts.

### 7 — Build loop

For each task in `tasks.json` (respecting `depends_on`):

1. swe-lead spawns `swe-coder` with the task's context slice.
2. swe-coder implements, runs tests locally, commits once.
3. swe-lead spawns `swe-verifier-mech`. On fail: swe-coder retries (up to iteration cap).
4. swe-lead spawns `swe-verifier-sem`. On `spec_gap` or `security_fail`: replan.
5. On pass: task marked `done`.

On `stuck` event from hook (identical commits, file churn, no progress): abort.

### 8 — Verify (whole-PR)

After all tasks are `done`, one final `swe-verifier-sem` pass runs over the full `git diff <base>..HEAD`:

- `requirement_coverage_pct ≥ 70`
- `cross_task_conflicts == []`
- `security_verdict != fail` (OWASP + secret scan via `swe-team:security-review`)

Any fail triggers a replan (capped at 2 total replans).

### 9 — Ship

`swe-pr` runs `gh pr create --base <base> --body <generated>`. PR body includes:

- Summary from `spec.md`
- Per-task verification evidence
- Security issues at `warn` severity (non-blocking but visible to reviewer)

`git push --force` is blocked at hook level. No force-push, ever.

### 10 — Retro

Runs regardless of terminal status (succeeded, failed, aborted). Analyzes the run: budget efficiency, failure patterns, what worked. Writes ≥ 1 lesson to `learnings.jsonl`.

Then `swe-team:knowledge-write` routes each lesson to the configured `write_target` (local vault, Notion, or Confluence). Future runs read these lessons at startup.

---

## Run artifacts

```
.claude/swe-team/runs/<run-id>/
├── run.json                 requirement, branch, final status
├── knowledge-context.md     knowledge search results
├── pre-flight-brief.md      clarify output
├── assumptions.md           autonomous-mode assumptions
├── adversarial-notes.md     adv-spec findings
├── spec.md                  define output
├── challenge-notes.md       plan challenge findings
├── tasks.json               plan (append-only)
├── phase_state.json         current phase + counters
├── events.jsonl             full audit trail
├── build/task-<id>.jsonl    per-task coder log
├── verification.jsonl       mech + sem + security verdicts
└── pr.json                  PR URL, number, branch
```

Runs are gitignored (ephemeral audit trail). `learnings.jsonl` is also gitignored (project-local).

---

## Guards

| Guard | Default | Action on trip |
|---|---|---|
| Iteration cap | S=2 · M=4 · L=6 | Mark task `failed`; offer replan |
| Replan cap | 2 | `run_abort` with `status: failed` |
| Plan size | 500 LOC / 15 tasks | `needs_split` |
| Token ceiling | 2 000 000 | Hard stop |
| USD ceiling | $15 | Hard stop |
| Stuck: identical diff | 2× | `run_abort` |
| Stuck: file churn | 5× same file | Flag + lead decides |
| Destructive git | — | Hook blocks (exit 2) |

See [SPEC.md §8](../SPEC.md#8-guards--stop-conditions) for full detail.
