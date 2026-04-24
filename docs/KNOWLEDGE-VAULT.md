# Knowledge Vault Integration

> How to connect swe-team to your team's knowledge — Notion, Confluence, a local
> Obsidian vault, or Linear. Agents read context before coding and write lessons back
> after each run.

---

## Why it matters

Without domain context, agents know your codebase but not your business. They'll build
technically correct features that violate business rules, use the wrong terminology, or
duplicate decisions your team already made. The knowledge vault closes this gap.

**Read path (CLARIFY)** — before writing a single line of spec, swe-lead searches the
vault for pages relevant to the requirement. Domain rules, personas, ADRs, and prior
PRDs get injected into the clarification brief.

**Write path (RETRO)** — after every run, lessons are written back to the vault.
Knowledge compounds: run 10 teaches run 11.

---

## Setup

### Option A — guided wizard (recommended)

```
/swe-team-setup
```

The wizard asks which sources you want to connect, walks you through auth, and writes the
`knowledge` block to `swe-team.config.json` for you. No JSON editing.

### Option B — manual config

Add a `knowledge` block to `swe-team.config.json`:

```jsonc
"knowledge": {
  "sources": [
    {
      "id": "local-vault",
      "type": "local",
      "path": "~/vault",
      "project_namespace": "my-project",
      "capabilities": ["read", "write"]
    },
    {
      "id": "team-notion",
      "type": "notion",
      "space_id": "<your-notion-space-id>",
      "capabilities": ["read"]
    },
    {
      "id": "confluence",
      "type": "confluence",
      "space_key": "ENG",
      "capabilities": ["read"]
    },
    {
      "id": "linear",
      "type": "linear",
      "capabilities": ["read"]
    }
  ],
  "write_target": "local-vault"   // id of the source to write lessons back to
}
```

`write_target` must match one source `id` that has `"write"` in `capabilities`.
If unset, lessons are only stored in `learnings.jsonl` (no external write).

---

## Source types

### `local` — Obsidian or any markdown vault

Reads from and writes to a local directory of markdown files.

| Field | Required | Description |
|---|---|---|
| `path` | ✅ | Absolute or `~`-relative path to vault root |
| `project_namespace` | ✅ | Subfolder under `wiki/projects/` for this project |
| `capabilities` | ✅ | `["read"]` or `["read", "write"]` |

**Read**: `grep -r` over `wiki/projects/<project_namespace>/` and `wiki/engineering/`.

**Write**: Creates dated markdown files under `wiki/projects/<project_namespace>/learnings/`
using vault frontmatter convention. Updates `wiki/index.md` and `_meta/processing-log.md`.

The vault must be initialized before write works. If using the
[vault skill format](https://github.com/quybquang/swe-team), run `vault-init` once.
A minimal vault only needs: `wiki/`, `wiki/index.md`, `_meta/processing-log.md`.

---

### `notion` — Notion workspace

Reads from Notion via the `notion-search` MCP tool (requires Notion MCP connected in
Claude Code settings).

| Field | Required | Description |
|---|---|---|
| `space_id` | optional | Filter results to a specific Notion space or database ID |
| `capabilities` | ✅ | `["read"]` or `["read", "write"]` |

**Read**: keyword search via `notion-search` MCP, top 5 results.

**Write** (if `"write"` in capabilities): creates a new page via `notion-create-pages` MCP
in the space identified by `space_id`. Pages follow the same frontmatter structure as the
local vault template.

**Prerequisite**: Notion MCP must be connected. In Claude Code, add to `settings.json`:

```json
"mcpServers": {
  "notion": { ... }
}
```

Or use the `/swe-team-setup` wizard — it detects connected MCPs automatically.

---

### `confluence` — Atlassian Confluence

Reads from Confluence via the Atlassian MCP tool.

| Field | Required | Description |
|---|---|---|
| `space_key` | ✅ | Confluence space key (e.g. `"ENG"`, `"PROJ"`) |
| `capabilities` | ✅ | `["read"]` or `["read", "write"]` |

**Read**: full-text search via Atlassian MCP, filtered to `space_key`.

**Write**: creates a page under a "swe-team Learnings" parent page in the space.

**Prerequisite**: Atlassian MCP must be connected in Claude Code settings.

---

### `linear` — Linear issues

Read-only. Surfaces related Linear tickets for context during CLARIFY.

| Field | Required | Description |
|---|---|---|
| `capabilities` | ✅ | Must be `["read"]` only — write not supported |

**Read**: `list_issues` MCP filtered by extracted keywords.

**Prerequisite**: Linear MCP must be connected in Claude Code settings.

---

## Multiple sources

All sources with `"read"` capability are searched in parallel. Results are merged and
ranked:

- +2 if from `wiki/projects/<project_namespace>/` (project-specific)
- +1 if page title contains a keyword
- +1 if updated within 90 days

Top 6 results across all sources are injected into `knowledge-context.md`.

Write only goes to the single `write_target`. Lessons are never scattered across multiple
stores.

---

## Vault structure (local adapter)

Expected layout (compatible with the vault skill format):

```
~/vault/
├── wiki/
│   ├── index.md                           ← auto-updated by knowledge-write
│   ├── engineering/
│   │   └── patterns/                      ← promoted cross-project patterns
│   └── projects/
│       └── <project_namespace>/
│           ├── README.md                  ← project overview (you write this)
│           ├── domain.md                  ← business rules (you write this)
│           ├── personas.md                ← user roles (you write this)
│           └── learnings/                 ← swe-team writes here
│               └── 2026-04-24-<slug>.md
└── _meta/
    └── processing-log.md                  ← append-only audit log
```

Files you write (`domain.md`, `personas.md`) are the highest-value input for the search
path — they ground agents in your business context before they touch any code.

---

## Opt-out

To disable knowledge integration entirely without removing the config block:

```jsonc
"knowledge": {
  "sources": [],
  "write_target": ""
}
```

Or remove the `knowledge` key from `swe-team.config.json`. The skill exits silently when
no sources are configured.
