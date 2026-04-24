# Changelog

All notable changes to this package are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [0.2.0] — 2026-04-24

Three new capabilities ported from gstack research: pre-flight clarification, persistent
retrospective learnings, and OWASP security gate.

### Added

- `.claude/skills/swe-team-clarify/SKILL.md` — CLARIFY phase skill. Runs before DEFINE.
  Two modes: interactive (asks user 3–5 forcing questions) and autonomous (greps repo for
  assumptions). Outputs `pre-flight-brief.md` to run dir. Eliminates the majority of mid-BUILD
  replans caused by misunderstood scope.
- `.claude/skills/swe-team-retro/SKILL.md` — RETRO phase skill. Runs after every run
  (succeeded, failed, or aborted). Analyzes budget efficiency and failure patterns. Writes
  ≥1 project-specific lesson to `.claude/swe-team/learnings.jsonl` (persistent, not in runs/).
  Future swe-lead reads the last N=10 learnings at startup so each project session teaches the next.
- `.claude/skills/swe-team-security-review/SKILL.md` — Security review skill. Invoked by
  swe-verifier-sem in whole-PR mode. Runs OWASP Top 10 grep checks + secret/credential pattern
  detection. Emits `security_verdict` (pass|warn|fail) and `security_issues[]`. `fail` blocks
  SHIP and triggers a replan; `warn` proceeds but notes issues in PR body for reviewer.

### Changed

- `SPEC.md` bumped to v0.2.0. Updates in:
  - §3.1 run dir layout: added `pre-flight-brief.md`, `assumptions.md`, expanded package layout to show `learnings.jsonl`.
  - §3.4 event kinds: added `phase_enter/exit` for CLARIFY and RETRO phases, `security_review` event, `retro_complete` event, `learning` record.
  - §3.6 context condensation: swe-lead now reads `learnings.jsonl`; swe-verifier-sem whole-PR row added; swe-pr row reads `security_review` event.
  - §5 phase flow: CLARIFY inserted before DEFINE, RETRO inserted after SHIP. Both phases shown in ASCII diagram.
  - §6 skills catalog: 3 new skills added; directory column added.
  - §9.3 whole-PR checks: `security_verdict != fail` added as blocking condition.
  - §9.4 (new): security review evidence schema — `security_verdict`, `security_issues[]` with per-issue `{severity, category, file, line, snippet}`.
  - §9.5 (was §9.4): anti-rationalization enforcement.
  - §10 config: added `clarify`, `security`, `retro` top-level keys with defaults; `phases.skip_clarify`; version bumped to 0.2.0.
- `swe-lead.md` agent: CLARIFY step (step 2) added before DEFINE. Learnings loaded at startup (step 1a). RETRO (step 9) added after SHIP. BUILD loop references renumbered (5–9 instead of 4–7). Invariants and Skills sections updated.
- `swe-verifier-sem.md` agent: whole-PR mode step 7 added (invoke `swe-team:security-review`). Blocking condition updated. Invariants and Skills sections updated.
- `.claude/swe-team/config.default.json`: version 0.2.0; added `clarify`, `security`, `retro` blocks; added `phases.skip_clarify`.

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
