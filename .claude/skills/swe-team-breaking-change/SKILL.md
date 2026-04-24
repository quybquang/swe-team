---
name: swe-team:breaking-change
description: >
  Detect breaking changes in the full PR diff — exported function signature changes,
  DB schema mutations, API contract changes. Runs in whole-PR VERIFY mode inside
  swe-verifier-sem. Emits a breaking_change event; critical findings block SHIP unless
  explicitly acknowledged in PR body.
---

# Breaking Change Detector

## Overview

Breaking changes are the silent killers of production systems. A PR can pass every test,
satisfy every acceptance criterion, and still break callers, clients, or dependent services
that were never part of the test suite. This skill performs a targeted diff analysis across
three high-risk surface areas: exported code contracts, database schema, and API contracts.

"Breaking" means: a caller who worked before this PR will fail after it without changing
their own code.

## When to Use

- Always, in whole-PR VERIFY mode, invoked by swe-verifier-sem before the final verdict.
- Invoked via: `swe-team:breaking-change` with the full `git diff <base>..HEAD` as context.

## When NOT to Use

- Do NOT run in per-commit mode — breaking change analysis requires the full PR diff, not
  individual task commits.
- Do NOT block for breaking changes in internal (non-exported, non-public) code. Only
  public contracts matter.
- Do NOT flag a change as breaking if the file is newly created in this PR (no prior callers).

---

## Process

### Step 1 — Load full diff

```bash
git diff <base_branch>..HEAD --name-only
git diff <base_branch>..HEAD
```

Identify which files changed. Categorise by surface type:
- TypeScript/JavaScript exported symbols: files containing `export function`, `export class`,
  `export const`, `export type`, `export interface`, `export default`
- Database schema: `prisma/schema.prisma`, `*.sql`, `migrations/**`, `schema.rb`, `models.py`
  (Django), any file named `*schema*` or `*migration*`
- API contracts: `openapi.yaml`, `openapi.json`, `swagger.yaml`, `swagger.json`,
  `*.proto`, any file in `api/`, `routes/`, `controllers/` that changes response shapes

### Step 2 — TypeScript/JavaScript export analysis

For each changed file with exports:

1. Extract exported symbols from BASE version:
   ```bash
   git show <base_branch>:<file> | grep -E "^export (function|class|const|type|interface|default|async function)"
   ```

2. Extract exported symbols from HEAD version:
   ```bash
   git show HEAD:<file> | grep -E "^export (function|class|const|type|interface|default|async function)"
   ```

3. Compare:
   - **Removed export**: any symbol present in base but absent in HEAD → `BREAKING: removed export`
   - **Parameter added (required)**: function signature gained a non-optional parameter → `BREAKING: new required param`
   - **Parameter removed**: function signature lost a parameter → `BREAKING: removed param`
   - **Return type narrowed or changed**: inferred from TypeScript types in diff → `BREAKING: return type changed`
   - **Parameter made required** (was optional `?`): → `BREAKING: param no longer optional`

Skip: purely additive changes (new optional params, new exports, new overloads).

### Step 3 — Database schema analysis

For each changed schema file:

**Prisma** (`schema.prisma`):
- Column removed from a model → `BREAKING: removed column <table>.<column>`
- Column type narrowed (e.g. `String` → `String @db.VarChar(50)`) → `HIGH: column type changed`
- Column made required (added without default, no migration default) → `BREAKING: column now required`
- Model renamed → `BREAKING: model renamed`
- Relation removed → `BREAKING: relation removed`

**Raw SQL migrations**:
- `DROP COLUMN`, `DROP TABLE`, `ALTER TABLE ... DROP` → `BREAKING: destructive DDL`
- `ALTER TABLE ... ALTER COLUMN ... NOT NULL` (without DEFAULT) → `BREAKING: NOT NULL without default`
- `RENAME COLUMN`, `RENAME TABLE` → `BREAKING: rename`
- `ALTER COLUMN ... TYPE` → `HIGH: type change`

### Step 4 — API contract analysis

**OpenAPI/Swagger**:
- Response field removed → `BREAKING: response field removed`
- Request field made required → `BREAKING: new required request field`
- Endpoint removed → `BREAKING: endpoint removed`
- Status code changed → `HIGH: status code changed`

**Protobuf**:
- Field number changed → `BREAKING: proto field number changed`
- Field type changed → `BREAKING: proto field type changed`
- Field removed → `BREAKING: proto field removed`

**Express/Fastify/NestJS route changes** (heuristic — not exhaustive):
- If a route handler's response `res.json(...)` call removes a key that was present before → `HIGH: response shape changed`

### Step 5 — Classify and emit

| Severity | Meaning |
|---|---|
| `BREAKING` | Callers will fail without changes on their end |
| `HIGH` | Callers may fail depending on how they consume the contract |
| `ADVISORY` | Change is technically breaking only in edge cases |

Write `breaking_change_verdict` to `verification.jsonl`:

```json
{"kind":"breaking_change","ts":"<iso8601>","run_id":"<id>",
 "breaking_change_verdict":"fail",
 "breaking_changes":[
   {"severity":"BREAKING","surface":"export","file":"src/lib/auth.ts","line":12,
    "description":"exported function `verifyToken` lost required param `options`"},
   {"severity":"HIGH","surface":"schema","file":"prisma/schema.prisma","line":45,
    "description":"column User.email type changed from String to String @db.VarChar(100)"}
 ]}
```

`breaking_change_verdict` values:
- `pass` — no breaking or high findings
- `warn` — only HIGH or ADVISORY findings (no BREAKING) — SHIP proceeds, findings annotated in PR body
- `fail` — at least one BREAKING finding — SHIP blocked unless acknowledged

### Step 6 — Acknowledgement path

A `fail` verdict can be unblocked if `swe-team.config.json` contains:
```jsonc
"dod": { "breaking_change_flag": "acknowledge" }
```
AND the PR description draft (in `pr.json` or generated by swe-pr) contains the text
`BREAKING CHANGE:` followed by a description. If both conditions met → downgrade to `warn`.

If `breaking_change_flag: "block"` (default) → `fail` always blocks SHIP.

---

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "The test suite passes — no callers broke." | The test suite only tests what was written. It cannot test callers that were not in scope. |
| "This is an internal function, not public." | Check if it is actually exported. `grep "export"` — if exported, it is public by definition. |
| "The parameter change is minor." | Minor to you. Catastrophic to the caller who passed a positional argument that now maps to the wrong slot. |
| "We don't have any callers of this function yet." | If it is exported, it was designed to have callers. Future callers will hit this. |
| "The OpenAPI change is backward compatible." | Run Axis 4 on it anyway. State your evidence in the verdict. |
| "I'll skip DB analysis — this project uses an ORM." | ORMs generate migrations. The migration files are the schema contract. Run Step 3 on them. |

## Red Flags

- Zero findings on a PR that changes 3+ exported function signatures → likely missed the analysis.
- `breaking_change_verdict: pass` on a PR containing `DROP COLUMN` or `RENAME TABLE` → critical miss.
- Breaking changes acknowledged without a `BREAKING CHANGE:` entry in the PR description → acknowledgement path was not followed correctly.

## Verification

After this skill completes:
- `breaking_change` event appended to `verification.jsonl`.
- `breaking_change_verdict` is one of `pass|warn|fail`.
- Every finding in `breaking_changes[]` has `severity`, `surface`, `file`, `line`, `description`.
- Read-only on all source files.
