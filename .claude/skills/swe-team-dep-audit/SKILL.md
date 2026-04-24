---
name: swe-team:dep-audit
description: >
  Audit new or updated dependencies for known CVEs, license compliance, and maintenance
  health. Triggered by swe-verifier-mech when the diff modifies package.json, go.mod,
  requirements.txt, Gemfile, or Cargo.toml. Emits a dep_audit event; critical CVEs block
  the mech verdict.
---

# Dependency Audit

## Overview

Every `npm install <package>` or `pip install <lib>` is a trust decision. swe-coder
can add a dependency to solve a problem — that's fine. What's not fine is adding one
without knowing whether it has a known exploit, an incompatible license, or hasn't been
maintained in three years.

This skill audits new and updated dependencies at the point they enter the codebase:
during mechanical verification, before semantic review has a chance to mask the risk.

## When to Use

- Invoked by swe-verifier-mech when the diff contains changes to a known dependency manifest:
  - `package.json` or `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock`
  - `go.mod` or `go.sum`
  - `requirements.txt`, `pyproject.toml`, `Pipfile`
  - `Gemfile` or `Gemfile.lock`
  - `Cargo.toml` or `Cargo.lock`
- If no manifest file appears in the diff, this skill is a no-op — skip cleanly.

## When NOT to Use

- Do NOT run if only lock file changed (no manifest change) — lock file updates from
  hoisting are false positives.
- Do NOT run on files in `devDependencies` if `swe-team.config.json dod.audit_dev_deps`
  is `false` (default: `false`).

---

## Process

### Step 1 — Identify new/changed dependencies

```bash
git diff <base_branch>..HEAD -- package.json go.mod requirements.txt pyproject.toml Pipfile Gemfile Cargo.toml
```

Parse the diff to extract only **added** or **version-bumped** packages. Do NOT audit
packages that were removed (no incoming risk).

For npm/pnpm/yarn:
```bash
git diff <base_branch>..HEAD -- package.json | grep '^+' | grep -E '"[^"]+"\s*:\s*"[^"]+"' | grep -v '"name"' | grep -v '"version"'
```

For Go:
```bash
git diff <base_branch>..HEAD -- go.mod | grep '^+' | grep 'require'
```

For Python:
```bash
git diff <base_branch>..HEAD -- requirements.txt pyproject.toml | grep '^+'
```

Record: list of `{name, version, ecosystem}` tuples.

### Step 2 — CVE scan

Run the appropriate tool if available. Degrade gracefully if tool is not installed.

**npm/pnpm/yarn** (Node.js):
```bash
npm audit --json 2>/dev/null || pnpm audit --json 2>/dev/null || echo '{"vulnerabilities":{}}'
```
Parse JSON output. Extract `vulnerabilities` keyed by package name. Check if any
new dependency appears in the vulnerability list.

**Python** (pip-audit preferred, safety fallback):
```bash
pip-audit --format json 2>/dev/null || safety check --json 2>/dev/null || echo '[]'
```

**Go**:
```bash
govulncheck ./... 2>/dev/null || echo 'govulncheck not available'
```

**Fallback** (any ecosystem, tool unavailable):
- Log `"dep_audit_tool_unavailable": true` in the event.
- Do NOT fail the build for tool unavailability — emit `dep_audit_verdict: skipped` with reason.

For each new/changed package, record:
- `cve_count_critical`, `cve_count_high`, `cve_count_medium`, `cve_count_low`
- `cve_ids[]` — list of CVE IDs if available

### Step 3 — License check

For npm packages, check license field:

```bash
npm info <package> license 2>/dev/null
```

Or parse from `node_modules/<package>/package.json` if already installed.

| License category | Action |
|---|---|
| MIT, ISC, BSD-2-Clause, BSD-3-Clause, Apache-2.0, Unlicense | `pass` — permissive |
| LGPL-2.1, LGPL-3.0 | `warn` — copyleft but generally safe for app dependencies |
| GPL-2.0, GPL-3.0, AGPL-3.0 | `flag` — strong copyleft; may impose obligations on proprietary code |
| Unknown / no license | `flag` — cannot assess |
| CC-BY-NC, custom commercial restriction | `flag` — non-commercial or restricted |

Record: `{package, license, license_category}` for each new package.

### Step 4 — Maintenance health (npm only — best effort)

```bash
npm info <package> time.modified 2>/dev/null
```

If `time.modified` is more than **2 years** ago relative to today's date, record:
```json
{"package": "<name>", "last_published": "<date>", "stale": true}
```

This is advisory only — does not affect verdict.

### Step 5 — Apply verdict rule

`dep_audit_verdict` values:

| Condition | Verdict |
|---|---|
| Any new dep has `critical` or `high` CVE | `fail` |
| Any new dep has `flag` license | `warn` |
| Any new dep has `medium` CVE only (no critical/high) | `warn` |
| Tool unavailable | `skipped` |
| All new deps pass CVE + license | `pass` |

`fail` blocks the mech tier verdict: `verified: false` with `reason: "dep_audit_fail"`.
`warn` does NOT block; recorded in `dep_audit` event and surfaced in PR body.
`skipped` does NOT block; noted as limitation in PR body.

Override: `swe-team.config.json dod.dep_audit_fail_on` may include `["medium"]` to
promote medium CVEs to fail. Default: only `["critical", "high"]` fail.

### Step 6 — Emit event

Append to `.claude/swe-team/runs/current/verification.jsonl`:

```json
{"kind":"dep_audit","ts":"<iso8601>","run_id":"<id>","task_id":"<T_i>",
 "dep_audit_verdict":"warn",
 "packages_audited":3,
 "dep_audit_tool_unavailable":false,
 "vulnerabilities":[
   {"package":"lodash","version":"4.17.20","severity":"high","cve_ids":["CVE-2021-23337"]}
 ],
 "license_flags":[
   {"package":"some-lib","license":"GPL-3.0","license_category":"flag"}
 ],
 "stale_packages":[
   {"package":"old-helper","last_published":"2021-08-14","stale":true}
 ]}
```

---

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "This package is very popular — it must be safe." | Popularity ≠ security. Log4j, event-stream, and left-pad were popular. Run the audit. |
| "The CVE doesn't affect our usage path." | That's a risk assessment for a human reviewer to make, not for the build to silently accept. Record it. |
| "It's just a dev dependency." | Dev deps run on developer machines and in CI. Supply chain attacks target devDependencies specifically. |
| "npm audit returns too many false positives." | Filter for the specific new packages, not the full audit. Step 1 isolates the new risk surface. |
| "The tool isn't installed." | Emit `dep_audit_verdict: skipped` and note the limitation. Do not pretend the check passed. |
| "License analysis is overkill for a small project." | License violations scale with the project. A GPL dep in a proprietary product is a legal issue regardless of project size. |

## Red Flags

- `dep_audit_verdict: pass` on a PR that adds 5 new packages and no tool output was recorded → tool was not actually run.
- No `dep_audit` event in `verification.jsonl` despite diff containing `package.json` changes → skill was skipped without logging.
- `dep_audit_tool_unavailable: true` on every run → audit tooling is not set up in the project; recommend adding `npm audit` or `pip-audit` to the project.

## Verification

After this skill completes:
- `dep_audit` event appended to `verification.jsonl`.
- `dep_audit_verdict` is one of `pass|warn|fail|skipped`.
- `packages_audited` matches the count of new/changed packages extracted in Step 1.
- If `dep_audit_verdict: fail` → mech verifier emits `verified: false` with `reason: "dep_audit_fail"`.
- Read-only on source files.
