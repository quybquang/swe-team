# Changelog

All notable changes to this package are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [0.1.1] — 2026-04-23

OSS research + hardening pass. Derived from a deep-research sweep of
addyosmani/agent-skills, OpenHands, SWE-agent, Anthropic Agent SDK,
MetaGPT/AutoGen/CrewAI/claude-flow, Aider, Cognition's "Don't build
multi-agents" essay, MCP, and the Anthropic engineering blog.

### Added

- `CLAUDE.md` — project memory (SoT rule, smoke test command, "never do" list).
- `docs/research-oss-best-practices.md` — 11-section research report.
- `docs/AGENT_DESIGN.md` — rationale for multi-agent + Claude Code-native.
- `docs/ANTI_PATTERNS.md` — 22 failure-mode entries with detection path.
- `docs/EVAL.md` — evaluation harness spec (seed corpus + rubric + metrics).
- `docs/TELEMETRY.md` — file-based observability with jq recipes.
- `.claude/skills/swe-team-context-prime/SKILL.md` — 13th skill for start-of-turn re-grounding.
- `SPEC.md` §15 Appendix A — 8 research-derived refinements.

## [0.1.0] — 2026-04-23

Initial MVP.

### Added

- `SPEC.md` as the Single Source of Truth (13 numbered sections + glossary).
- 5 subagent definitions in `.claude/agents/` (`swe-lead`, `swe-coder`, `swe-verifier-mech`, `swe-verifier-sem`, `swe-pr`), each with explicit tool allowlist and model assignment.
- 12 skills in `.claude/skills/swe-team-*/` using the addyosmani agent-skills format (Overview / When to Use / When NOT / Process / Anti-Rationalizations / Red Flags / Verification).
- 4 JSON schemas in `.claude/references/` (event, tasks, verification, config) — Draft 2020-12.
- 3 markdown references: `commit-conventions.md`, `pr-template.md`, `security-checklist.md`.
- 6 hook scripts in `.claude/hooks/` wired via `.claude/settings.json`:
  `init-run.sh`, `guard-destructive-git.sh`, `budget-gate.sh`,
  `track-file-edit.sh`, `capture-test-output.sh`, `phase-exit-verify.sh`.
- `/swe-team` slash command.
- `scripts/install.sh` with stack auto-detection (npm/pnpm/yarn/go/python), base-branch detection, settings merge, `.gitignore` updates. `scripts/uninstall.sh` reverses.
- Smoke tests: `tests/smoke/{run-all,test-schemas,test-hooks,test-install}.sh`.
- Example requirement at `examples/sample-requirement.md`.
- Default config at `.claude/swe-team/config.default.json`.

### Design decisions

- File-based state (no external queue, no DB).
- Evidence-over-assertion verification discipline.
- Per-agent context condensation (§ 3.6 of SPEC).
- Multi-agent with phase boundaries (addresses long-horizon error accumulation).
- Human gate at PR review only; autonomous until then.
