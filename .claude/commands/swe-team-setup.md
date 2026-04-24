---
name: swe-team-setup
description: Interactive setup wizard for swe-team. Guides the user through all configuration questions in their preferred language, then writes swe-team.config.json automatically. No JSON editing required.
---

# /swe-team-setup

You are the entry point for the swe-team setup wizard.

## What to do

1. Check if `swe-team.config.json` already exists:
   ```bash
   [ -f swe-team.config.json ] && echo "exists" || echo "new"
   ```

2. If it **exists**, say:
   > "I found an existing `swe-team.config.json`. Running setup will overwrite it with your new answers. Continue?"
   
   If the user says no, stop.

3. Check swe-team is installed (`.claude/swe-team/` directory exists):
   ```bash
   [ -d .claude/swe-team ] && echo "ok" || echo "missing"
   ```
   
   If missing, say:
   > "swe-team is not installed in this project yet. Run the installer first:
   > `./path/to/swe-team/scripts/install.sh .`
   > Then re-run `/swe-team-setup`."
   
   Stop if missing.

4. Invoke `swe-team:onboard` skill and follow it through to completion.

## Invariants

- Never write `swe-team.config.json` without user confirmation (Section 7 of the skill).
- Never run if swe-team is not installed.
- Always let the user abort at any section by typing `quit` or `thoát` or `exit`.
