# Safety & Security Gates

> What swe-team checks before it ships — and what blocks the PR.

---

## Gates overview

| Gate | Phase | Blocks PR? | Configurable? |
|---|---|---|---|
| Spec adversarial review | ADV-SPEC | Yes — critical gaps abort | `adv_spec.enabled` |
| Plan challenge review | CHAL-PLAN | Yes — critical risks abort | `chal_plan.enabled` |
| Test pass | VERIFY mech | Yes | `verification.test_cmd` |
| Lint pass | VERIFY mech | Yes | `verification.lint_cmd` |
| Typecheck pass | VERIFY mech | Yes | `verification.typecheck_cmd` |
| Dependency CVE audit | VERIFY mech | Yes — `critical`/`high` | `dep_audit.fail_on` |
| Test deletion check | VERIFY mech | Yes | not configurable |
| `.skip`/`.only` injection | VERIFY mech | Yes | not configurable |
| Assertion count regression | VERIFY mech | Yes | not configurable |
| Acceptance criteria met | VERIFY sem | Yes | not configurable |
| Scope diff clean | VERIFY sem | Yes | not configurable |
| Breaking-change detection | VERIFY sem | Yes — undeclared breaks | `breaking_change.fail_on` |
| OWASP Top 10 scan | VERIFY sem (whole-PR) | Yes — `critical`/`high` | `security.fail_on` |
| Secret / credential scan | VERIFY sem (whole-PR) | Yes — any finding | not configurable |
| Force-push guard | hook | Yes — hard block | not configurable |
| Destructive git guard | hook | Yes — hard block | not configurable |

---

## Mechanical gates

### Tests, lint, typecheck

Run via the commands in `swe-team.config.json#verification`. All three must exit 0 for
a task commit to pass the mech tier.

```jsonc
"verification": {
  "test_cmd":      "pnpm test",
  "lint_cmd":      "pnpm lint",
  "typecheck_cmd": "pnpm typecheck"
}
```

Set to `"auto"` to detect from `package.json#scripts` each run.

### Test gaming detection

The mech verifier checks every commit for:

- **Deleted test files** — `git diff --diff-filter=D` on test globs. Any deletion → `verified: false`.
- **New `.skip` / `.only`** — grep diff for added `describe.skip`, `it.only`, `xit`, `xdescribe`. Any addition → `verified: false`.
- **Assertion count regression** — counts `expect|assert|should|require` across test dirs at run start. If count drops at any commit → `verified: false`.

These checks are not configurable. They exist because coder agents under pressure will
sometimes "pass" tests by deleting or disabling them. Evidence-over-assertion means the
verifier must catch this mechanically.

### Dependency CVE audit

`swe-team:dep-audit` runs during the mech tier. It checks `package.json` / `go.mod` /
`requirements.txt` for known CVEs using the package manager's built-in audit tool:

- npm/pnpm/yarn: `npm audit --json`
- Go: `govulncheck ./...` (if installed)
- Python: `pip-audit` (if installed)

Configure blocking severity in `swe-team.config.json`:

```jsonc
"dep_audit": {
  "enabled": true,
  "fail_on": ["critical", "high"],
  "warn_on": ["moderate"]
}
```

`fail_on` items block the PR. `warn_on` items appear in the PR body for the reviewer.

---

## Semantic gates

### Acceptance criteria

Each task in `tasks.json` has `acceptance` bullets. The sem verifier checks each bullet
against the diff and must cite `file:line` evidence for every claim. No evidence → the
bullet is marked unmet → `verified: false`.

Hedging language (`probably`, `should work`, `looks correct`) in a verdict causes the
`swe-team:anti-rationalize` skill to reject it and force a re-run.

### Scope audit

Every file in the commit diff must appear in the task's `touch_files` list. Out-of-scope
edits → `verified: false` with `out_of_scope_files` list. This prevents coder from
silently modifying files outside the declared task boundary.

### Breaking-change detection

`swe-team:breaking-change` scans the diff for:

- Removed or renamed exported functions, types, constants
- Changed function signatures (added required params, removed optional ones)
- API route changes (method, path, response shape)
- Database schema drops or renames

Configure blocking behaviour:

```jsonc
"breaking_change": {
  "enabled": true,
  "fail_on": ["api", "schema"],
  "warn_on": ["export"]
}
```

An undeclared breaking change in a `fail_on` category → `verified: false`. The task must
be replanned with a migration or versioning strategy.

---

## Security gate (whole-PR)

Runs once at the end of BUILD, over the full `git diff <base>..HEAD`.

### OWASP Top 10 scan

`swe-team:security-review` greps the diff for patterns in each OWASP category:

| Category | Example patterns checked |
|---|---|
| A01 — Broken Access Control | route handlers missing auth middleware |
| A02 — Cryptographic Failures | hardcoded secrets, `MD5`/`SHA1` for passwords |
| A03 — Injection | string concatenation in SQL/shell, missing `parameterize` |
| A04 — Insecure Design | `TODO: add auth later`, public endpoints on sensitive routes |
| A05 — Security Misconfiguration | `debug: true` in production config, CORS `*` |
| A06 — Vulnerable Components | flagged by dep-audit above |
| A07 — Auth Failures | JWT `alg: none`, missing expiry |
| A08 — Integrity Failures | missing integrity check on external resources |
| A09 — Logging Failures | passwords/tokens logged to console |
| A10 — SSRF | user-controlled URLs in server-side fetch |

### Secret / credential scan

Checks diff for patterns matching:

- API keys (`sk-`, `AIza`, `AKIA`, etc.)
- Private keys (`-----BEGIN`)
- Connection strings with passwords
- Bearer tokens in code

Any secret finding blocks the PR — there is no `warn` level for secrets.

### Verdicts and actions

| Verdict | Condition | Action |
|---|---|---|
| `pass` | No issues | PR proceeds |
| `warn` | Only `medium`/`low` issues | PR proceeds; issues listed in PR body |
| `fail` | Any `critical` or `high` issue | Blocks SHIP; triggers replan to fix |

Configure thresholds:

```jsonc
"security": {
  "enabled": true,
  "fail_on": ["critical", "high"],
  "warn_on": ["medium"]
}
```

---

## Git guards (hooks)

Two hooks run at the shell level and cannot be bypassed by agents:

### `guard-destructive-git.sh`

Blocks any `Bash` tool call matching:

- `git push --force` / `git push -f`
- `git reset --hard`
- `git rebase -i`
- `rm -rf .git`
- `git branch -D` (unless on a `swe/` branch)

Exit code 2 — Claude Code treats this as a blocked tool call and the agent cannot proceed
with the destructive command.

### No force-push, ever

`swe-pr` is explicitly instructed never to force-push. The hook provides the mechanical
backstop. Both layers must be present because an agent could in theory be instructed to
bypass its own instructions; the hook cannot be overridden by agent text.

---

## Definition of Done (DoD)

A task is only marked `done` when ALL of the following are true:

1. `test_exit == 0`
2. `lint_exit == 0`
3. `typecheck_exit == 0`
4. `deleted_test_files == []`
5. `new_skip_or_only_count == 0`
6. `assertion_count >= assertion_baseline`
7. `acceptance_missing == []`
8. `scope_diff_clean == true`
9. `reasoning_cites_evidence == true`

A PR only ships when ALL tasks are `done` AND the whole-PR pass clears:

10. `requirement_coverage_pct >= 70`
11. `cross_task_conflicts == []`
12. `security_verdict != fail`
13. `dep_audit_verdict != fail`
14. `breaking_change_verdict != fail` (for declared `fail_on` categories)

Configure items 10–14 in `swe-team.config.json`. Items 1–9 are not configurable.
