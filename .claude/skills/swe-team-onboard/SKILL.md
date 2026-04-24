---
name: swe-team:onboard
description: >
  Interactive setup wizard for swe-team. Auto-detects project settings, presents
  numbered option menus in the user's chosen language, and writes swe-team.config.json
  after a final confirmation brief. No JSON editing, no free-text guessing.
---

# Onboard

## Overview

`swe-team:onboard` is a choice-driven setup wizard. It **auto-detects** project settings,
presents them as **numbered options with a highlighted default**, collects answers, and
writes `swe-team.config.json` only after showing the user a full **confirmation brief**.

Design principles:
- Start in English. Switch to the user's chosen language after Section 0.
- Every input is a numbered pick from a concrete list — never open-ended unless unavoidable.
- Auto-detected value is always Option 1 (marked `← recommended` or `← detected`).
- Free-text is only requested for values that cannot be listed: file paths, IDs.
- After every free-text input, echo back what you understood and ask "correct?".
- A single full-screen brief summarizes ALL choices before any file is written.

## When to Use

- `/swe-team-setup` is invoked (first-time or reconfigure).
- A teammate is confused about their existing config.
- A project's stack, branch, or knowledge source has changed.

## When NOT to Use

- A run is in progress (`run.json` status = `running`). Do not reconfigure mid-run.
- Inside a spawned subagent. This skill requires the main conversation thread.

---

## Process

Work through sections **strictly in order**. Never skip ahead. Never show raw JSON before
Section 8. All example prompts below are in English — after Section 0, render them in the
user's chosen language.

---

### Section 0 — Language

Speak English. Present this as the very first message:

```
👋 Welcome to swe-team setup!

What language would you like to use?

  1. English  ← default
  2. Tiếng Việt
  3. 日本語
  4. Español
  5. Other — type the language name
```

Switch ALL subsequent communication to the chosen language immediately and permanently.
If the user types a language name (e.g. "French"), accept it as Option 5.

---

### Section 1 — Auto-detect project

Run silently before showing anything:

```bash
# Detect stack
[ -f package.json ]   && HAS_PKG=yes || HAS_PKG=no
[ -f go.mod ]         && HAS_GO=yes  || HAS_GO=no
[ -f pyproject.toml ] || [ -f requirements.txt ] && HAS_PY=yes || HAS_PY=no

# Detect package manager
[ -f pnpm-lock.yaml ]   && PM=pnpm
[ -f yarn.lock ]        && PM=yarn
[ -f package-lock.json ] && PM=npm

# Read scripts from package.json
TEST_CMD=$(cat package.json 2>/dev/null | jq -r '.scripts.test // ""')
LINT_CMD=$(cat package.json 2>/dev/null | jq -r '.scripts.lint // ""')
TYPE_CMD=$(cat package.json 2>/dev/null | jq -r '.scripts.typecheck // .scripts["type-check"] // ""')

# Detect branches
BRANCHES=$(git branch -a 2>/dev/null \
  | grep -oE 'origin/(dev|develop|main|master)' \
  | sed 's/origin\///' | sort -u)
```

Show a formatted summary (in the user's language from Section 0):

```
─────────────────────────────────
  Project detected
─────────────────────────────────
  Stack     : Node.js
  Manager   : pnpm
  Test      : pnpm test
  Lint      : pnpm run lint
  Typecheck : pnpm run typecheck

  Does this look right?

  1. Yes, continue  ← recommended
  2. Change test command
  3. Change lint command
  4. Change typecheck command
  5. My stack is different — pick again
─────────────────────────────────
```

Handle each choice:
- **1**: lock values, proceed to Section 2.
- **2/3/4**: ask free text for that command. Echo: "Test command will be: `<input>`. Correct?" Then return to the summary.
- **5**: show stack picker:
  ```
  Choose your stack:
    1. Node.js (npm)
    2. Node.js (pnpm)
    3. Node.js (yarn)
    4. Go
    5. Python
    6. No test/lint/typecheck (skip verification)
  ```
  After picking, ask each command: "What is your test command? (leave blank to skip)"

If no recognizable stack is found, go directly to the stack picker.

---

### Section 2 — Base branch

Show only branches that actually exist in the repo:

```
─────────────────────────────────
  Base branch (PRs will target this)
─────────────────────────────────
  1. dev    ← detected
  2. main
  3. develop
  4. master
  5. Enter a different branch name
─────────────────────────────────
```

Mark the first detected branch as default.
If only one branch exists, show it alone with a confirm prompt.
If Option 5: ask free text → echo back → "Correct?"

---

### Section 3 — Knowledge sources

```
─────────────────────────────────
  Knowledge sources (optional)
─────────────────────────────────
  Agents can read your team's docs and internal
  processes before planning any code changes.

  Where does your team store documentation?

  1. Skip for now  ← recommended if not set up yet
  2. Local wiki folder (e.g. ~/vault)
  3. Notion
  4. Confluence
  5. Linear (read tickets)
  6. Multiple sources — add one by one
─────────────────────────────────
```

#### Option 1 — Skip
Set `knowledge.sources = []`, `write_target = ""`. Proceed to Section 4.

#### Option 2 — Local vault
Ask path as free text:
```
  Path to your wiki folder?
  (e.g.  ~/vault  or  /Users/yourname/notes)
  →
```
Echo: "Folder: `/Users/yourname/notes`. Correct?"

Check existence:
```bash
[ -d "<expanded_path>" ] && echo "exists" || echo "missing"
```
If missing:
```
  ⚠ That folder doesn't exist yet.

  1. Enter a different path
  2. Skip for now (set up later with /swe-team-setup)
```

If path exists, detect sub-folders and ask namespace:
```bash
ls "<vault_path>/wiki/projects/" 2>/dev/null
```
```
  What is this project's name in the wiki?
  (Used for the path  wiki/projects/<name>)

  1. cardiy    ← matches repo name
  2. my-project
  3. Enter a different name
```
Recommend any folder name that matches the current git repo name.

Then ask write-back:
```
  After each run, write lessons back to this folder?

  1. Yes — automatically save lessons  ← recommended
  2. No  — read only
```

#### Option 3 — Notion
```
  Notion workspace or database ID?
  (Find it in the URL: notion.so/.../[ID-here])
  →
```
Echo + confirm. Then:
```
  Access level:

  1. Read only  — agents reference Notion when planning
  2. Read + write — also save lessons after each run
```

#### Option 4 — Confluence
```
  Confluence space key?
  (Usually 2–5 uppercase letters in the URL, e.g. ENG · PROD · WIKI)
  →
```
Echo + confirm. Same read/write choice as Notion.

#### Option 5 — Linear
Linear is read-only. Confirm:
```
  Linear will be used to read related tickets when analyzing requirements.
  Read-only — no writes.

  1. Add Linear  ← recommended
  2. Skip
```

#### Option 6 — Multiple sources
After each source is added:
```
  Source 1 added: local vault ~/vault

  Add another source?
  1. Add Notion
  2. Add Confluence
  3. Add Linear
  4. Done — no more sources
```
If more than one source supports write, ask:
```
  Which source should receive lessons after each run?
  1. local vault ~/vault  ← recommended (supports write)
  2. Notion <id>          (supports write)
  3. Don't write lessons anywhere
```

---

### Section 4 — Budget

```
─────────────────────────────────
  Cost limit per run
─────────────────────────────────
  1. Standard — $15 · 2M tokens   ← recommended
  2. Light    — $5  · 500K tokens  (small projects, simple tasks)
  3. Heavy    — $30 · 4M tokens   (large codebase, complex tasks)
  4. Custom   — enter your own limits
─────────────────────────────────
```

If Option 4:
```
  USD limit per run? (e.g. 10)
  →

  Token limit? (e.g. 1000000)
  →
```
Echo both. "Correct?"

---

### Section 5 — Security policy

```
─────────────────────────────────
  Security policy
─────────────────────────────────
  When a vulnerability is found in the code
  (SQL injection, exposed secrets, XSS, etc.):

  1. Strict — Block the PR, require a fix  ← recommended
     (critical + high → block · medium → warn in PR)

  2. Balanced — Warn but still open PR
     (all severities → noted in PR body)

  3. Off — No security scanning
─────────────────────────────────
```

Map:
- 1 → `fail_on: ["critical","high"]`, `warn_on: ["medium"]`
- 2 → `fail_on: []`, `warn_on: ["critical","high","medium"]`
- 3 → `enabled: false`

---

### Section 6 — Clarification mode

```
─────────────────────────────────
  Requirement clarification
─────────────────────────────────
  Before coding, swe-team analyzes the requirement.
  How should it handle ambiguity?

  1. Autonomous  ← recommended
     Analyzes and makes assumptions from the codebase.
     Doesn't ask you. Faster. Good for unattended runs.

  2. Interactive
     Asks you 3–5 clarifying questions before starting.
     More precise. Requires you to be available.
─────────────────────────────────
```

---

### Section 7 — PR settings

```
─────────────────────────────────
  Pull Request type
─────────────────────────────────
  1. Regular PR (ready for review)  ← recommended
  2. Draft PR (marked as work-in-progress)
─────────────────────────────────
```

---

### Section 8 — Confirmation brief (REQUIRED before any write)

After all sections answered, show a complete summary. Do NOT write any file before this.

```
══════════════════════════════════════════
  REVIEW YOUR SWE-TEAM CONFIGURATION
══════════════════════════════════════════

  📦 Project
     Stack     : Node.js · pnpm
     Test      : pnpm test
     Lint      : pnpm run lint
     Typecheck : pnpm run typecheck
     Branch    : dev

  💰 Budget
     Limit     : $15 per run · 2M tokens

  🔐 Security
     Policy    : Strict
     Critical/High → block PR · Medium → warn in PR body

  🧠 Clarification
     Mode      : Autonomous (no user prompts)

  📚 Knowledge sources
     1. ~/vault — read + write  (namespace: cardiy)
     2. Linear — read only
     Lessons written to: ~/vault

  🔀 Pull Request
     Type: Regular (not draft)

══════════════════════════════════════════
  Write this configuration? (yes / no / edit)
══════════════════════════════════════════
```

- **"yes"** → write config (Section 9).
- **"no"** → discard and exit.
- **"edit"** → ask which section to revisit:
  ```
  Which section would you like to change?
  1. Project / Stack
  2. Branch
  3. Knowledge sources
  4. Budget
  5. Security
  6. Clarification mode
  7. Pull Request
  ```
  Jump back to that section, then return to the brief.

---

### Section 9 — Write and validate

Write `swe-team.config.json` with all resolved values. No placeholders.

After writing, validate:

```bash
# JSON syntax
python3 -c "import json; json.load(open('swe-team.config.json'))" 2>&1

# Schema (if jsonschema available)
python3 -m jsonschema \
  --instance swe-team.config.json \
  --schema .claude/references/config-schema.json 2>&1 || true
```

If validation fails, show the field name and a plain-language description of the error.
Never say "edit the JSON manually." Instead:
```
  ⚠ Problem: The branch value "<value>" is not valid.
  1. Fix it now — enter a valid branch name
  2. Use the default: "dev"
```

If validation passes:

```
══════════════════════════════════════════
  ✓ swe-team.config.json written!
══════════════════════════════════════════

  Next steps:

  1. Commit the config:
     git add swe-team.config.json
     git commit -m "chore: configure swe-team"

  2. Run your first task:
     /swe-team "Add a small button to test the pipeline"

  Need to change settings later? Run /swe-team-setup again anytime.
══════════════════════════════════════════
```

---

## Anti-Rationalizations

| Excuse | Rebuttal |
|---|---|
| "The user seems technical — I'll ask for raw values." | Always show numbered options first. Free-text is a last resort, only when options can't enumerate the valid set. |
| "I'll skip the echo-back for free-text inputs." | Always echo back what you heard and ask "correct?". A misread path or ID fails silently at runtime. |
| "The brief is too long — I'll shorten it." | Show every section in the brief, no omissions. Users cannot catch errors in sections they cannot see. |
| "User said 'yes' — I can skip showing the brief." | The brief IS the confirmation gate. "yes" must come after reading the brief, not before. |
| "I'll write the config as I collect each answer." | Write exactly once — after the user confirms the full brief. No partial writes. |
| "Vault path doesn't exist — I'll create the folder." | Never create vault directories. Warn and offer to skip. |
| "The user hasn't picked a language yet — I'll use Vietnamese." | Section 0 is in English. Stay in English until the user explicitly picks a language. |

## Red Flags

- User is confused by the namespace question → explain: "It's just a folder name. Use the project name." Suggest the git repo name as default.
- User's vault path exists but has no `wiki/` subdirectory → warn: "This doesn't look like an initialized vault. Knowledge features may not work until you run `vault-init`."
- User enters an empty string for a required free-text field → re-ask with an example.
- User selects "edit" three times on the same section → ask: "Would you like to skip this section and configure it manually later with /swe-team-setup?"
- Validation fails after write → fix in-place by re-asking the offending section. Never tell the user to open the file.

## Verification

After this skill completes:
- `swe-team.config.json` exists at repo root, passes JSON syntax check, and passes schema validation.
- All required fields have real values — no unresolved placeholders.
- The user confirmed the full brief before the file was written.
- The user received the two next-step commands.
- No raw JSON was shown at any point during the wizard.
- All communication after Section 0 was in the user's chosen language.
