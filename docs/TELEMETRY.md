# Telemetry — File-Based Observability

> swe-team emits no metrics to external collectors. The run directory is the trace. Analysis is post-hoc via `jq` on `events.jsonl` and `build/task-*.jsonl`.

Design basis: research §10 pattern 3 (Anthropic engineering blog) — **`events.jsonl` is the OpenTelemetry-equivalent trace**, without the collector. Research §3 validates this pattern via OpenHands' EventStream.

---

## 1. `events.jsonl` as the Trace

Every system-significant action is an append-only JSON line (SPEC §3.4):

```jsonc
{"kind":"phase_enter","ts":"2026-04-23T22:15:10Z","run_id":"2026-04-23-2215-dark-mode","agent":"swe-lead","phase":"PLAN"}
{"kind":"action","ts":"...","agent":"swe-coder","task_id":"T1","tool":"Edit","target":"src/contexts/ThemeContext.tsx","args_summary":"create file, 42 lines"}
{"kind":"observation","ts":"...","agent":"swe-coder","task_id":"T1","tool":"Bash","exit_code":0,"stdout_sha256":"sha256:...","summary":"tests passed 47/47"}
{"kind":"verification","ts":"...","agent":"swe-verifier-mech","task_id":"T1","tier":"mech","verified":true,"evidence":{...}}
```

Per-task coder actions live in `build/task-<id>.jsonl` (SPEC §3.1); everything else lives in `events.jsonl`.

---

## 2. Useful jq One-Liners

All examples assume `cd .claude/swe-team/runs/current/`.

### 2.1 Event distribution

```bash
jq -r '.kind' events.jsonl | sort | uniq -c | sort -rn
```

Output shape:
```
  12 action
   8 observation
   5 verification
   3 phase_enter
   3 phase_exit
   1 run_complete
```

### 2.2 Time per phase

```bash
jq -r 'select(.kind=="phase_enter" or .kind=="phase_exit") | [.ts, .kind, .phase // "-"] | @tsv' events.jsonl
```

Pipe to awk for deltas:
```bash
jq -r 'select(.kind=="phase_enter" or .kind=="phase_exit") | [.ts, .kind, .phase // "-"] | @tsv' events.jsonl \
  | awk 'BEGIN{FS="\t"} {print $0}'
```

### 2.3 Verifier verdict counts

```bash
# mech pass/fail
jq -r 'select(.kind=="verification" and .tier=="mech") | .verified' events.jsonl verification.jsonl \
  | sort | uniq -c

# sem pass/fail
jq -r 'select(.kind=="verification" and .tier=="sem") | .verified' verification.jsonl \
  | sort | uniq -c
```

### 2.4 Stuck detection

```bash
jq -r 'select(.kind=="stuck") | [.ts, .task_id, .pattern, .details] | @tsv' events.jsonl
```

If this returns nothing, the run did not stall. If it returns any rows, check SPEC §8 for the matching pattern and inspect the surrounding events.

### 2.5 Budget burn

```bash
# Running total over time
jq -r 'select(.kind=="budget_warn" or .kind=="budget_stop") | [.ts, .kind, .pct, .tokens, .usd] | @tsv' events.jsonl

# Final state
jq '.' budget.json
```

### 2.6 Replan audit

```bash
jq -r 'select(.kind=="replan") | [.ts, .count, .reason, (.appended_task_ids | join(","))] | @tsv' events.jsonl
```

### 2.7 Scope violations by task

```bash
jq -r 'select(.kind=="verification" and .tier=="sem" and (.evidence.scope_diff_clean | not)) | [.task_id, (.evidence.out_of_scope_files | join(","))] | @tsv' verification.jsonl
```

### 2.8 Test-gaming flags

```bash
jq -r 'select(.kind=="verification" and .tier=="mech" and .verified==false) | [.task_id, .reason] | @tsv' verification.jsonl
```

### 2.9 Iteration counts per task

```bash
# action events per task (rough iteration proxy)
for f in build/task-*.jsonl; do
  task=$(basename "$f" .jsonl)
  count=$(wc -l < "$f")
  echo "$task: $count events"
done
```

### 2.10 Full timeline for a single task

```bash
TASK=T1
jq -r --arg t "$TASK" '. | select(.task_id==$t) | [.ts, .agent, .kind, .summary // .reason // ""] | @tsv' \
  events.jsonl build/task-$TASK.jsonl verification.jsonl \
  | sort
```

---

## 3. Healthy Run vs Stuck Run

### 3.1 Healthy run signature

- Event count scales with task count: roughly `10 + 8 × task_count` events total.
- Each task has: ≥1 `action`, ≥1 `observation`, exactly 1 `verification{tier:mech,verified:true}`, exactly 1 `verification{tier:sem,verified:true}`.
- No `stuck` events.
- No `budget_warn` or at most one near end.
- `phase_enter`/`phase_exit` counts match per phase.
- `run_complete` terminal event present.

Example distribution for a 3-task run:
```
   3 phase_enter
   3 phase_exit
  15 action
  12 observation
   6 verification   # 3 mech + 3 sem
   1 run_complete
```

### 3.2 Stuck run signature

- Same task_id appearing in many `action` events without a successful `verification`.
- Repeated `stdout_sha256` across observations for the same task.
- `stuck` event present.
- Missing `run_complete`; terminal event is `run_abort`.
- Budget burn disproportionate to task count.
- `replan` events piling up (`count > 2` → abort).

Red-flag distribution:
```
   1 phase_enter
   0 phase_exit       # never exited BUILD
  40 action           # excessive for 1 task
  40 observation
   0 verification
   3 stuck
   1 run_abort
```

### 3.3 Diagnostic flowchart

```
events.jsonl empty?           → init-run.sh failed; check SessionStart hook
No phase_exit for PLAN?       → swe-lead never produced valid tasks.json
Many actions, 0 verifications → coder looping without commits
stuck events present          → read .pattern, map to SPEC §8
budget_stop terminal          → cost ceiling tripped; see budget.json
run_abort with replan_count>2 → lead exhausted replans
```

---

## 4. `scripts/run-summary.sh` (Sketch — Not Implemented)

A proposed tool that produces a markdown digest of the latest run. **Sketch only — implementation is future work.**

Intended behavior:

```bash
./scripts/run-summary.sh                  # latest run
./scripts/run-summary.sh <run-id>         # specific run
./scripts/run-summary.sh --all            # all runs, table format
```

### 4.1 Output shape (markdown)

```markdown
# Run Summary — 2026-04-23-2215-dark-mode

**Status**: succeeded
**Duration**: 8m 42s
**Cost**: $2.14 (327k tokens)
**Branch**: swe/dark-mode-2026-04-23-2215
**PR**: https://github.com/org/repo/pull/142

## Phases
| Phase   | Duration | Exit |
|---------|----------|------|
| DEFINE  | skipped  | —    |
| PLAN    | 45s      | ok   |
| BUILD   | 6m 12s   | ok   |
| VERIFY  | 58s      | ok   |
| SHIP    | 47s      | ok   |

## Tasks
| ID | Title             | Size | Iterations | Mech | Sem  |
|----|-------------------|------|------------|------|------|
| T1 | Add ThemeContext  | S    | 1          | pass | pass |
| T2 | Add toggle UI     | M    | 2          | pass | pass |
| T3 | Wire localStorage | S    | 1          | pass | pass |

## Events
- 3 `phase_enter`, 3 `phase_exit`
- 17 `action`, 14 `observation`
- 6 `verification` (6 verified:true)
- 0 `stuck`, 0 `replan`, 0 `blocker`
- 0 `budget_warn`

## Anomalies
(none)
```

### 4.2 Implementation outline

Roughly 40 lines of bash composing the jq queries from §2 above:

```
run_dir=.claude/swe-team/runs/${1:-current}
# header from run.json + pr.json
# phase table from phase_enter/phase_exit events
# task table joining tasks.json + verification.jsonl
# event counts from § 2.1
# anomalies = any stuck/replan/blocker/budget_warn rows
```

Output piped to stdout; callers can pipe to `glow` or `bat` for rendering.

---

## 5. Cost Attribution

`budget.json` carries cumulative counters updated by a hook per Task tool invocation:

```jsonc
{
  "total_tokens": 327412,
  "total_usd": 2.14,
  "by_agent": {
    "swe-lead":          { "tokens": 41000, "usd": 0.62 },
    "swe-coder":         { "tokens": 198000, "usd": 1.10 },
    "swe-verifier-mech": { "tokens": 22000, "usd": 0.05 },
    "swe-verifier-sem":  { "tokens": 54000, "usd": 0.31 },
    "swe-pr":            { "tokens": 12000, "usd": 0.06 }
  },
  "ceiling_tokens": 2000000,
  "ceiling_usd": 15.00
}
```

`by_agent` is not currently a SPEC-required field — see `SPEC.md` §15 (Appendix A) for the proposed refinement. Current MVP tracks only totals.

---

## 6. Limits of This Telemetry

- **No live view**: `events.jsonl` is updated asynchronously; tailing it works but you may miss events during atomic Write operations.
- **No distributed trace across machines**: single-machine model only.
- **No pre-aggregated indexes**: every query scans the file. Fine for runs producing <10k events; large runs may need jq `--stream` or a sqlite load.
- **No PII redaction on stdout summary fields**: if a test error message contains a secret, it may land in `summary`. Coder-loop skill warns against capturing secrets; not enforced programmatically in MVP.

---

*Cross-reference: SPEC §3 (schema), §7 (hook contracts that emit events), `docs/EVAL.md` (how metrics roll up to grading), `docs/ANTI_PATTERNS.md` (what each stuck-pattern looks like in the trace).*
