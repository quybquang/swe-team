# swe-team

> A Claude Code-native agent team for production software work. Point it at a requirement, get back a PR into `dev`.

**Status**: v0.1.0 MVP. Spec-first. All behavior is defined in [`SPEC.md`](./SPEC.md) — that document is authoritative. If code disagrees with the spec, the code is wrong.

---

## What it does

1. You run `/swe-team <requirement-or-URL>` inside Claude Code.
2. An orchestrator agent (`swe-lead`) creates a run directory, expands ambiguous requirements, and produces a task plan.
3. A coder agent implements each task, one commit at a time, on a fresh `swe/…` branch.
4. Two verifier tiers check every commit — a deterministic mechanical tier (tests/lint/typecheck + test-gaming heuristics) and a semantic tier (acceptance match + scope audit + adversarial review).
5. A PR agent opens the PR into your configured base branch (`dev` by default) with a structured body derived from the event log.
6. A human reviews and merges.

Everything is file-based and observable in `.claude/swe-team/runs/<run-id>/`. Nothing leaves your machine except model API calls.

## Why multi-agent

Long-horizon single-agent runs fail on error accumulation — small mistakes at step 3/20 compound by step 15. Phase boundaries + evidence gates localize errors. The trade-off (context coherence loss) is addressed by having every agent re-read `run.json`, `tasks.json`, and `phase_state.json` at the start of every turn. See [`docs/AGENT_DESIGN.md`](./docs/AGENT_DESIGN.md) (added after OSS-research pass) for the full rationale.

## Quickstart

```bash
git clone <this-repo> swe-team
cd /path/to/your/project
/path/to/swe-team/scripts/install.sh .
git add .claude/ swe-team.config.json .gitignore
git commit -m "chore: install swe-team v0.1.0"

# Open your project in Claude Code
claude
# inside Claude Code:
/swe-team "Add a dark-mode toggle to the site header. Persist in localStorage."
```

The installer:

- Copies `.claude/agents/swe-*.md`, `.claude/skills/swe-team-*/`, the slash command, references, and hooks.
- Merges `.claude/settings.json` (preserves existing hooks).
- Auto-detects test/lint/typecheck commands from `package.json` / `go.mod` / `pyproject.toml`.
- Auto-detects the base branch (`dev` → `develop` → `main` → `master`).
- Writes `swe-team.config.json` at the repo root.
- Adds `.claude/swe-team/runs/*` to `.gitignore` (runs are local audit trail, not source).

## What lives where

```
swe-team/
├── SPEC.md                     Single Source of Truth. Read first.
├── VERSION                     Package version.
├── README.md                   This file.
├── CLAUDE.md                   Project memory (added by research pass).
├── scripts/
│   ├── install.sh              Drop into a target repo.
│   └── uninstall.sh            Reverse it.
├── .claude/
│   ├── settings.json           Hook registration.
│   ├── commands/swe-team.md    /swe-team slash command.
│   ├── agents/                 5 subagent definitions (lead, coder, 2 verifiers, pr).
│   ├── skills/                 12 skills (addyosmani format).
│   ├── references/             JSON schemas + commit/PR/security conventions.
│   ├── hooks/                  6 shell scripts for guards + event logging.
│   └── swe-team/
│       ├── VERSION             Installed version marker.
│       ├── config.default.json Config template.
│       └── runs/               Per-run audit trail (gitignored).
├── docs/                       Design docs, research, eval (populated by research pass).
├── examples/
│   └── sample-requirement.md
└── tests/
    └── smoke/                  Shell tests for schemas, hooks, installer.
```

## The 5 agents

| Agent | Model | Role |
|---|---|---|
| `swe-lead` | Opus | Orchestrates phases (DEFINE → PLAN → BUILD → VERIFY → SHIP). Only agent that re-plans. |
| `swe-coder` | Sonnet | One task → one commit. Never touches files outside the task's declared `touch_files`. |
| `swe-verifier-mech` | Haiku | Deterministic: runs tests/lint/typecheck, computes assertion delta, checks for deleted tests and added `.skip`/`.only`. Evidence or verdict is invalid. |
| `swe-verifier-sem` | Sonnet | Acceptance matching with `file:line` citations; scope audit; adversarial review. Blocked unless mech passed. |
| `swe-pr` | Sonnet | Composes the PR body from run state; `gh pr create`. No force-push. |

Full allowlists and body prompts in `.claude/agents/`.

## Guards (from `SPEC.md §8`)

- Iteration cap per task: S=2, M=4, L=6.
- Re-plan cap: 2 per run.
- Token ceiling: 2M per run. USD ceiling: $15.
- "Stuck" detection: identical commits, identical test output hash, file churn, no verified progress.
- Destructive git commands blocked at the shell (force push, `reset --hard`, `.git` deletion).
- VERIFY phase cannot exit unless every non-failed task has both mech and sem verifications with `verified: true`.

## Event log = source of truth

The model's conversation context is not the record. `.claude/swe-team/runs/<run-id>/events.jsonl` (plus `build/task-*.jsonl` and `verification.jsonl`) is. Every agent re-reads it each turn. Every claim of "work done" must be backed by a `verification` event with recomputable evidence. No evidence → no progress.

Analyse a run:

```bash
jq -c 'select(.kind=="verification") | {task: .task_id, tier, verified}' \
  .claude/swe-team/runs/<run-id>/verification.jsonl
```

## Development

```bash
# Smoke tests
./tests/smoke/run-all.sh
```

Tests cover: JSON schema validity, example documents validate, each hook script behaves (including block/allow cases), installer produces a correct layout, uninstaller cleans up.

## Spec discipline

- `SPEC.md` is the Single Source of Truth. All agents, skills, hooks, and scripts derive from it.
- If you find a mismatch: update `SPEC.md` first, update the code to match.
- Never fix code-spec drift by silently rewriting the spec to match the code. Raise the disagreement, decide, update spec, then code.

## License

TBD (MIT expected).
