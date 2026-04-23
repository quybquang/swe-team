# Evaluation Harness — Specification

> This document specifies the evaluation harness. It does **not** implement it — implementation is future work (see SPEC §15, `tests/eval/` skeleton).

Eval-as-CI-gate is adopted from research §10 pattern 3 (Anthropic engineering blog): "A regression in agent behavior should break the build."

---

## 1. Seed Corpus

Five representative SWE tasks spanning the shape of work swe-team is expected to handle. Each task lives at `tests/eval/<task-id>/` with a fixed fixture repo.

| ID | Task | Size | Purpose |
|---|---|---|---|
| `E1-dark-mode` | Add dark mode toggle to a small Next.js app with `ThemeContext` + localStorage persistence | M | Multi-file, cross-cutting concern; stress `touch_files` discipline |
| `E2-readme-typo` | Fix three typos in `README.md` | S | Trivial; DEFINE should skip; single-commit happy path |
| `E3-util-and-test` | Add `formatCurrency(n, locale)` utility to `src/lib/` and co-located test | S | Clean TDD loop; mech verifier assertion-count gain |
| `E4-off-by-one` | Fix off-by-one bug in pagination helper; existing failing test must pass | M | Bug-fix with failing→passing test; exercises flaky-retry guard |
| `E5-api-endpoint` | Add `GET /api/health` endpoint returning `{ status, version, uptime_s }`; add integration test | M | New surface; exercises PLAN decomposition; scope discipline when test harness is adjacent |

Each fixture is a minimal repo (one package.json, minimal deps) checked into `tests/eval/<task-id>/fixture/`. Running the harness copies the fixture into a temp dir and invokes `/swe-team` with the canned requirement.

---

## 2. Grading Rubric

For each eval run, five binary checks plus one scalar:

| Check | Pass condition | Weight |
|---|---|---|
| PR opened | `pr.json` exists, `url` populated | Binary — gate |
| All tests pass | `git checkout <pr-head> && <test_cmd>` exits 0 | Binary — gate |
| Scope respected | Every file in PR diff ∈ union of task `touch_files` | Binary |
| No hallucination | Every `verification{verified:true}` event has valid `commit_sha` that resolves in git | Binary |
| Cost within budget | `budget.json.total_usd <= config.max_usd` AND same for tokens | Binary |
| Replan count | `phase_state.replan_count` | Scalar (lower is better) |

**Task passes iff** all binary checks pass. Replan count is reported but not a gate.

---

## 3. Metrics

Aggregated across the corpus:

### 3.1 Primary metrics

| Metric | Definition | Target (v0.1) |
|---|---|---|
| `pass@1` | Share of tasks passing all binary checks on first attempt | ≥ 3/5 |
| `scope_violation_rate` | Share of tasks with ≥1 `out_of_scope_files` in any sem verdict | 0/5 |
| `test_gaming_rate` | Share of tasks where mech verifier flagged deletion / `.skip` / assertion drop | 0/5 |
| `mean_cost_per_task_usd` | Average `budget.total_usd` across tasks | ≤ $3 |
| `mean_tasks_per_run` | Average `tasks.json.tasks.length` at end of run | — |
| `replan_rate` | Share of runs with `replan_count > 0` | ≤ 2/5 |

### 3.2 Secondary metrics (diagnostic)

- `mean_iterations_per_task` — convergence speed
- `stuck_event_rate` — share of runs emitting any `stuck` event
- `mech_then_sem_pass_rate` — share of commits where mech passes but sem fails (signal of semantic gaps mech can't catch)
- `phase_duration_p50_s` — median wall-clock per phase

Computed by reading `events.jsonl` with jq (see `docs/TELEMETRY.md`).

---

## 4. Harness Layout

```
tests/eval/
├── run-eval.sh                 # top-level runner (spec'd, not implemented)
├── grade.sh                    # reads a run dir, emits grading JSON
├── E1-dark-mode/
│   ├── REQ.md                  # canned requirement text passed to /swe-team
│   ├── EXPECTED.md             # human-readable expected behavior, for rubric reference
│   ├── fixture/                # minimal repo copied to temp dir per run
│   └── run.sh                  # per-task script: copy fixture, invoke /swe-team, grade
├── E2-readme-typo/ ...
├── E3-util-and-test/ ...
├── E4-off-by-one/ ...
└── E5-api-endpoint/ ...
```

### 4.1 `REQ.md`

Plain text the user would type after `/swe-team`. E.g. for E1:

```
Add a dark mode toggle. The theme state should persist across reloads via localStorage.
Default to the OS preference on first visit. Place the toggle in the top-right header.
```

### 4.2 `EXPECTED.md`

Bullet-level description of acceptance criteria + forbidden changes. Used by the human running the harness to spot-check, not by the grader (grader is mechanical).

### 4.3 `run.sh`

```
#!/usr/bin/env bash
set -euo pipefail
TMP=$(mktemp -d)
cp -R fixture/ "$TMP/repo"
cd "$TMP/repo"
git init && git add -A && git commit -m "init"
# invoke /swe-team via Claude Code CLI with REQ.md content
# — exact invocation is Claude Code CLI dependent; harness implementation task
# grade.sh reads .claude/swe-team/runs/<latest>/ and emits JSON
```

(Implementation deferred — see SPEC §13 out-of-scope / §15 appendix.)

---

## 5. How to Run (Future)

```bash
# Run full corpus
./tests/eval/run-eval.sh

# Run single task
./tests/eval/E1-dark-mode/run.sh

# Compare two runs
./tests/eval/compare.sh <run-id-a> <run-id-b>
```

Output is a markdown digest per run + a rollup JSON.

---

## 6. Comparison-to-Self (Regression Tracking)

The harness is valuable primarily for **regression detection across spec changes**, not absolute benchmarking.

Workflow:

1. Before a SPEC change, run the corpus: `./tests/eval/run-eval.sh > eval-baseline.json`
2. Apply the SPEC change + corresponding code change.
3. Run again: `./tests/eval/run-eval.sh > eval-after.json`
4. `./tests/eval/compare.sh eval-baseline.json eval-after.json` — diffs metrics, fails CI if any primary metric regresses by >X%.

**Regression thresholds** (proposed):
- `pass@1` must not decrease
- `scope_violation_rate` must remain 0
- `test_gaming_rate` must remain 0
- `mean_cost_per_task_usd` may increase by at most 20% (justified in PR)

---

## 7. Integration with CI

Eval is heavy — full corpus = ~5 runs × ~$3 each = ~$15 per CI execution. Not suitable per-commit.

Proposed cadence:
- **Per PR to `main`**: run `E2-readme-typo` and `E3-util-and-test` only (cheap S-sized smoke)
- **Nightly**: full corpus, compared against previous night
- **Before release tag**: full corpus, gated

The full harness is not part of MVP (SPEC §13). This document defines the skeleton so we can ship it incrementally.

---

## 8. What This Eval Does NOT Do

- **Absolute SWE-bench-style scoring**: that requires hundreds of tasks and is out of scope.
- **Cross-model comparison**: we test swe-team as configured, not swap model matrices.
- **Adversarial tasks**: no jailbreak prompts, no malicious fixtures. Threat model (SPEC §12) lives elsewhere.
- **Measure PR review quality**: only mechanical checks on what swe-team produced; humans still review.

---

## 9. Success Criteria for v0.1

- Harness layout exists (`tests/eval/<task-id>/` directories with REQ.md + EXPECTED.md + fixture/).
- Two tasks runnable end-to-end (`E2-readme-typo`, `E3-util-and-test`).
- `grade.sh` produces rubric JSON from a run directory.
- Documented invocation in README.

Full corpus and CI integration are v0.2+.

---

*Cross-reference: SPEC §9 (verification protocol drives the rubric), §10 (config drives cost gates), `docs/TELEMETRY.md` (metric extraction via jq), `docs/ANTI_PATTERNS.md` (what the rubric is watching for).*
