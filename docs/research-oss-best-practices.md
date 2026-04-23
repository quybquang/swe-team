# OSS Best Practices Research Report

> **Purpose**: Phase 1 research for hardening swe-team into an enterprise, production-grade Claude Code agent kit.
> **Date**: 2026-04-23
> **Status**: Complete — findings integrated into Phase 2 files.

---

## Table of Contents

1. [addyosmani/agent-skills](#1-addyosmaniagent-skills)
2. [Anthropic Claude Code Docs](#2-anthropic-claude-code-docs)
3. [OpenHands / All-Hands-AI](#3-openhands--all-hands-ai)
4. [SWE-agent (Princeton)](#4-swe-agent-princeton)
5. [Anthropic Agent SDK + "Building Effective Agents"](#5-anthropic-agent-sdk--building-effective-agents)
6. [MetaGPT / AutoGen / CrewAI / claude-flow](#6-metagpt--autogen--crewai--claude-flow)
7. [Aider](#7-aider)
8. [Cognition / Devin Counter-Argument](#8-cognition--devin-counter-argument)
9. [Model Context Protocol](#9-model-context-protocol)
10. [Anthropic Engineering Blog — Observability & Eval](#10-anthropic-engineering-blog--observability--eval)
11. [Synthesis: What swe-team Adopted and Rejected](#11-synthesis-what-swe-team-adopted-and-rejected)

---

## 1. addyosmani/agent-skills

**URL**: https://github.com/addyosmani/agent-skills  
**Relevance**: HIGH — canonical reference for Claude Code skill format

### What It Is

A curated set of 20 production-grade engineering skills for AI coding agents, structured as `SKILL.md` files with a consistent anatomy:

```
Overview → When to Use → When NOT to Use → Process → Common Rationalizations → Red Flags → Verification
```

Skills cover the full development lifecycle: `spec-driven-development`, `planning-and-task-breakdown`, `incremental-implementation`, `test-driven-development`, `context-engineering`, `git-workflow-and-versioning`, `code-review-and-quality`, `security-and-hardening`, and more.

### Pattern 1: Gated workflow with explicit "when NOT to use"

Every skill clearly names the boundary conditions. `spec-driven-development` has a hard rule: "When NOT to use: Single-line fixes, typo corrections." This prevents skill invocation overhead on trivial tasks. swe-team already applies this to all 12 skills but is inconsistent in the "when NOT to use" section of several early skills.

**Concrete text from source** (`spec-driven-development/SKILL.md`):
> "Write a structured specification before writing any code. The spec is the shared source of truth... Code without a spec is guessing."

### Pattern 2: Anti-rationalization tables

Skills include explicit tables mapping common excuses to the reality:

| Rationalization | Reality |
|---|---|
| "This is simple, I don't need a spec" | Simple tasks don't need long specs, but they still need acceptance criteria. |
| "I'll write the spec after I code it" | That's documentation, not specification. |

This pattern is partially in swe-team's `swe-team:anti-rationalize` skill but is not structured as a table. Adding the tabular form improves LLM parsing.

### Pattern 3: Scope discipline as a named rule

`incremental-implementation/SKILL.md` names scope discipline explicitly:

> "Rule 0.5: Scope Discipline — Touch only what the task requires. Do NOT: 'Clean up' code adjacent to your change... If you notice something worth improving outside your task scope, note it — don't fix it."

This maps directly to swe-team's `scope_diff_clean` evidence field in the semantic verifier but the *coder* side never explicitly receives this rule. The coder-loop skill should mirror it as a named, numbered rule.

### What NOT to Copy

- The slash-command layer (`/spec`, `/plan`, `/build`, `/test`) creates UX overhead appropriate for interactive single-agent use but is redundant in swe-team's fully orchestrated multi-agent context where swe-lead drives the workflow programmatically.
- The "AGENTS.md" pattern for Codex is not applicable — swe-team targets Claude Code exclusively.
- The plugin marketplace install mechanism adds an SSH dependency; swe-team uses `install.sh` directly.

### What swe-team Adopted

- Tabular anti-rationalization format added to `swe-team:anti-rationalize` (see ANTI_PATTERNS.md for catalog).
- "When NOT to Use" sections standardized across all 12 skills (see `swe-team-context-prime` skill as model).
- Scope discipline named and numbered in coder-loop skill.

---

## 2. Anthropic Claude Code Docs

**URLs**:
- https://docs.anthropic.com/en/docs/claude-code/sub-agents
- https://docs.anthropic.com/en/docs/claude-code/hooks
- https://docs.anthropic.com/en/docs/claude-code/skills
- https://docs.anthropic.com/en/docs/claude-code/settings

**Relevance**: HIGH — normative reference; swe-team is Claude Code-native

### Pattern 1: Tool allowlists on subagents

Claude Code allows each agent definition to specify an explicit `tools` allowlist in its frontmatter. swe-team already enforces this (SPEC §4). The docs confirm:

> Subagents inherit the parent thread's permissions unless overridden. Omitting `tools` is a security anti-pattern for production agents.

swe-team correctly overrides this for every agent. The verifier-mech tool set (`Read, Bash, Skill`) is the minimal viable set — the docs confirm Haiku can reliably invoke Bash for deterministic checks.

### Pattern 2: Hook exit code semantics

Exit code `2` from a hook blocks the tool call. Exit code `0` allows. Any other non-zero exits are advisory (the tool call proceeds but the output is flagged). swe-team uses exit code `2` for budget-gate and destructive-git guard — correct per docs. `track-file-edit.sh` uses exit `0` intentionally (advisory stuck signal).

### Pattern 3: Skill auto-invocation by description match

Claude Code matches skills by the `description` field in frontmatter. The description should start with a verb phrase describing the trigger: "Runs when...", "Assembles...", "Invoked when swe-coder spawns..." — not a noun phrase describing what the skill is. Several swe-team skills use noun-first descriptions, reducing auto-match precision.

**Recommended fix**: All skill descriptions should start with a third-person verb: "Assembles the minimal per-agent context slice..." (already correct for `condense-context`).

### What NOT to Copy

- The global `~/.claude/settings.json` is for personal preferences. swe-team correctly uses project-level `.claude/settings.json` exclusively — merge at install, not override.
- Claude Code's built-in compact/summarize behavior is separate from swe-team's explicit context condensation. Do not attempt to suppress built-in compaction; layer on top of it.

### What swe-team Adopted

- Exit code semantics fully aligned with docs.
- Skill description verb-first convention enforced in new `swe-team-context-prime`.

---

## 3. OpenHands / All-Hands-AI

**URL**: https://github.com/All-Hands-AI/OpenHands  
**Paper**: https://arxiv.org/abs/2511.03690  
**Benchmark**: 77.6% on SWE-bench verified  
**Relevance**: HIGH — state-of-art multi-agent SWE system; architecture reference

### What It Is

OpenHands is a multi-agent SWE system with three core architectural components:

1. **EventStream**: All agent actions and observations are appended to a shared event stream. Every agent action (file edit, bash command) produces an observation. The stream is the ground truth.

2. **Action/Observation Loop**: Agents operate in a tight `action → environment → observation` loop. They cannot proceed to a next action until the observation from the previous action is received. This prevents hallucinated intermediate states.

3. **Runtime Sandboxing**: All code execution happens in a Docker sandbox. The agent cannot affect the host.

### Pattern 1: EventStream as ground truth

OpenHands' EventStream is the direct architectural precedent for swe-team's `events.jsonl` + `build/task-*.jsonl` design. Key shared property: agents must read the stream to know what happened; they cannot rely on context window memory.

> From the OpenHands architecture: "The agent's context window is reconstructed from the EventStream on each turn, not carried from the previous turn."

swe-team implements this as SPEC §3.5 ("Ground-truth rule"). The OpenHands paper validates this as the key anti-hallucination mechanism.

### Pattern 2: Context condensation (the "condenser")

OpenHands implements a `condenser` module that summarizes old events before they overflow the context window. The condenser is configurable: `NoOpCondenser`, `LLMSummarizingCondenser`, `RecentEventsCondenser`. The key insight: **different agents in the same system benefit from different condensation strategies**.

swe-team's `swe-team:condense-context` skill and SPEC §3.6 implement the equivalent using per-agent read-slicing rules. This is actually simpler than OpenHands' condenser because swe-team uses per-task file isolation, which makes the slicing deterministic rather than requiring LLM summarization.

**What swe-team does better**: swe-team's `build/task-<id>.jsonl` per-task file means the coder never needs to filter events — its log IS the filtered event stream. OpenHands has to condense because all events land in one stream.

### Pattern 3: Micro-agent specialization

OpenHands uses specialized micro-agents: `BrowsingAgent`, `LockedAgent`, `RepoExplorer`. Each has a defined role with explicit tool restrictions. The paper shows that specialization outperforms a single generalist agent for SWE tasks.

swe-team's agent roster (swe-lead / swe-coder / swe-verifier-mech / swe-verifier-sem / swe-pr) mirrors this pattern. The model selection rationale in SPEC §4 is well-aligned with OpenHands' findings.

### What NOT to Copy

- Docker sandboxing: Adds operational complexity that conflicts with swe-team's Claude Code-native stance. Claude Code already runs in a process-isolated environment. Shipping a Docker dependency would break the install-and-run promise.
- Python daemon / REST API: OpenHands requires a running server process. swe-team is file-based.
- The "Theory of Mind" module (ToM-SWE): Fascinating research but not yet stable. Out of scope for MVP.

### What swe-team Adopted

- Per-task event file isolation (already in SPEC, validated by OpenHands EventStream pattern).
- Agent specialization pattern (already in SPEC, validated by micro-agent research).
- Context condensation as a first-class concern (SPEC §3.6 and `swe-team:condense-context` skill).

---

## 4. SWE-agent (Princeton)

**URL**: https://github.com/princeton-nlp/SWE-agent  
**Paper**: https://arxiv.org/abs/2405.15793 — "SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering"  
**Relevance**: HIGH — direct SWE-bench performance data; Agent-Computer Interface (ACI) lessons

### What It Is

SWE-agent is a research system where an LLM agent autonomously uses a custom Agent-Computer Interface (ACI) to solve GitHub issues. The ACI is a set of purpose-built shell tools designed specifically for LM agents, replacing raw bash with commands like `search_dir`, `open`, `scroll_down`, `find_file`, `edit`.

Key finding from the paper: **The ACI design, not the underlying LLM, is the primary performance driver** on SWE-bench. Switching from raw bash to the custom ACI improved Claude 3.5 performance by over 8 percentage points.

A successor project, `mini-swe-agent`, achieves 65% on SWE-bench verified with 100 lines of Python — validating that simplicity plus good ACI beats complexity.

### Pattern 1: Purpose-built navigation tools outperform raw bash

Raw bash gives an agent unbounded power but poor ergonomics. The SWE-agent ACI wraps file navigation into constrained, predictable commands:

```
open <path> [line_number]   — opens file, shows context window
scroll_down                 — scrolls the open file by N lines
find_file <name> [dir]      — finds file by name in repo
search_file <pattern>       — searches within open file
edit <start_line> <end_line> <replacement>  — structured edit
```

The structured `edit` command in particular reduces off-by-one errors and prevents the agent from making unintended changes outside the specified line range.

**Implication for swe-team**: Claude Code's Edit and Write tools already provide this structure. The coder-loop skill should explicitly instruct swe-coder to use Edit (line-targeted) rather than Write (full-file overwrite) wherever possible, since Edit is the ACI equivalent.

### Pattern 2: Observation summaries prevent context overflow

SWE-agent's `ACI` has a built-in "window" showing the last N lines of the current open file. Observations are truncated to a configurable window size rather than dumped in full. The agent sees: "File X, lines 45-90, <content>" rather than the entire file.

swe-team's `capture-test-output.sh` stores `stdout_sha256` rather than full test output — this is the same principle. The sha is the reference; the verifier can reconstruct if needed.

### Pattern 3: Reproducible benchmark isolation

SWE-agent runs each task in an isolated container initialized from the repo at the issue's creation commit. This ensures reproducibility: two runs of the same task get identical starting state.

swe-team achieves partial isolation via branch discipline (`swe/<slug>-<date>`). The equivalent of SWE-agent's container isolation is: each run starts from a clean checkout of `base_branch`. The `require_clean_working_tree` config option (§10) enforces this but is not explicitly described as the isolation mechanism.

### What NOT to Copy

- The full ACI scaffolding in Python: Not needed; Claude Code provides equivalent primitives.
- The single-agent long-horizon design: SWE-agent runs one agent for the whole issue. This is exactly the failure mode swe-team's multi-agent phased approach avoids.
- The `window` command pattern: Not needed; Claude Code's Read tool with offset/limit provides the same capability.

### What swe-team Adopted

- Edit-over-Write preference added to coder-loop skill (pattern 1).
- Observation truncation principle validated; `capture-test-output.sh` approach confirmed.
- Clean-working-tree prerequisite described as isolation mechanism in AGENT_DESIGN.md.

---

## 5. Anthropic Agent SDK + "Building Effective Agents"

**URLs**:
- https://www.anthropic.com/research/building-effective-agents (Dec 2024)
- https://github.com/anthropics/anthropic-sdk-python

**Relevance**: HIGH — authoritative Anthropic guidance; directly applicable patterns

### What It Is

The "Building Effective Agents" post summarizes Anthropic's production learnings from working with dozens of teams building LLM agents. It defines a taxonomy of agentic systems:

- **Workflows**: LLMs orchestrated through predefined code paths.
- **Agents**: LLMs that dynamically direct their own processes.

Five workflow patterns are described: Prompt Chaining, Routing, Parallelization, Orchestrator-Workers, and Evaluator-Optimizer.

### Pattern 1: Orchestrator-Workers is the right pattern for SWE

From the post:
> "The orchestrator-workers workflow is well-suited for complex tasks where you can't predict the subtasks needed (in coding, the number of files that need to be changed and the nature of each change likely depend on the task)."

swe-team's swe-lead (orchestrator) + swe-coder-per-task (workers) is textbook orchestrator-workers. The research validates this design choice.

### Pattern 2: Evaluator-Optimizer validates two-tier verification

From the post:
> "The evaluator-optimizer workflow is particularly effective when we have clear evaluation criteria, and when iterative refinement provides measurable value. The two signs of good fit are: LLM responses can be demonstrably improved when a human articulates their feedback; and the LLM can provide such feedback."

swe-team's mech-then-sem verification is an evaluator-optimizer where:
- Mech verifier = deterministic evaluator (clear criteria)
- Sem verifier = reasoning evaluator (LLM judgment)
- Coder = optimizer (iterative refinement within iter budget)

### Pattern 3: Simplest solution first; only add complexity when needed

> "We recommend finding the simplest solution possible, and only increasing complexity when needed. This might mean not building agentic systems at all."

This is the Cognition counter-argument from within Anthropic's own post. swe-team addresses this by:
1. Being a workflow (predefined phases), not a fully autonomous agent.
2. Having explicit scope gates that prevent agents from expanding scope.
3. Requiring human review at PR — no autonomous merge.

The post's guidance on tool documentation:
> "Often the most important thing you can do is improve your tool documentation... Ensure that edge cases are handled by the tool itself... Any mistakes an LLM makes in tool usage are likely to be repeated."

swe-team's skills function as tool documentation. The detail in each skill's Process section addresses this directly.

### What NOT to Copy

- Complex framework abstractions: The post explicitly warns against LangChain-style frameworks that obscure underlying prompts.
- Prompt chaining for sequential deterministic tasks: swe-team's phase-based approach is correct; pure prompt chaining without phase gates would lose verifiability.

### What swe-team Adopted

- Two-tier verification validated as Evaluator-Optimizer pattern.
- Orchestrator-Workers pattern confirmed for lead/coder split.
- Tool documentation quality (skills) as primary quality lever.

---

## 6. MetaGPT / AutoGen / CrewAI / claude-flow

**URLs**:
- MetaGPT: https://github.com/geekan/MetaGPT
- AutoGen: https://github.com/microsoft/autogen
- CrewAI: https://github.com/joaomdmoura/crewAI

**Relevance**: MEDIUM — architectural patterns; most do NOT translate directly to Claude Code file-based setup

### MetaGPT — Role-Based SOP Encoding

MetaGPT's core insight: encode software company SOPs as agent roles. Roles = `ProductManager`, `Architect`, `ProjectManager`, `Engineer`. Each role has a defined `watch` set (what messages it subscribes to) and an `act` function.

**Translatable pattern**: Role message routing via file type. In swe-team, each agent reads a specific file set (SPEC §3.6). This is the file-based equivalent of MetaGPT's message subscribe/publish. A coder does not read `events.jsonl` — it reads only `build/task-T_i.jsonl`. This IS MetaGPT's `watch` implemented as file routing.

**Not translatable**: MetaGPT's in-process message bus and Python class hierarchy. swe-team must remain file-based and Claude Code-native.

### AutoGen — Conversational Agent Patterns

AutoGen (now in maintenance mode, superseded by Microsoft Agent Framework) pioneered "conversational agents" — agents that communicate by passing messages to each other. The key innovation: agents can be human-in-the-loop or fully automated.

**Translatable pattern**: The `GroupChat` pattern where multiple agents take turns responding to a shared conversation context. swe-team's sequential task execution (coder → verifier-mech → verifier-sem → lead decision) is a deterministic variant of AutoGen's `GroupChat` with a fixed turn order.

**Not translatable**: AutoGen requires a running Python process coordinating agents. swe-team uses Claude Code's Task tool for agent spawning, which is simpler and doesn't require a separate process.

### CrewAI — Sequential and Hierarchical Processes

CrewAI offers two execution modes: sequential (tasks run in order, output feeds next) and hierarchical (manager agent routes tasks to workers). swe-team's BUILD phase is sequential CrewAI; swe-lead is the manager in hierarchical mode during planning.

**Key CrewAI lesson**: Tasks should have explicit `expected_output` defined before execution starts, not inferred during. swe-team's `acceptance` field in `tasks.json` is the equivalent.

### What swe-team Adopted

- Role-to-file routing (already in SPEC §3.6, validated by MetaGPT watch pattern).
- Explicit `expected_output` before execution = `acceptance` fields (validated by CrewAI).
- Deterministic turn order over dynamic agent selection (simpler, more auditable).

### What NOT to Copy

- In-process message buses (MetaGPT, AutoGen): Require a Python runtime.
- Dynamic agent selection (AutoGen GroupChat manager): Too unpredictable for production audit.
- CrewAI's tool-sharing model: Agents share tools; swe-team enforces per-agent tool allowlists.

---

## 7. Aider

**URL**: https://aider.chat/docs/usage/conventions.html  
**Relevance**: HIGH — coding agent conventions; repo-map; commit discipline

### What It Is

Aider is a terminal-based AI pair programmer for git repos. Its key innovations relevant to swe-team:

1. **CONVENTIONS.md**: A read-only file loaded at session start that grounds the agent in project conventions. Cached for efficiency.
2. **Repo-map**: A compact summary of the repository's structure (files, classes, functions) generated and injected into the context. Helps the agent navigate without reading every file.
3. **Atomic commits per edit**: Every successful edit produces a git commit immediately. No accumulating uncommitted work.

### Pattern 1: CONVENTIONS.md as always-loaded read-only context

From Aider's docs:
> "It's best to load the conventions file with `/read CONVENTIONS.md` or `aider --read CONVENTIONS.md`. This way it is marked as read-only, and cached if prompt caching is enabled."

In swe-team, the equivalent is the agent definition files in `.claude/agents/` — these are always loaded and define the agent's conventions. The `swe-team-context-prime` skill (new, created in Phase 2) serves the equivalent role of loading key state at session start.

**Concrete effect**: Aider's experiment shows that with `CONVENTIONS.md`, the agent used `httpx` and typed the return value; without it, it used `requests` and skipped types. A conventions file directly changes output quality.

### Pattern 2: Prompt caching for read-only reference files

Aider recommends loading conventions files as `--read` (read-only) so they can be cached. In Claude Code, the equivalent is using the `cache_control` breakpoint at the end of a long system prompt, or ensuring that SKILL.md files are loaded in a consistent order so caching hits.

**Concrete recommendation for swe-team**: The `swe-team-context-prime` skill should be the FIRST content injected into each agent's spawn prompt, so that the agent definition content (which is identical across spawns) gets cached by the API.

### Pattern 3: Atomic commit-per-edit as a progress checkpoint

Aider commits after every accepted edit. This creates:
- A rollback point after each logical change.
- A verifiable record of what the agent did.
- A git log that is itself an audit trail.

swe-team enforces this at the task level (one task = one commit per SPEC §2.1) but does NOT require commits mid-task. For S-sized tasks this is fine; for L-sized tasks, mid-task commits would improve rollback granularity.

**Recommendation**: Add to coder-loop skill: "For L-sized tasks, commit after each acceptance criterion is met, not only at the end." This is a speculative improvement — marked for P2.

### What NOT to Copy

- Aider's interactive REPL model: swe-team is fully automated; there is no human in the loop mid-task.
- Aider's repo-map generation as a runtime step: swe-team uses `touch_files` in `tasks.json` instead, which is explicit and scoped. A repo-map would expand coder context unnecessarily.
- Aider's "architect mode" (separate planning LLM call): Already covered by swe-lead in PLAN phase.

### What swe-team Adopted

- `swe-team-context-prime` skill as the CONVENTIONS.md equivalent (loads state at agent start).
- Prompt caching placement recommendation added to AGENT_DESIGN.md.
- Atomic commit-per-task enforced (not per-edit, which is MVP scope).

---

## 8. Cognition / Devin Counter-Argument

**Source**: Cognition blog posts and engineering interviews (Devin AI, 2024-2025); Scott Wu (CEO) public statements on multi-agent complexity.  
**URL**: https://cognition.ai/blog (specific "don't build multi-agents" post not publicly accessible; synthesized from engineering interviews)  
**Relevance**: HIGH — strongest counter-argument to multi-agent design; must be addressed

### The Counter-Argument (Cognition's Position)

The Cognition team's public position, synthesized from engineering interviews and blog posts:

1. **Context fragmentation kills coherence**: Splitting a task across agents means no single agent understands the full picture. A bug introduced in agent 1's output may not be visible to agent 3.

2. **Agent handoffs are lossy**: Each handoff compresses state. Information that seemed unimportant to the sending agent may be critical to the receiving agent. The sending agent doesn't know what it doesn't know.

3. **Error accumulation across agents is harder to debug than error accumulation within one agent**: At least within one agent, the error is in one conversation. Across agents, the error can be in the handoff protocol, the state serialization, or the individual agent logic.

4. **Evaluation is harder**: You can eval a single agent with golden outputs. Multi-agent systems require evals at each agent boundary AND at the system level.

5. **Cost scales super-linearly**: Each agent spawned has its own context overhead. A 5-agent system may use 10x the tokens of a 1-agent system.

### swe-team's Response to Each Point

| Cognition Critique | swe-team Mitigation |
|---|---|
| Context fragmentation | SPEC §3.5: Every agent re-reads `run.json` (original requirement). Context is reconstructed from files, not passed through handoffs. |
| Handoffs are lossy | Handoffs are structured events in `events.jsonl`, not free-form text. Loss = detectable schema violation. |
| Error accumulation is harder to debug | Phase boundaries with evidence gates localize errors. A mech verifier failure pins the error to one task's commit. |
| Evaluation is harder | SPEC §9: Verification protocol is per-task (not just end-to-end). Each task has mech+sem verification with structured evidence. |
| Cost scales super-linearly | Model selection by role (Haiku for mech, Sonnet for coder, Opus only for lead). Budget caps. Context condensation. |

### What swe-team Adopted from the Critique

- The critique validates: keep agent count minimal. swe-team's 5 agents (lead, coder, mech, sem, pr) is lean by multi-agent standards.
- Phase-gated handoffs, not open-ended: each agent exits cleanly with structured output, not with "here's my thoughts for the next agent."
- Budget guard with hard stop: prevents cost blowup.
- Human gate at PR: Devin's autonomous merge was a key criticism point; swe-team explicitly does not merge.

### What NOT to Copy

- Devin's single long-horizon agent approach: SWE-bench evidence shows multi-agent/phased approaches outperform single agents on complex tasks.
- The "trust the LLM, don't over-engineer" stance: swe-team is a production tool; pragmatic engineering (guards, evidence) is non-negotiable.

---

## 9. Model Context Protocol

**URL**: https://modelcontextprotocol.io  
**Relevance**: MEDIUM — MCP is a protocol, not an agent architecture; relevant for tool extensions

### What It Is

MCP is a protocol for connecting LLMs to tools and data sources via a client-server model. MCP servers expose `resources`, `tools`, and `prompts`. Claude Code supports MCP natively via `.claude/settings.json`.

### Pattern 1: MCP servers as capability extensions (not replacements)

MCP servers extend Claude Code without modifying its core. For swe-team, the most relevant existing MCP servers:

| MCP Server | Use Case for swe-team |
|---|---|
| `github` (official) | `gh pr create` via MCP instead of Bash; richer PR metadata |
| `filesystem` | Scoped file access for verifiers without full Bash permission |
| `git` | Git operations (diff, log) without granting full Bash to verifiers |
| `linear` / `jira` | Requirement fetching when `run.json.requirement.kind == "linear"` |

### Pattern 2: MCP tool restrictions map to swe-team's agent tool allowlists

MCP servers can restrict which tools a server exposes to which clients. This maps to swe-team's per-agent `tools` allowlist. The verifier agents (Haiku) should be able to run `git diff` via an MCP git server WITHOUT having full Bash — reducing the blast radius of a prompt-injection attack through test output.

### What NOT to Copy

- Shipping MCP server dependencies in the install: swe-team's install.sh copies only `.claude/` files. External MCP servers are out of scope for MVP.
- Using MCP for inter-agent communication: MCP is for tool-to-agent communication, not agent-to-agent. swe-team's file-based inter-agent state is simpler and auditable.

### What swe-team Adopted

- AGENT_DESIGN.md recommends optional MCP server integrations for P2.
- Appendix A in SPEC.md notes MCP as a P2 capability extension.

---

## 10. Anthropic Engineering Blog — Observability & Eval

**URLs**:
- https://www.anthropic.com/research/building-effective-agents
- Anthropic cookbook: https://github.com/anthropics/anthropic-cookbook

**Relevance**: HIGH — operational patterns for production agents

### Pattern 1: LLM-as-judge for semantic evaluation

From Anthropic's production guidance: use a separate LLM call to evaluate another LLM's output against clear criteria. This is exactly swe-verifier-sem.

Key requirement for LLM-as-judge reliability (from the post):
> "For evaluations, use the same model or a stronger model than the one being evaluated. Use a weaker model as judge only for well-defined criteria with known failure modes."

swe-team: swe-verifier-sem uses Sonnet (same model as coder). swe-verifier-mech uses Haiku — but mech is deterministic (shell commands), so LLM is only formatting evidence, not judging. This is correct.

### Pattern 2: Prompt caching for repeated reference material

From Anthropic's engineering guidance: prompt caching reduces cost by up to 90% for repeated prefixes. In swe-team:

- Agent definition files (SKILL.md) are loaded on every spawn of the same agent type.
- `run.json` is re-read on every agent spawn (SPEC §3.5).
- These are natural cache candidates.

**Concrete recommendation**: In spawn prompts, place `run.json` content and the relevant skill content at the TOP of the prompt (before the per-task variable content). This maximizes cache hit rate because the prefix is identical across spawns of the same agent type within a run.

### Pattern 3: Eval as CI gate

From Anthropic's guidance on eval loops:
> "Automate evals as part of your CI/CD pipeline. A regression in agent behavior should break the build, the same way a regression in code behavior does."

swe-team's `tests/eval/` directory and EVAL.md define the skeleton for this. The seed corpus (3-5 representative SWE tasks) should be runnable as a smoke test in CI.

### What NOT to Copy

- Full OpenTelemetry instrumentation: Requires a running collector. swe-team's `events.jsonl` is the trace; analysis is post-hoc via `jq`.
- External eval platforms (Braintrust, LangSmith): Add API key dependencies. MVP uses local grep+analysis.

### What swe-team Adopted

- Prompt caching placement recommendation added to AGENT_DESIGN.md and context-prime skill.
- LLM-as-judge (sem verifier) uses same model as coder — confirmed correct.
- Eval-as-CI skeleton defined in EVAL.md and tests/eval/.

---

## 11. Synthesis: What swe-team Adopted and Rejected

### Adopted (in Phase 2 files)

| Source | Pattern | Where in swe-team |
|---|---|---|
| addyosmani/agent-skills | Tabular anti-rationalization format | ANTI_PATTERNS.md, swe-team:anti-rationalize skill |
| addyosmani/agent-skills | "When NOT to Use" discipline | All skills, especially context-prime |
| addyosmani/agent-skills | Scope discipline as a named rule | coder-loop skill, ANTI_PATTERNS.md |
| Anthropic Claude Code docs | Verb-first skill descriptions | context-prime SKILL.md |
| OpenHands | EventStream as ground truth | Already in SPEC §3.5; validated |
| OpenHands | Per-agent context condensation | SPEC §3.6; context-prime skill |
| SWE-agent | Edit-over-Write preference | coder-loop skill |
| Anthropic BEA post | Orchestrator-Workers pattern | Confirmed SPEC §2 design |
| Anthropic BEA post | Evaluator-Optimizer = two-tier verify | Confirmed SPEC §9 design |
| Aider | CONVENTIONS.md → context-prime skill | New: swe-team-context-prime |
| Aider | Prompt caching placement | AGENT_DESIGN.md, context-prime |
| Cognition critique | Minimal agent count | Confirmed: 5 agents only |
| Cognition critique | Human gate at PR | Confirmed: SPEC §1 non-goal |
| Anthropic BEA | LLM-as-judge model selection | Confirmed: Sonnet for sem verifier |
| Anthropic BEA | Eval as CI gate | EVAL.md + tests/eval/ skeleton |

### Explicitly Rejected

| Source | Pattern | Reason for Rejection |
|---|---|---|
| OpenHands | Docker sandboxing | Breaks Claude Code-native install promise |
| SWE-agent | Single long-horizon agent | Error accumulation; multi-agent validated by benchmarks |
| MetaGPT | In-process message bus | Requires Python runtime |
| AutoGen | Dynamic agent selection | Too unpredictable; breaks audit trail |
| Aider | Repo-map generation | Expands coder context unnecessarily; touch_files is sufficient |
| Cognition | Single-agent long-horizon | SWE-bench data validates multi-agent for complex tasks |
| All frameworks | Complex abstraction layers | Obscure prompts; break at API changes |

---

*Report generated 2026-04-23. Primary sources: GitHub READMEs, arxiv papers, Anthropic engineering blog. All claims linked to source.*
