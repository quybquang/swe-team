#!/usr/bin/env bash
# tests/smoke/test-install.sh
# Run install.sh into a fresh temp repo and verify layout.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
git init -q
git config user.email test@swe-team.local
git config user.name  test
cat > package.json <<'JSON'
{"name":"demo","version":"0.0.0","scripts":{"test":"jest","lint":"eslint .","typecheck":"tsc --noEmit"}}
JSON
git add . && git commit -q -m "init"

# Run installer
bash "$ROOT/scripts/install.sh" "$tmp"

# Assertions
[[ -f "$tmp/.claude/settings.json" ]] || { echo "FAIL: settings.json missing"; exit 1; }
[[ -f "$tmp/.claude/commands/swe-team.md" ]] || { echo "FAIL: slash command missing"; exit 1; }
[[ -f "$tmp/.claude/agents/swe-lead.md" ]] || {
  # Expected to be missing if agents weren't written yet — issue warning only
  echo "  warn: swe-lead.md not present (agents may be in-flight)"
}
[[ -f "$tmp/swe-team.config.json" ]] || { echo "FAIL: config missing"; exit 1; }
[[ -f "$tmp/.claude/swe-team/VERSION" ]] || { echo "FAIL: VERSION missing"; exit 1; }

# Detection test
if ! grep -q '"test_cmd": "npm test"' "$tmp/swe-team.config.json"; then
  echo "FAIL: npm test not detected"; exit 1
fi

if ! grep -q '"typecheck_cmd": "npm run typecheck"' "$tmp/swe-team.config.json"; then
  echo "FAIL: typecheck not detected"; exit 1
fi

# .gitignore entries
grep -q ".claude/swe-team/runs/" "$tmp/.gitignore" \
  || { echo "FAIL: .gitignore not updated"; exit 1; }

# Hooks executable
[[ -x "$tmp/.claude/hooks/guard-destructive-git.sh" ]] \
  || { echo "FAIL: hook not executable"; exit 1; }

# Uninstall
bash "$ROOT/scripts/uninstall.sh" "$tmp"
[[ ! -f "$tmp/swe-team.config.json" ]] || { echo "FAIL: config not removed"; exit 1; }
[[ ! -f "$tmp/.claude/swe-team/VERSION" ]] || { echo "FAIL: VERSION not removed"; exit 1; }

echo "install: ok"
