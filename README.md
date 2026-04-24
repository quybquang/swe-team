# swe-team

> Type a requirement. Get a PR.

A Claude Code-native agent team that takes a requirement and autonomously runs **CLARIFY → DEFINE → PLAN → BUILD → VERIFY → SHIP → RETRO** — then opens a pull request for human review. No mid-flow gates. File-based. Observable.

[![Version](https://img.shields.io/badge/version-0.2.0-blue)](#) [![Claude Code](https://img.shields.io/badge/Claude%20Code-native-blueviolet)](#) [![License](https://img.shields.io/badge/license-MIT-green)](#)

---

## How it works

```
You type:
  /swe-team "Add booking form — user picks date, time, service type"

                        ┌─────────────────────────────────────────┐
                        │              swe-lead  (Opus)            │
                        └───┬─────────────────────────────────────┘
                            │
              ┌─────────────▼──────────────┐
              │  CLARIFY                   │  Asks 3–5 forcing questions
              │  → pre-flight-brief.md     │  (or auto-resolves from repo)
              └─────────────┬──────────────┘
                            │
              ┌─────────────▼──────────────┐
              │  DEFINE  (if ambiguous)    │  Expands req → spec.md
              │  → acceptance bullets      │  with testable acceptance criteria
              └─────────────┬──────────────┘
                            │
              ┌─────────────▼──────────────┐
              │  PLAN                      │  Decomposes into tasks
              │  → tasks.json              │  ≤15 tasks · ≤500 LOC · ≤10 files/task
              └─────────────┬──────────────┘
                            │
              ┌─────────────▼──────────────┐   ┌─────────────────────────┐
              │  BUILD  (per task)         │──▶│  swe-coder  (Sonnet)    │
              │                            │   │  1 task → 1 commit      │
              └─────────────┬──────────────┘   └─────────────────────────┘
                            │
              ┌─────────────▼──────────────┐   ┌─────────────────────────┐
              │  VERIFY  (per commit)      │──▶│  swe-verifier-mech      │
              │                            │   │  tests · lint · typecheck│
              │                            │──▶│  swe-verifier-sem       │
              │                            │   │  acceptance · scope ·   │
              │                            │   │  security (OWASP)       │
              └─────────────┬──────────────┘   └─────────────────────────┘
                            │
              ┌─────────────▼──────────────┐   ┌─────────────────────────┐
              │  SHIP                      │──▶│  swe-pr  (Sonnet)       │
              │                            │   │  gh pr create → dev     │
              └─────────────┬──────────────┘   └─────────────────────────┘
                            │
              ┌─────────────▼──────────────┐
              │  RETRO                     │  Writes lessons learned
              │  → learnings.jsonl         │  (used in future runs)
              └────────────────────────────┘

You review the PR.
```

---

## Quickstart

**Step 1 — Install into your project**

```bash
git clone https://github.com/quybquang/swe-team
cd /path/to/your-project
/path/to/swe-team/scripts/install.sh .
```

The installer auto-detects your stack (npm/pnpm/yarn/go/python), base branch, and test/lint/typecheck commands. It merges `settings.json` without overwriting existing hooks.

**Step 2 — Commit the installed files**

```bash
git add .claude/ swe-team.config.json .gitignore
git commit -m "chore: install swe-team"
```

**Step 3 — Run it**

```bash
claude   # open Claude Code inside your project

# inside Claude Code:
/swe-team "Add a dark-mode toggle to the site header. Persist in localStorage."

# or point at a ticket:
/swe-team https://linear.app/my-team/issue/APP-42
```

The team runs autonomously. When it finishes, there's a PR waiting for your review.

---

## The team

| Agent | Model | What it does |
|---|---|---|
| `swe-lead` | Opus | Orchestrates all phases. Only agent that can re-plan. Reads `learnings.jsonl` at startup so past runs inform current decisions. |
| `swe-coder` | Sonnet | Implements one task → one commit. Never touches files outside the task's declared scope. |
| `swe-verifier-mech` | Haiku | Runs tests/lint/typecheck. Checks for deleted tests, added `.skip`/`.only`, assertion count drops. No evidence = invalid verdict. |
| `swe-verifier-sem` | Sonnet | Acceptance matching with `file:line` citations. Scope audit. OWASP security scan in whole-PR mode. Blocked unless mech passed. |
| `swe-pr` | Sonnet | Composes PR body from run state + security issues. `gh pr create`. No force-push ever. |

---

## Safety rails

| Guard | Behaviour |
|---|---|
| Iteration cap | S=2 · M=4 · L=6 retries per task before escalation |
| Re-plan cap | Max 2 re-plans per run, then abort |
| Budget ceiling | 2M tokens / $15 per run (configurable) |
| Stuck detection | Identical commits · identical test hash · file churn · no verified progress |
| Destructive git | Force push, `reset --hard`, `.git` deletion — blocked at shell level |
| VERIFY exit gate | Every non-failed task must have mech + sem `verified:true` before SHIP |
| Security gate | OWASP Top 10 + secret scan — `critical`/`high` blocks PR; `medium` annotates PR body |

---

## What's in a run

```
.claude/swe-team/runs/<run-id>/
├── run.json              requirement, branch, status
├── pre-flight-brief.md   clarify output — decisions locked before coding
├── spec.md               acceptance criteria (DEFINE phase)
├── tasks.json            the plan (append-only, never rewritten)
├── phase_state.json      current phase, active task, counters
├── events.jsonl          every phase transition, replan, abort
├── build/
│   └── task-<id>.jsonl   per-task coder actions + observations
├── verification.jsonl    mech + sem + security verdicts
└── pr.json               final PR url, number, branch

.claude/swe-team/
└── learnings.jsonl       persistent lessons across all runs (gitignored)
```

Inspect a run:

```bash
# All verdicts
jq -c '{task:.task_id, tier, ok:.verified}' .claude/swe-team/runs/current/verification.jsonl

# Security issues from last run
jq -c 'select(.kind=="security_review") | .security_issues[]' \
  .claude/swe-team/runs/current/verification.jsonl

# Lessons learned so far
cat .claude/swe-team/learnings.jsonl | jq -r '"[\(.scope)] \(.lesson)"'
```

---

## Configuration

`swe-team.config.json` at your project root (auto-generated at install). Key options:

```jsonc
{
  "clarify": {
    "mode": "autonomous"      // or "interactive" to answer questions yourself
  },
  "security": {
    "fail_on": ["critical", "high"],   // what severity blocks the PR
    "warn_on": ["medium"]              // what severity annotates the PR body
  },
  "retro": {
    "enabled": true,
    "learnings_window": 10    // how many past lessons swe-lead reads at startup
  },
  "budget": {
    "max_usd": 15.00,         // hard stop
    "warn_pct": 80            // emit warning at 80%
  }
}
```

Full schema: `.claude/references/config-schema.json`. Spec: `SPEC.md §10`.

---

## Package layout

```
swe-team/
├── SPEC.md                   Single Source of Truth — read this first
├── scripts/
│   ├── install.sh            installer (stack auto-detect, settings merge)
│   └── uninstall.sh          reverses install
├── .claude/
│   ├── agents/               5 subagent definitions
│   ├── skills/               16 skills (addyosmani format)
│   ├── hooks/                6 shell scripts (guards + event logging)
│   ├── commands/swe-team.md  /swe-team slash command
│   └── references/           JSON schemas + commit/PR/security conventions
├── docs/                     AGENT_DESIGN · ANTI_PATTERNS · EVAL · TELEMETRY
├── tests/smoke/              schema · hook · installer tests
└── examples/
    └── sample-requirement.md
```

---

## Development

```bash
./tests/smoke/run-all.sh   # 3 suites: schemas · hooks · installer
```

## Spec discipline

`SPEC.md` is the Single Source of Truth. If spec and code disagree, the code is wrong.  
To change behaviour: update the spec first, then the code, in the same commit.

## License

MIT
