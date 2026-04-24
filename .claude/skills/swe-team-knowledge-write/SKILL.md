---
name: swe-team:knowledge-write
description: >
  Write lessons learned from a completed swe-team run into the configured knowledge
  write_target (local vault, Notion, or Confluence). Invoke after RETRO phase emits
  retro_complete — swe-lead calls this as the final step before the run fully terminates.
---

# Knowledge Write

## Overview

`swe-team:knowledge-write` reads the lessons produced by `swe-team:retro` from
`.claude/swe-team/learnings.jsonl` and persists them in the external knowledge store
configured as `swe-team.config.json#knowledge.write_target`. This closes the
bidirectional knowledge loop: agents read from the vault at CLARIFY time; agents write
back after RETRO.

Each write_target type uses its own adapter:

| Target type | Write adapter |
|---|---|
| `local` | Create a dated markdown file under `wiki/projects/<project_namespace>/learnings/`. Follow vault frontmatter conventions. Update `wiki/index.md` and `_meta/processing-log.md`. |
| `notion` | `notion-create-pages` MCP tool — create a page in the configured space |
| `confluence` | Atlassian MCP create page in the configured space |

If `knowledge.write_target` is empty, unset, or the target source does not have `"write"`
in its `capabilities`, the skill is a no-op — exits cleanly without error.

## When to Use

- A run has just reached terminal status (succeeded, failed, or aborted).
- `swe-team:retro` has completed and written at least one entry to `learnings.jsonl`.
- `swe-team.config.json#knowledge.write_target` is set and matches a source id with `"write"` capability.
- The run's lessons have NOT already been written to the vault (idempotent guard: check `run_id` in processing log before writing).

## When NOT to Use

- `knowledge.write_target` is empty or unset.
- No source with a matching `id` has `"write"` in `capabilities`.
- The retro skill did not run or wrote 0 lessons.
- You are NOT in post-RETRO state.

## Process

### 1. Preflight

```bash
# Resolve write target config
cat swe-team.config.json | jq -r '.knowledge.write_target // ""'
cat swe-team.config.json | jq -r '.knowledge.sources // []'
```

If `write_target` is empty string, or no source with matching `id` exists, or that source
lacks `"write"` capability — write one-line log and stop:

```bash
jq -nc '{kind:"knowledge_write_skip",reason:"no_write_target_configured"}' \
  >> .claude/swe-team/runs/current/events.jsonl
```

### 2. Read new lessons from this run

```bash
RUN_ID=$(jq -r .run_id .claude/swe-team/runs/current/run.json)
grep "\"evidence_run_id\":\"$RUN_ID\"" .claude/swe-team/learnings.jsonl
```

If zero lessons found for this run_id, skip write (emit `knowledge_write_skip` with
`reason: "no_lessons_for_run"`).

### 3. Format each lesson as a knowledge page

For each lesson `{scope, lesson, evidence_run_id, tags?}`, compose a structured markdown page:

```markdown
---
title: <scope>: <first 60 chars of lesson>
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
tags: [swe-team, <scope>, <tags from lesson if present>]
source: .claude/swe-team/runs/<run_id>/learnings.jsonl
related: []
---

# <scope>: <first 60 chars of lesson>

## Summary

<lesson text, verbatim>

## Context

- **Run**: <run_id>
- **Scope**: <scope>
- **Date**: <YYYY-MM-DD>

## My Takeaway

<1–2 sentence synthesis: what should future agents do differently based on this lesson?>
```

### 4. Write to target — adapter dispatch

#### `local` adapter

```bash
VAULT_PATH=$(cat swe-team.config.json | jq -r '.knowledge.sources[] | select(.id==<write_target>) | .path')
NS=$(cat swe-team.config.json | jq -r '.knowledge.sources[] | select(.id==<write_target>) | .project_namespace // "default"')
DATE=$(date +%Y-%m-%d)
SLUG=$(echo "<lesson first 40 chars>" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)

TARGET_DIR="$VAULT_PATH/wiki/projects/$NS/learnings"
mkdir -p "$TARGET_DIR"
TARGET_FILE="$TARGET_DIR/$DATE-$SLUG.md"
```

Before writing, check for an existing page with the same topic:
```bash
grep -rl "$SLUG" "$TARGET_DIR/" 2>/dev/null | head -1
```
- If a similar page exists: update it by appending a new `## Update <date>` section rather than creating a duplicate.
- If no similar page: write the new file.

After writing, append to `$VAULT_PATH/wiki/index.md`:
```
- [[wiki/projects/<ns>/learnings/<slug>]] — <lesson first 60 chars> (<date>)
```

Append to `$VAULT_PATH/_meta/processing-log.md`:
```
| <date> | swe-team run <run_id> | 1 | 0 | auto-written by swe-team:knowledge-write |
```

#### `notion` adapter

Invoke `notion-create-pages` MCP with:
- `parent`: the configured `space_id` or a "swe-team learnings" database page
- `properties.title`: the formatted page title
- `content`: the full markdown page body

If the MCP tool is unavailable:
```bash
jq -nc '{kind:"knowledge_write_warn",target:"notion",reason:"MCP unavailable"}' \
  >> .claude/swe-team/runs/current/events.jsonl
```
Fall back to local write if a `local` source with `"write"` capability also exists.

#### `confluence` adapter

Invoke Atlassian MCP create page in `space_key` from config, under a "swe-team Learnings" parent page.
If unavailable, same fallback logic as Notion.

### 5. Emit event

```bash
RUN_ID=$(jq -r .run_id .claude/swe-team/runs/current/run.json)
jq -nc --arg rid "$RUN_ID" --arg ts "$(date -u +%FT%TZ)" \
  --arg target "<write_target_id>" --argjson n <lessons_written> \
  '{kind:"knowledge_write",ts:$ts,run_id:$rid,agent:"swe-lead",
    write_target:$target,lessons_written:$n}' \
  >> .claude/swe-team/runs/current/events.jsonl
```

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "This lesson is obvious — no need to write it to the vault." | Write it anyway. "Obvious" lessons frequently aren't obvious to future agents or teammates who weren't present for this run. |
| "The lesson is project-specific so it won't be useful." | Project-specific lessons are exactly what `wiki/projects/<ns>/learnings/` is for. Write there first; if it generalizes, a future `distill` pass can promote it. |
| "Writing to Notion might create noise in the team's workspace." | The lesson goes into a dedicated learnings section. Noise risk is the team's decision — they configured `write_target`. |
| "I'll write one big combined lesson for the whole run." | Write one page per lesson entry from `learnings.jsonl`. Granular pages are findable by search; one megapage is not. |
| "The vault index will get out of sync." | Always update `wiki/index.md` and `_meta/processing-log.md` as part of the write. No shortcuts. |

## Red Flags

- A lesson entry has an empty or single-word `lesson` field — this was written by a poorly-calibrated retro. Write it anyway but flag: `[Note: lesson description is sparse — review manually]`.
- The `local` vault path does not exist — stop, emit `knowledge_write_warn` with `reason: "vault_path_not_found"`. Do NOT create the vault. Tell the user to run `vault-init` first.
- The same lesson slug already exists and was written less than 1 day ago (duplicate run?) — skip write, emit `knowledge_write_skip` with `reason: "duplicate_within_24h"`.
- `wiki/index.md` or `_meta/processing-log.md` don't exist in the vault — do NOT create them. Emit `knowledge_write_warn` with `reason: "vault_not_initialized"` and skip the index/log update.

## Verification

After this skill completes:
- `events.jsonl` contains a `{kind:"knowledge_write"}` or `{kind:"knowledge_write_skip"}` event.
- If write happened: the target file exists at the expected path (local) or the MCP confirmed creation (Notion/Confluence).
- No duplicate pages written (idempotent: check run_id in processing log before any write).
- `wiki/index.md` contains a new entry for the written page (local adapter only).
- `_meta/processing-log.md` contains a new row for this run (local adapter only).
