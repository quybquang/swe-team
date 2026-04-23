#!/usr/bin/env bash
# uninstall.sh — remove swe-team from a target repo
#
# Only removes swe-*-prefixed files and swe-team-specific state.
# Leaves the user's other .claude/ contents alone.

set -euo pipefail

TARGET="${1:-}"
err() { echo "swe-team uninstall: $*" >&2; exit 1; }
info() { echo "swe-team uninstall: $*"; }

[[ -n "$TARGET" ]] || err "usage: $0 <target-dir>"
[[ -d "$TARGET" ]] || err "not a dir: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"

# Agents
for f in "$TARGET/.claude/agents/"swe-*.md; do
  [[ -f "$f" ]] && rm -v "$f"
done

# Skills
for d in "$TARGET/.claude/skills/"swe-team-*; do
  [[ -d "$d" ]] && rm -rvf "$d"
done

# Slash command
rm -vf "$TARGET/.claude/commands/swe-team.md"

# References (only those we ship)
for f in event-schema.json tasks-schema.json verification-schema.json config-schema.json \
         commit-conventions.md pr-template.md security-checklist.md; do
  rm -vf "$TARGET/.claude/references/$f"
done

# Hooks
for f in init-run.sh guard-destructive-git.sh budget-gate.sh \
         track-file-edit.sh capture-test-output.sh phase-exit-verify.sh; do
  rm -vf "$TARGET/.claude/hooks/$f"
done

# Package state (keep runs/ for audit unless --purge)
rm -vf "$TARGET/.claude/swe-team/VERSION"
rm -vf "$TARGET/.claude/swe-team/config.default.json"

# Config
rm -vf "$TARGET/swe-team.config.json"

# Detach hook entries from settings.json (leave other hooks)
if [[ -f "$TARGET/.claude/settings.json" ]]; then
  python3 - "$TARGET/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: t = json.load(f)
if "hooks" in t:
  for event, entries in list(t["hooks"].items()):
    t["hooks"][event] = [
      e for e in entries
      if not any(
        isinstance(h, dict) and ".claude/hooks/" in h.get("command", "") and any(
          k in h["command"] for k in (
            "init-run.sh","guard-destructive-git.sh","budget-gate.sh",
            "track-file-edit.sh","capture-test-output.sh","phase-exit-verify.sh"))
        for h in e.get("hooks", [])
      )
    ]
    if not t["hooks"][event]:
      del t["hooks"][event]
with open(p, "w") as f:
  json.dump(t, f, indent=2); f.write("\n")
PY
  info "cleaned swe-team hooks from .claude/settings.json"
fi

info "done. runs/ audit trail preserved at .claude/swe-team/runs/"
