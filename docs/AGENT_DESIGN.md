# Agent Design Rationale

> Companion to `SPEC.md`. The spec defines **what** swe-team does. This document explains **why** the design is shaped that way, with direct citations to `docs/research-oss-best-practices.md`.

---

## 1. Why Multi-Agent

The strongest counter-argument to multi-agent architectures comes from Cognition (Devin) and is summarized in research §8: context fragmentation, lossy handoffs, harder debugging, harder evaluation, super-linear cost. These are real failure modes, and we take them seriously.

We still chose multi-agent. The argument:

### 1.1 Error accumulation caps out faster in single-agent long-horizon

SWE-agent (research §4) demonstrated that a single agent running over a full issue accumulates errors step-by-step until the trajectory is unrecoverable. OpenHands (research §3) achieves 77.6% on SWE-bench verified specifically because it phases work across specialized agents with evidence gates between them. The empirical data favors phased multi-agent for complex coding tasks.

### 1.2 Phase boundaries localize errors

With a single long agent, a mistake at step 3 may only become detectable at step 15 — and by then the context is saturated and the agent cannot self-correct. With phase-gated agents, the mech verifier (SPEC §9.1) fires immediately after each coder spawn and pins any regression to exactly one commit. The error domain is always one task, not the whole run.

### 1.3 Fragmentation mitigated by shared file state

Cognition's critique assumes handoffs carry state through prompt-to-prompt text. We don't do that. Every agent re-reads `run.json` (the immutable anchor requirement), `tasks.json` (current plan), and the relevant event slice (SPEC §3.5, §3.6). Context is **reconstructed from files on each turn**, not inherited. This is OpenHands' EventStream pattern (research §3 pattern 1) — agents cannot hallucinate state because the ground truth is on disk.

This directly defuses Cognition's points 1-3. Points 4-5 (eval, cost) are mitigated by per-phase verification (SPEC §9) and model selection by role (SPEC §4).

### 1.4 Agent count is the budget

Every agent added = more spawn cost, more handoff surface, more to debug. We ship **5 agents** (lead, coder, mech, sem, pr). Adding a sixth requires a rationale stronger than "it would be nice."

---

## 2. Context Engineering

Per-agent context slicing (SPEC §3.6) is directly modeled on OpenHands' condenser module (research §3 pattern 2). Each agent sees only what it needs.

### 2.1 What we borrowed from OpenHands

- **Condenser-as-module**: different agents benefit from different condensation strategies. OpenHands configures this at runtime; we configure it at the spec level by prescribing per-agent read slices.
- **File-based instead of LLM-summarized**: OpenHands' condenser often summarizes old events with an LLM. We avoid this because summarization is itself a source of hallucination. Instead we achieve the same outcome through **per-task file isolation** (`build/task-<id>.jsonl`) — the coder's log IS its filtered event stream, zero summarization required (research §3 pattern 2, "what swe-team does better").

### 2.2 What we borrowed from Aider

Aider's `CONVENTIONS.md` pattern (research §7 pattern 1) grounds an agent in project conventions via an always-loaded read-only file. Our equivalent is the new `swe-team-context-prime` skill (`.claude/skills/swe-team-context-prime/SKILL.md`), which loads `run.json`, active task, phase state, and the recent event tail at every agent spawn. This is the same cache-friendly prefix strategy Aider uses (research §7 pattern 2): identical prefix across spawns of the same agent type → prompt caching cost reduction (research §10 pattern 2).

### 2.3 Practical rule for prompt layout

In each agent's spawn prompt, order is:

1. Skill / agent definition content (identical across spawns → cacheable)
2. `run.json` content (identical within a run → cacheable)
3. Per-agent read slice (varies per spawn → not cacheable, kept at the end)

This layout is recommended in research §10 pattern 2 ("place stable content at the top").

---

## 3. Evidence over Assertion

The most load-bearing design decision in swe-team: **no verdict without evidence**.

### 3.1 Mech tier is a binary function of evidence

SPEC §9.1 defines the mech verdict as a pure boolean over structured fields: `test_exit == 0 AND lint_exit == 0 AND typecheck_exit == 0 AND deleted_test_files == [] AND new_skip_or_only_count == 0 AND assertion_count >= baseline`. No LLM judgment. The LLM only **formats** the evidence into the verification event.

This is the SWE-agent ACI lesson inverted. SWE-agent (research §4) showed that good tool interfaces dominate LLM capability — the agent gets 8+ percentage points on SWE-bench just from better ACI. We apply the same lesson to verification: give the verifier a deterministic interface, and the LLM's job becomes tractable regardless of model strength. That's why Haiku suffices for mech (SPEC §4 model rationale).

### 3.2 Sem tier's LLM judgment is gated on mech pass

If mech fails, sem never runs. This cuts sem cost and prevents the common failure mode where a reasoning-strong LLM rationalizes a broken commit as acceptable because it "looks right." Sem only sees commits that already pass every deterministic check.

### 3.3 Anti-rationalization is a hard filter, not a suggestion

The `swe-team:anti-rationalize` skill (SPEC §9.4) rejects any verdict string containing hedging tokens (`probably`, `should work`, `seems fine`) unless paired with explicit evidence fields. Tabular anti-rationalization format is borrowed from addyosmani (research §1 pattern 2); the enforcement is our addition.

### 3.4 Why this works: verifiability compounds

Every `verification` event with `verified: true` carries a `commit_sha`, test output sha, and assertion counts. These are **independently recomputable** by a hook, by a human reviewer, or by a replay script (see `docs/TELEMETRY.md`). If the coder lied, a human can detect it without re-running the LLM. This is the "eval as CI gate" discipline from research §10 pattern 3.

---

## 4. Claude Code-native vs. Custom Runtime

OpenHands ships a Python server + Docker runtime. MetaGPT and AutoGen require Python processes and in-process message buses. swe-team ships **only** `.claude/` files plus two shell scripts.

### 4.1 Why we don't ship a runtime

- **Install promise**: `./scripts/install.sh <target>` is one command, no Docker pull, no pip install, no daemon. Research §3 "what NOT to copy" captures this: Docker sandboxing breaks the install-and-run experience.
- **Audit surface**: Users read `.claude/agents/*.md`, `.claude/skills/*/SKILL.md`, and `.claude/hooks/*.sh` as checked-in code. No hidden state, no binary blob. Research §12 Threat Model treats the package as user-reviewed.
- **Upgrade story**: `install.sh --upgrade` overwrites files. No database migration, no state drift.

### 4.2 What we get for free from Claude Code

- Isolated-context subagents via the Task tool (SPEC §2.3)
- File-based agent definitions with tool allowlists (research §2 pattern 1)
- Hooks: `PreToolUse`, `PostToolUse`, `SubagentStop`, `SessionStart` (SPEC §7)
- Skill auto-invocation via description match (research §2 pattern 3)
- Project-over-global settings merging

### 4.3 What we give up

- No durable queue — a crashed Claude Code session ends the run. Mitigation: events.jsonl is replayable, but resumption is out of scope for MVP (SPEC §13).
- No cross-machine coordination — single-user, single-machine model. A team member can read a run directory from git but cannot resume it.
- No real-time dashboards — analysis is post-hoc via `jq` on `events.jsonl` (see `docs/TELEMETRY.md`).

These are acceptable trade-offs for v0.1.0. Research §3 "what NOT to copy" lists the same trade-offs OpenHands made in reverse and explicitly rejects them for our product shape.

---

## 5. Spec-first Discipline

### 5.1 Every agent re-reads the anchor

SPEC §3.5 mandates that every agent reads `run.json` (original requirement) and the per-agent slice at the start of every turn. No agent trusts its context window as a historical record.

This solves Cognition's "context fragmentation" critique (research §8): the original requirement is never more than one file-read away, so no agent can drift from the user's stated intent.

### 5.2 Docs-as-Code

`SPEC.md` is the source of truth. All code derives from it (SPEC §1 axiom 1). When a hook script, agent file, or skill diverges, the code is the bug. This discipline is explicit in every contributor-facing file (`CLAUDE.md`).

### 5.3 Why this over "let the agents figure it out"

Research §5 pattern 3 from Anthropic's "Building Effective Agents":
> "We recommend finding the simplest solution possible, and only increasing complexity when needed."

Spec-first is simpler than self-organizing. A spec can be reviewed in a PR diff; an emergent agent behavior cannot.

---

## 6. Edit-over-Write and ACI Lessons

From research §4 pattern 1 (SWE-agent): structured edit commands reduce off-by-one errors and prevent unintended changes outside the targeted line range. Claude Code's `Edit` tool gives us the equivalent of SWE-agent's structured `edit <start_line> <end_line> <replacement>`. The coder-loop skill instructs swe-coder to prefer `Edit` over `Write` whenever possible — `Write` only for new files.

This also makes `scope_diff_clean` (SPEC §9.2) easier for the sem verifier to evaluate: line-scoped edits produce tighter diffs.

---

## 7. Orchestrator-Workers as the Named Pattern

Research §5 pattern 1 names our architecture: the Anthropic "Building Effective Agents" post classifies swe-lead + swe-coder-per-task as the **Orchestrator-Workers** workflow, explicitly recommended for coding tasks where subtask count is task-dependent. This is not a coincidence — we designed to this pattern deliberately.

The two-tier verifier (mech then sem) is the **Evaluator-Optimizer** workflow from the same post (§5 pattern 2), with the coder as optimizer and the verifier pair as evaluators.

Both patterns are production-validated inside Anthropic. We are not inventing; we are composing documented patterns.

---

## 8. Trade-offs Stated Explicitly

| Decision | What we gain | What we give up |
|---|---|---|
| Multi-agent, phased | Localized errors, per-phase eval, role-specialized models | Handoff surface, coordination cost, extra agent spawns |
| File-based state | Auditable, git-checkable, no runtime daemon | No live dashboard, manual replay for inspection |
| Claude Code-native only | Zero-dependency install, Docker-free | No cross-tool portability (Codex, Cursor, etc.) |
| Sequential task execution (MVP) | Simple ordering, deterministic logs | No parallelism — slower wall-clock on large plans (SPEC §13) |
| Evidence-only verdicts | Hallucination-resistant, human-recomputable | More rigid; coders must produce concrete proof |
| Opus only for lead | Cost ceiling achievable | Lead is a bottleneck; coder cannot request Opus |
| Human gate at PR | No autonomous merge disasters | Not end-to-end autonomous |
| No Docker sandbox | One-step install, works in any Claude Code session | Lower blast-radius guarantee than OpenHands |
| No MCP deps in MVP | Clean install | Coder uses raw `Bash` / `gh` rather than scoped MCP (research §9) |
| `.skip`/`.only` etc. checked by grep, not AST | Language-agnostic, fast | Can miss obfuscated forms; acceptable per threat model |

---

## 9. Future Refinements

See `SPEC.md` §15 (Appendix A) for specific research-derived amendments queued for follow-up:
- MCP scoped-tool integration for verifiers (research §9)
- Prompt caching hit-rate measurement (research §10)
- Eval corpus expansion and CI gating (research §10)
- Mid-task commits for L-sized tasks (research §7 pattern 3, speculative)

---

*This document explains the why. When reality collides with one of these rationales, revisit the research file section cited here — don't re-derive from scratch.*
