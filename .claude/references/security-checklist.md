# Security checklist

Checks that `swe-verifier-sem` applies (in addition to scope and acceptance) before passing a commit. Treat these as mandatory review items — not "nice to have."

## Secrets

- [ ] No API keys, tokens, or passwords in the diff (grep for `sk_`, `ghp_`, `xox[abpr]-`, `AKIA`, `AIza`, `-----BEGIN PRIVATE KEY-----`).
- [ ] No `.env*` files committed.
- [ ] No database credentials in connection strings.
- [ ] No auth tokens embedded in test fixtures.

## Injection

- [ ] User input is not interpolated into SQL queries (look for string concat with `${}` in query builders).
- [ ] Shell commands do not concatenate user input (`exec`, `spawn`, `system` with untrusted strings).
- [ ] HTML rendering uses escaping by default (no `dangerouslySetInnerHTML` without justification).
- [ ] File paths from user input are not joined raw (path traversal).

## Auth / authz

- [ ] New API routes declare their auth requirement (middleware, decorator, guard).
- [ ] Role checks are present on routes that require them.
- [ ] No hardcoded user IDs or "admin" backdoors.

## Data exposure

- [ ] Responses don't leak PII fields the request didn't ask for.
- [ ] Error messages don't include stack traces in production paths.
- [ ] Logs don't include full request bodies of auth endpoints.

## Dependencies

- [ ] New dependencies are not deprecated or unmaintained (check last commit date).
- [ ] Pinned versions or lockfile updates accompany any `package.json`/`go.mod`/`pyproject.toml` change.
- [ ] No dependencies from unverified sources.

## When a check fails

The semantic verifier emits `verified: false` with `reason` containing the failed check name. Re-run falls back to `swe-coder` for remediation unless `max_iterations` is exhausted — in which case the task is marked `failed`.

## What's NOT covered (MVP)

- Full SAST scanning — run your existing tools (CodeQL, Semgrep, Snyk) on the PR.
- Dependency vulnerability scanning — run `npm audit` / `pip-audit` separately.
- Container image scanning.

These belong in CI, not in the swe-team run.
