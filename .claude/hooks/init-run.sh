#!/usr/bin/env bash
# init-run.sh — SessionStart hook
#
# Idempotent. Safe to run on every SessionStart, even when a swe-team run is
# not active.
#
# Behavior:
#   - If `.claude/swe-team/runs/current` symlink exists and points at a valid
#     dir, do nothing.
#   - Otherwise this is a no-op — only `/swe-team` slash command creates a run.
#     The hook exists so a stale symlink can be detected and cleaned up.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNS_DIR="$ROOT/.claude/swe-team/runs"
CURRENT_LINK="$RUNS_DIR/current"

# Stale symlink guard
if [[ -L "$CURRENT_LINK" ]] && [[ ! -d "$CURRENT_LINK" ]]; then
  rm -f "$CURRENT_LINK"
fi

exit 0
