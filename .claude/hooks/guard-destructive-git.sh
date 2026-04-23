#!/usr/bin/env bash
# guard-destructive-git.sh — PreToolUse(Bash) hook
#
# Blocks destructive git commands. Reads tool input JSON from stdin.
#
# Exit codes:
#   0 — allow
#   2 — block (Claude Code surfaces the stderr message to the agent)

set -euo pipefail

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("command",""))' 2>/dev/null || true)"

if [[ -z "$CMD" ]]; then
  exit 0
fi

block() {
  echo "blocked by swe-team guard: $1" >&2
  exit 2
}

# Force pushes — never, regardless of branch
case "$CMD" in
  *"git push --force"*|*"git push -f "*|*"git push -f"$|*"git push --force-with-lease"*)
    block "destructive: force push"
    ;;
esac

# Hard reset — never
case "$CMD" in
  *"git reset --hard"*)
    block "destructive: git reset --hard"
    ;;
esac

# Interactive rebase — would hang the agent
case "$CMD" in
  *"git rebase -i"*|*"git rebase --interactive"*)
    block "interactive rebase blocked (would hang non-interactive session)"
    ;;
esac

# Branch deletion — only allow if it's a swe-team branch
case "$CMD" in
  *"git branch -D"*|*"git branch --delete --force"*)
    if ! printf '%s' "$CMD" | grep -qE 'swe/'; then
      block "git branch -D outside swe/ namespace"
    fi
    ;;
esac

# Repo nuking
case "$CMD" in
  *"rm -rf .git"*|*"rm -fr .git"*|*"rm -r .git"*)
    block "deleting .git directory"
    ;;
esac

exit 0
