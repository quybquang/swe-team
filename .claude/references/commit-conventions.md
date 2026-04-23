# Commit conventions

swe-team commits follow [Conventional Commits](https://www.conventionalcommits.org/) with a task-id trailer.

## Format

```
<type>(<scope>): <subject>

<body>

Task: <task_id>
Run: <run_id>
```

## Types

| Type | Use when |
|---|---|
| `feat` | New user-visible functionality |
| `fix` | Bug fix |
| `refactor` | Internal restructure, no behavior change |
| `test` | Tests-only change |
| `docs` | Documentation-only change |
| `chore` | Tooling, deps, config |
| `perf` | Performance improvement |

## Rules

- One task → one commit. If a task requires multiple logical changes, it should be split at PLAN time.
- Subject ≤ 72 chars. Imperative mood ("add", not "added" or "adds").
- Body explains **why**, not what (the diff shows what).
- `Task:` trailer is mandatory. The mechanical verifier reads it.
- `Run:` trailer is mandatory. Enables audit across runs.

## Example

```
feat(theme): add ThemeContext with localStorage persist

Introduces a React context so the header toggle and any future
consumer can read/write the active theme without prop drilling.

Task: T1
Run: 2026-04-23-2215-dark-mode
```

## No trailers in squash-merge

When the PR is squash-merged by a human reviewer, the PR body (authored by `swe-pr`) carries the full run summary. Trailers in individual commits are fine to drop at merge time.
