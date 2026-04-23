---
name: swe-team:budget-check
description: Read budget.json, compute percent of token/USD ceiling used, emit budget_warn at warn_pct or budget_stop at 100 percent. Hook-invoked on PreToolUse(Task); also callable from swe-lead.
---

# Budget Check

## Overview
Runaway cost is a failure mode a non-trivial fraction of the time. This skill is the last arithmetic between a runaway loop and the user's wallet. On every `Task` spawn, the `budget-gate.sh` hook calls this logic; at `>= warn_pct` it emits `budget_warn`; at `>= 100%` it emits `budget_stop` and exits 2, which blocks the spawn. swe-lead can also invoke pre-spawn to decide whether to condense context or bail.

## When to Use
- Hook `PreToolUse` with `matcher: "Task"` — always.
- swe-lead reasoning about whether to re-plan or proceed.
- Post-run audit to generate a cost report.

## When NOT to Use
- As a replacement for the hook — the hook is the enforceable chokepoint; the skill is the reference logic.
- On non-Task tool uses — cost attribution is per subagent; Edit/Bash etc. are accounted inside the spawning agent.
- Before `budget.json` exists — `init-run.sh` must have seeded it first.

## Process
1. Read state.
   ```bash
   B=.claude/swe-team/runs/current/budget.json
   [ -f "$B" ] || { echo "no budget.json"; exit 0; }
   TOKENS=$(jq -r '.total_tokens // 0' "$B")
   USD=$(jq -r '.total_usd // 0' "$B")
   MAX_TOKENS=$(jq -r .budget.max_tokens swe-team.config.json)
   MAX_USD=$(jq -r .budget.max_usd swe-team.config.json)
   WARN_PCT=$(jq -r .budget.warn_pct swe-team.config.json)
   ```
2. Compute percentages.
   ```bash
   TOK_PCT=$(awk "BEGIN{printf \"%.2f\", ($TOKENS/$MAX_TOKENS)*100}")
   USD_PCT=$(awk "BEGIN{printf \"%.2f\", ($USD/$MAX_USD)*100}")
   PCT=$(awk "BEGIN{print ($TOK_PCT>$USD_PCT)?$TOK_PCT:$USD_PCT}")
   ```
3. Hard stop at 100 percent.
   ```bash
   STOP=$(awk "BEGIN{print ($PCT>=100)?1:0}")
   if [ "$STOP" -eq 1 ]; then
     jq -nc \
       --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
       --arg ts "$(date -u +%FT%TZ)" \
       --argjson tokens $TOKENS --argjson usd $USD \
       '{kind:"budget_stop", ts:$ts, run_id:$rid, agent:"system", tokens:$tokens, usd:$usd}' \
       >> .claude/swe-team/runs/current/events.jsonl
     # Hook returns exit 2 to BLOCK the Task tool spawn
     exit 2
   fi
   ```
4. Warn at or above `warn_pct`.
   ```bash
   WARN=$(awk "BEGIN{print ($PCT>=$WARN_PCT)?1:0}")
   if [ "$WARN" -eq 1 ]; then
     # idempotent: only emit if we haven't warned at this tier already
     ALREADY=$(grep -c '"kind":"budget_warn"' .claude/swe-team/runs/current/events.jsonl || echo 0)
     if [ "$ALREADY" -eq 0 ]; then
       jq -nc \
         --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
         --arg ts "$(date -u +%FT%TZ)" \
         --argjson pct $PCT --argjson tokens $TOKENS --argjson usd $USD \
         '{kind:"budget_warn", ts:$ts, run_id:$rid, agent:"system",
           pct:$pct, tokens:$tokens, usd:$usd}' \
         >> .claude/swe-team/runs/current/events.jsonl
     fi
   fi
   exit 0
   ```
5. swe-lead's view: read the latest budget_warn/budget_stop and factor into re-plan decisions.
   ```bash
   jq -c 'select(.kind=="budget_warn" or .kind=="budget_stop")' \
     .claude/swe-team/runs/current/events.jsonl | tail -n 1
   ```

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "We're at 101% but this next task is small." | Hard stop is hard. Exit 2. The user can raise the ceiling and re-run. |
| "Skip the warning; the user will see it later." | Warnings unblock decisions (condense context, re-plan). Silence hurts transparency. |
| "Tokens are under, USD is over — ship it." | `PCT = max(token_pct, usd_pct)`. Either ceiling trips the stop. |
| "I'll estimate tokens instead of reading budget.json." | Estimates drift. The file is the SoT; read it. |
| "Hook already ran; skill call is redundant." | The hook enforces; the skill is the logic the hook and lead share. Deduped by the idempotent guard in step 4. |

## Red Flags
- `budget.json` missing mid-run — init-run.sh did not run or was clobbered; abort.
- `total_tokens` or `total_usd` decreased since last check — state corruption; treat as abort.
- `max_tokens == 0` or `max_usd == 0` in config — misconfig; fail closed with non-zero exit.
- Multiple `budget_stop` events in the same run — hook is not blocking Task; infra broken.

## Verification
After this skill runs:
- If under `warn_pct`: no new events; exit 0.
- If between `warn_pct` and 100%: at most one `budget_warn` per tier (idempotent); exit 0.
- If `>= 100%`: one `budget_stop` event per invocation; exit 2 (blocks the Task spawn at the hook layer).
- Emitted events match `event-schema.json` (required `pct`/`tokens`/`usd` for warn; `tokens`/`usd` for stop).
