# Configuration Reference

> Full reference for `swe-team.config.json`. Generated at install; checked into your repo.
>
> Schema: `.claude/references/config-schema.json`
> Single Source of Truth: `SPEC.md §10`

---

## Quickstart

The fastest way to configure is the wizard:

```
/swe-team-setup
```

It auto-detects your stack, asks a few questions, and writes the config file. Edit
manually only when you need to override a specific value.

---

## Full config with defaults

```jsonc
{
  "$schema": "./.claude/references/config-schema.json",
  "version": "0.4.0",

  // ── Models ──────────────────────────────────────────────────────────────
  "models": {
    "lead":          "opus",    // opus | sonnet | haiku | inherit
    "coder":         "sonnet",
    "verifier_mech": "haiku",
    "verifier_sem":  "sonnet",
    "pr":            "sonnet"
  },

  // ── Budget ──────────────────────────────────────────────────────────────
  "budget": {
    "max_tokens": 2000000,   // hard stop on total tokens across all agents
    "max_usd":    15.00,     // hard stop on total USD
    "warn_pct":   80         // emit budget_warn at this % of ceiling
  },

  // ── Limits ──────────────────────────────────────────────────────────────
  "limits": {
    "max_iterations": { "S": 2, "M": 4, "L": 6 },
    "max_replans":            2,
    "stuck_identical_output": 3,   // N identical diffs → stuck event
    "stuck_file_churn":       5,   // same file edited N× in one task
    "max_files_per_task":    10,
    "max_plan_tasks":        15,
    "max_plan_loc":         500
  },

  // ── Branch ──────────────────────────────────────────────────────────────
  "branch": {
    "base":             "dev",   // PR target; "auto" = detect from repo
    "prefix":           "swe/",
    "auto_detect_base": true     // re-detect on each run
  },

  // ── Verification commands ────────────────────────────────────────────────
  "verification": {
    "test_cmd":      "auto",   // "auto" = detect from package.json/lockfile/go.mod/pyproject
    "lint_cmd":      "auto",
    "typecheck_cmd": "auto",
    "test_globs": [
      "**/*.test.*", "**/*.spec.*", "**/tests/**", "**/test/**"
    ],
    "allow_flaky_retry": true   // retry once on non-zero test exit before failing
  },

  // ── Clarify phase ────────────────────────────────────────────────────────
  "clarify": {
    "enabled":       true,
    "mode":          "autonomous",   // "autonomous" | "interactive"
    "max_questions": 5
  },

  // ── Dependency audit ─────────────────────────────────────────────────────
  "dep_audit": {
    "enabled":  true,
    "fail_on":  ["critical", "high"],
    "warn_on":  ["moderate"]
  },

  // ── Breaking-change detection ─────────────────────────────────────────────
  "breaking_change": {
    "enabled":  true,
    "fail_on":  ["api", "schema"],   // api | schema | export
    "warn_on":  ["export"]
  },

  // ── Security (OWASP + secret scan) ────────────────────────────────────────
  "security": {
    "enabled":  true,
    "fail_on":  ["critical", "high"],
    "warn_on":  ["medium"]
  },

  // ── Retrospective ────────────────────────────────────────────────────────
  "retro": {
    "enabled":               true,
    "max_learnings_per_run": 5,
    "learnings_window":      10   // swe-lead reads last N learnings at startup
  },

  // ── Phase toggles ────────────────────────────────────────────────────────
  "phases": {
    "define_threshold": 3,      // ambiguity score ≥ N → run DEFINE
    "force_define":     false,  // always run DEFINE
    "skip_define":      false,  // never run DEFINE
    "skip_clarify":     false,  // skip CLARIFY (not recommended)
    "skip_adv_spec":    false,  // skip adversarial spec review
    "skip_chal_plan":   false   // skip plan challenge review
  },

  // ── GitHub / PR ──────────────────────────────────────────────────────────
  "gh": {
    "pr_labels":                  ["ai-generated", "swe-team"],
    "pr_draft":                   false,
    "require_clean_working_tree": true
  },

  // ── Knowledge vault ──────────────────────────────────────────────────────
  "knowledge": {
    "sources": [
      // local vault example:
      // {
      //   "id": "local-vault",
      //   "type": "local",
      //   "path": "~/vault",
      //   "project_namespace": "my-project",
      //   "capabilities": ["read", "write"]
      // },

      // Notion example:
      // {
      //   "id": "team-notion",
      //   "type": "notion",
      //   "space_id": "<space-id>",
      //   "capabilities": ["read"]
      // },

      // Confluence example:
      // {
      //   "id": "confluence",
      //   "type": "confluence",
      //   "space_key": "ENG",
      //   "capabilities": ["read"]
      // },

      // Linear example:
      // {
      //   "id": "linear",
      //   "type": "linear",
      //   "capabilities": ["read"]
      // }
    ],
    "write_target": ""   // set to a source id with "write" capability
  }
}
```

---

## Key options explained

### `models`

Each agent can be independently assigned a model tier. `"inherit"` means it uses whatever
model the parent agent was invoked with.

Typical cost-optimisation: keep `lead` on `opus` (planning is the highest-leverage step),
drop `verifier_mech` to `haiku` (shell checks, not reasoning).

### `budget`

`max_tokens` and `max_usd` are enforced by `budget-gate.sh` before every Task spawn. The
run aborts with `status: failed` if either ceiling is hit mid-run. Set `warn_pct` lower
(e.g. `60`) on small projects to get an early warning.

### `limits.max_iterations`

How many coder→mech→sem cycles are allowed per task before the task is marked `failed` and
a replan is triggered. `S` = small task, `M` = medium, `L` = large (declared in
`tasks.json` per task). Increase `L` for tasks that are known to need more trial runs;
decrease `S` to cut costs on trivial tasks.

### `clarify.mode`

- `autonomous`: swe-lead greps the repo and writes its own assumptions. Fastest; no
  user interaction needed. Good for CI-adjacent or unattended runs.
- `interactive`: swe-lead asks you questions before proceeding. Use when you're at the
  terminal and the requirement is genuinely ambiguous.

### `phases.skip_clarify`

Skipping CLARIFY saves ~1 round trip but increases replan risk. Recommended only for
trivial single-file tasks.

### `gh.pr_draft`

Set `true` to always open draft PRs. Useful if you want a staging review before marking
the PR ready.

### `gh.require_clean_working_tree`

Aborts the run at ingest if there are uncommitted changes in the working tree. Prevents
the coder from accidentally incorporating half-finished work. Disable only in development
setups where you intentionally have staged changes.

---

## Minimal config (bare project)

If you want to get started without filling in every option, the installer generates this:

```jsonc
{
  "$schema": "./.claude/references/config-schema.json",
  "version": "0.4.0",
  "models":       { "lead": "opus", "coder": "sonnet", "verifier_mech": "haiku", "verifier_sem": "sonnet", "pr": "sonnet" },
  "budget":       { "max_tokens": 2000000, "max_usd": 15.00, "warn_pct": 80 },
  "limits":       { "max_iterations": { "S": 2, "M": 4, "L": 6 }, "max_replans": 2, "stuck_identical_output": 3, "stuck_file_churn": 5, "max_files_per_task": 10, "max_plan_tasks": 15, "max_plan_loc": 500 },
  "branch":       { "base": "dev", "prefix": "swe/", "auto_detect_base": true },
  "verification": { "test_cmd": "auto", "lint_cmd": "auto", "typecheck_cmd": "auto", "test_globs": ["**/*.test.*", "**/*.spec.*", "**/tests/**", "**/test/**"], "allow_flaky_retry": true },
  "clarify":      { "enabled": true, "mode": "autonomous", "max_questions": 5 },
  "dep_audit":    { "enabled": true, "fail_on": ["critical", "high"], "warn_on": ["moderate"] },
  "breaking_change": { "enabled": true, "fail_on": ["api", "schema"], "warn_on": ["export"] },
  "security":     { "enabled": true, "fail_on": ["critical", "high"], "warn_on": ["medium"] },
  "retro":        { "enabled": true, "max_learnings_per_run": 5, "learnings_window": 10 },
  "phases":       { "define_threshold": 3, "force_define": false, "skip_define": false, "skip_clarify": false, "skip_adv_spec": false, "skip_chal_plan": false },
  "gh":           { "pr_labels": ["ai-generated", "swe-team"], "pr_draft": false, "require_clean_working_tree": true },
  "knowledge":    { "sources": [], "write_target": "" }
}
```

---

## Where to find more

| Topic | Link |
|---|---|
| Knowledge vault setup | [docs/KNOWLEDGE-VAULT.md](KNOWLEDGE-VAULT.md) |
| Security gate details | [docs/SAFETY.md](SAFETY.md) |
| How each phase works | [docs/HOW-IT-WORKS.md](HOW-IT-WORKS.md) |
| Config JSON schema | `.claude/references/config-schema.json` |
| Full spec (authoritative) | [SPEC.md](../SPEC.md) |
