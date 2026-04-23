---
name: swe-team:anti-rationalize
description: Enforcement skill that rejects hedging language in verifier verdicts — probably, should work, looks correct, seems fine, I think — unless backed by explicit evidence citations. Invoked by both mech and sem verifiers before finalizing a verdict.
---

# Anti-Rationalize

## Overview
Verifier LLMs drift toward agreeable, fuzzy verdicts. This skill is the adversarial counter-pressure: it lexically scans the draft verdict for hedge tokens and citation gaps and rejects anything that fails. A rejected verdict is NOT allowed to pass through — the verifier must rewrite with stricter grounding (or flip to `verified:false`). Without this skill, sem verification collapses into rubber-stamp approval.

## When to Use
- Called by `swe-team:verify-semantic` before appending a sem verdict to `verification.jsonl`.
- Called by `swe-team:verify-mechanical` when a `reason` string is being written (e.g. on `verified:false`).
- Whenever a verifier is about to claim `verified:true` — always pass through this skill first.

## When NOT to Use
- Coder, lead, or PR skills — those are not verdicts.
- Evidence fields that are pure numbers/arrays (`assertion_count`, `deleted_test_files`) — this skill only reviews prose.
- Programmatic pipelines that don't produce a reasoning string.

## Process
1. Receive the draft verdict object containing at minimum `reasoning` (string) and `acceptance_met` (array).
2. Hedge token scan — case-insensitive whole-word/phrase match against:
   ```
   probably
   should work
   looks correct
   looks good
   looks fine
   seems fine
   seems ok
   seems correct
   i think
   i believe
   pretty sure
   more or less
   basically
   essentially
   ```
   Shell check:
   ```bash
   if printf '%s' "$REASONING" | grep -qiE '\b(probably|should work|looks (correct|good|fine)|seems (fine|ok|correct)|i (think|believe)|pretty sure|more or less|basically|essentially)\b'; then
     echo "REJECT: hedge tokens present"
     exit 1
   fi
   ```
3. Citation coverage check. Every string in `acceptance_met` must have at least one corresponding `file:line` reference in `reasoning`.
   ```bash
   CITATIONS=$(printf '%s' "$REASONING" | grep -oE '[a-zA-Z0-9_./-]+\.(ts|tsx|js|jsx|py|go|rs|java|rb|md):[0-9]+' | wc -l)
   MET_COUNT=$(printf '%s' "$MET_JSON" | jq 'length')
   if [ "$CITATIONS" -lt "$MET_COUNT" ]; then
     echo "REJECT: $CITATIONS citations for $MET_COUNT accepted bullets"
     exit 1
   fi
   ```
4. Length check (≤500 chars per schema).
   ```bash
   [ ${#REASONING} -le 500 ] || { echo "REJECT: reasoning > 500 chars"; exit 1; }
   ```
5. On any rejection, return a structured rejection to the caller:
   ```json
   {
     "accepted": false,
     "failures": ["hedge_tokens", "insufficient_citations"],
     "note": "rewrite reasoning with file:line citations and no hedging"
   }
   ```
   The caller re-runs verification with the stricter prompt. Document the rejection as a self-correction note in the next reasoning draft.
6. On acceptance, return `{"accepted": true, "reasoning_cites_evidence": true}`. The caller sets this boolean in evidence.

## Anti-Rationalizations
| Excuse | Rebuttal |
|---|---|
| "'Probably' is used as a hedge here but it's actually a factual probability." | The token list is lexical; it does not distinguish semantic nuance. Rewrite or fail. |
| "The citation is in my head — the code is obvious." | If it's obvious, writing `path.ts:42` takes 5 seconds. Do it. |
| "I already cited one file; the rest follow." | Per-bullet citations required. Each `acceptance_met[i]` needs one. |
| "Exceeding 500 chars is necessary for nuance." | Schema cap is 500. Summarize or the verdict does not serialize. |
| "Re-running will just produce the same verdict." | If so, you have a genuine `verified:false` — flip the boolean; don't dress up a failing verdict as passing. |
| "I can soften the rejection check because the verifier is Sonnet." | Model class doesn't change the rule. Grep the hedge list. |

## Red Flags
- Two consecutive rejections on the same verdict — the verifier is in a rationalization loop; escalate to lead for manual review.
- Rejection note ignored in the retry (same hedge re-appears) — hard-fail the whole verification; emit `verified:false` with `reason: anti_rationalize_loop`.
- Citation format is wrong (e.g. `ThemeContext:42` missing extension) — reject; require full path.

## Verification
After this skill returns:
- Caller has a boolean `accepted` and (if accepted) sets `reasoning_cites_evidence: true` in `verification-schema.json#sem` evidence.
- If rejected, caller has a `failures` array naming which checks tripped.
- No verdict ever reaches `verification.jsonl` with `verified:true` unless this skill returned `accepted:true`.
- Rejection counts per task do not exceed 2; on the 3rd, emit `verified:false` with `reason:"anti_rationalize_loop"`.
