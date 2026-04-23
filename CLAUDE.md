# swe-team — Project Memory

A Claude Code-native, file-based agent-team package. User issues `/swe-team <requirement|URL>`; a coordinated set of agents (lead → coder × N → verifier-mech → verifier-sem → pr) plans, builds, verifies, and opens a PR against the integration branch. All state lives under `.claude/swe-team/runs/<run-id>/`.

## Source of Truth

`SPEC.md` at repo root is the **single source of truth**. If the spec and the code disagree, the spec is right and the code is a bug. When tempted to "just fix the spec to match what the code does," stop — update the code instead, unless the spec itself is provably wrong (then update the spec first, in its own commit, with rationale).

Supporting docs that distill rationale (not authority):
- `docs/AGENT_DESIGN.md` — why the architecture is shaped this way
- `docs/ANTI_PATTERNS.md` — failure modes and how we detect them
- `docs/EVAL.md` — evaluation harness spec
- `docs/TELEMETRY.md` — file-based observability via `events.jsonl`
- `docs/research-oss-best-practices.md` — upstream research findings

## Running Smoke Tests

```bash
./tests/smoke/run-all.sh
```

Wraps `test-install.sh`, `test-hooks.sh`, `test-schemas.sh`. Run this before every commit that touches `.claude/`, `scripts/`, or schemas.

## Modifying Agent / Skill / Hook Files

1. Read the SPEC section governing the artifact (agents → §4, skills → §6, hooks → §7).
2. Make the change.
3. Update the corresponding section of `SPEC.md` **in the same commit** if the contract changed.
4. Run `./tests/smoke/run-all.sh`.
5. For skills, preserve the addyosmani anatomy: Overview → When to Use → When NOT to Use → Process → Anti-Rationalizations → Red Flags → Verification.
6. For agents, `tools` allowlists are explicit — never omit and never broaden without a SPEC update.

## Install

```bash
./scripts/install.sh <target-repo>
```

Copies `.claude/` template into the target, merges `settings.json` (project wins on key conflicts), auto-detects stack, writes `swe-team.config.json`. See SPEC §11.

## Commit Conventions

- One logical change per commit. No drive-by refactors.
- Subject line `<scope>: <imperative>` (e.g. `skill: tighten anti-rationalize hedging list`).
- Body references SPEC section when contract changes (e.g. "refines §9.1 evidence fields").
- Never commit `.claude/swe-team/runs/` — runtime state only; `.gitignore` enforces this.

## Never Do

- Never silently update `SPEC.md` so it matches drifted code. Fix the code; bump the spec only when the spec is wrong.
- Never bypass the mech verifier's evidence requirements. No "LGTM" without `commit_sha`, `test_exit`, `assertion_count`, etc. (SPEC §9.1).
- Never auto-merge a PR. Human review is the gate (SPEC §1 non-goal, §12 threat model).
- Never commit anything under `.claude/swe-team/runs/` — it's per-run ephemeral state.
- Never weaken a guard to pass a test. If `stuck` or `budget_stop` trips in CI, the fix is in the run, not in the guard.
- Never add a new top-level directory without updating SPEC §11.1.
- Never grant a subagent Bash without documenting why in the agent file and SPEC §4.
- Never `git push --force` a swe-team branch (guarded by `guard-destructive-git.sh`).
- Never add a hedging phrase to a verifier verdict. The anti-rationalize skill rejects them; keep it that way.
