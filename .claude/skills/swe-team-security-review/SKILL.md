---
name: swe-team:security-review
description: OWASP Top 10 + secret detection pass over the full PR diff. Invoked by swe-verifier-sem in whole-PR mode. Emits security_verdict (pass|warn|fail) and security_issues[]. A fail verdict blocks SHIP. A warn verdict is recorded but does not block.
---

# Security Review

## Overview

`swe-team:security-review` is a focused, adversarial security pass over the complete diff before shipping. It runs as the final check inside `swe-verifier-sem`'s whole-PR mode, after acceptance coverage and cross-task conflict checks. It does NOT replace a human security audit. It catches the class of vulnerabilities that LLM-generated code most commonly introduces: injection vectors, direct object reference gaps, hardcoded credentials, missing auth guards, and unsafe deserialization.

Verdict levels:
- **`pass`** — no issues found; SHIP proceeds normally.
- **`warn`** — low/medium issues found; recorded in `security_issues[]` and noted in the PR body; SHIP is NOT blocked. swe-lead logs the issues so the human reviewer knows to look.
- **`fail`** — high or critical issue found; `verification` event emitted with `verified:false` and `reason:"security_fail"`; swe-lead triggers a replan.

## When to Use

- `swe-verifier-sem` is in whole-PR mode.
- `config.security.enabled == true` (default: `true`).
- A full `git diff <base>..HEAD` diff is available.
- All per-task mech + sem verdicts have already passed.

## When NOT to Use

- `config.security.enabled == false`.
- You are in per-commit (not whole-PR) mode — security review runs once at the PR level, not per commit.
- The diff is empty.
- A `security_review` event already exists in `verification.jsonl` for this `run_id` (idempotent guard).
- The diff is documentation-only (no code files changed — detected by checking that all changed files are `.md`, `.txt`, `.json`, `.yaml`).

## Process

1. Load the full diff.
   ```bash
   BASE=$(jq -r .base_branch .claude/swe-team/runs/current/run.json)
   git diff "$BASE"..HEAD > /tmp/security-diff.txt
   DIFF_SIZE=$(wc -l < /tmp/security-diff.txt)
   ```
2. Run automated secret detection.
   ```bash
   # Check for hardcoded secrets patterns
   grep -nE \
     '(password|passwd|secret|api_key|apikey|token|private_key|access_key|auth_token)\s*=\s*["\x27][^"]{6,}' \
     /tmp/security-diff.txt > /tmp/secret-hits.txt || true

   # Check for base64-encoded blobs (common credential obfuscation)
   grep -nE '[A-Za-z0-9+/]{40,}={0,2}' /tmp/security-diff.txt | \
     grep -v 'sha256\|hash\|digest\|test_output' >> /tmp/secret-hits.txt || true
   ```
3. Run OWASP Top 10 pattern checks. For each category, grep the diff:

   **A01 — Broken Access Control**
   ```bash
   # Missing auth guard (route handler without middleware check)
   grep -nE 'app\.(get|post|put|delete|patch)\s*\(' /tmp/security-diff.txt | \
     grep -v 'auth\|protect\|guard\|middleware\|requireAuth\|isAuthenticated'
   ```

   **A02 — Cryptographic Failures**
   ```bash
   grep -nE 'md5|sha1\b|DES\b|RC4\b|Math\.random\(\)' /tmp/security-diff.txt
   ```

   **A03 — Injection (SQL/Command/LDAP)**
   ```bash
   # SQL string concatenation (not parameterized)
   grep -nE '"SELECT.*"\s*\+|`SELECT.*\$\{|execute\s*\(\s*["\x27].*\+' /tmp/security-diff.txt
   # Shell injection
   grep -nE 'exec\s*\(.*\$\{|child_process.*\+|shell\s*=\s*True' /tmp/security-diff.txt
   ```

   **A05 — Security Misconfiguration**
   ```bash
   grep -nE 'DEBUG\s*=\s*True|CORS.*\*|allow_origins.*\*|ssl_verify.*False|verify\s*=\s*False' \
     /tmp/security-diff.txt
   ```

   **A07 — Identification & Authentication Failures**
   ```bash
   grep -nE 'jwt\.decode.*algorithms.*none|verify\s*=\s*False.*jwt|expir' /tmp/security-diff.txt | \
     grep -i 'skip\|ignore\|no.*expir'
   ```

   **A08 — Software and Data Integrity (deserialization)**
   ```bash
   grep -nE 'pickle\.loads|eval\s*\(|Function\s*\(\s*["\x27]|unserialize\s*\(' /tmp/security-diff.txt
   ```

   **A09 — Logging sensitive data**
   ```bash
   grep -nE '(console\.log|logger\.(info|debug|error))\s*\(.*password|token|secret' \
     /tmp/security-diff.txt
   ```

4. For each hit found in steps 2–3, classify severity:
   - **critical**: Hardcoded secrets, SQL injection, command injection, JWT without verification.
   - **high**: Missing auth guard on state-mutating routes, dangerous deserialization, disabled SSL.
   - **medium**: Weak crypto (MD5/SHA1 for security purposes), CORS wildcard, sensitive data logged.
   - **low**: Weak crypto for non-security use (checksum), noisy grep hits in comments/tests.
5. For grep hits in test files or comments, downgrade by one severity level.
6. Apply verdict rule:
   - Any `critical` or `high` → `verdict: fail`
   - Any `medium` (and no critical/high) → `verdict: warn`
   - Only `low` or no hits → `verdict: pass`
7. Append event to `verification.jsonl`:
   ```bash
   jq -nc \
     --arg rid "$(jq -r .run_id .claude/swe-team/runs/current/run.json)" \
     --arg ts "$(date -u +%FT%TZ)" \
     --arg verdict "$VERDICT" \
     --argjson issues "$ISSUES_JSON" \
     '{kind:"security_review",ts:$ts,run_id:$rid,agent:"swe-verifier-sem",
       security_verdict:$verdict,
       security_issues:$issues}' \
     >> .claude/swe-team/runs/current/verification.jsonl
   ```
   Where `$ISSUES_JSON` is a JSON array of objects: `{severity, category, file, line, snippet}`.
8. If `verdict == fail`: swe-verifier-sem emits `verified:false` with `reason:"security_fail"` (swe-lead will replan with the coder fixing the vulnerability). If `verdict == warn`: proceed with SHIP but include `security_issues` in the PR body. If `verdict == pass`: proceed normally.

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "This is a demo/dev project; security doesn't matter here." | `swe-team` is designed for production-grade work. The install target is real repos. The security check protects the install target, not this package. |
| "The grep hits are false positives in test files." | Step 5 explicitly downgrades test-file hits. If the hit is truly a false positive, document it in `reasoning` — don't simply skip the check. |
| "The coder wouldn't introduce an injection vulnerability." | OWASP A03 is the #3 most common vulnerability class in LLM-generated code (2024–2025 research). The check exists because coders make this error. |
| "A warning is just noise; I'll suppress it." | Warnings are written to the PR body as reviewer notes. The human reviewer decides whether to merge with the warning. That is the correct human gate. |
| "I'll mark critical issues as medium to avoid blocking SHIP." | Severity classification is based on the grep + context rules in steps 4–5. Downgrading without documented rationale is a protocol violation equivalent to bypassing the verifier. |

## Red Flags

- `security_issues` array contains >20 items → the codebase has structural security problems; consider `run_abort` and a dedicated security remediation pass.
- `verdict: pass` but `/tmp/secret-hits.txt` is non-empty — classification logic failed; re-examine step 4.
- The diff contains API route additions with no auth middleware and `verdict` is not `fail` — check grep pattern coverage for the specific framework.
- Grep patterns return hits in `node_modules/`, `vendor/`, or `dist/` paths — diff was too broad; scope `git diff` to `-- ':!*/node_modules'`.

## Verification

After this skill completes:
- `.claude/swe-team/runs/current/verification.jsonl` has a new line with `kind:"security_review"`.
- `security_verdict` is one of `pass`, `warn`, `fail`.
- If `verdict != pass`, `security_issues` is non-empty (at least one issue documented).
- If `verdict == fail`, the calling `swe-verifier-sem` has emitted a corresponding `verification` event with `verified:false, reason:"security_fail"`.
- Every issue in `security_issues` has: `severity`, `category`, `file`, `line`, `snippet` (≤80 chars).
