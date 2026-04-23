#!/usr/bin/env bash
# install.sh — copy swe-team into a target repo
#
# Usage:
#   ./scripts/install.sh <target-dir>
#   ./scripts/install.sh <target-dir> --force      # overwrite existing swe-* files
#   ./scripts/install.sh <target-dir> --upgrade    # update existing install in place

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
FORCE=0
UPGRADE=0

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=1 ;;
    --upgrade) UPGRADE=1; FORCE=1 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

err() { echo "swe-team install: $*" >&2; exit 1; }
info() { echo "swe-team install: $*"; }

[[ -n "$TARGET" ]] || err "usage: $0 <target-dir> [--force|--upgrade]"
[[ -d "$TARGET" ]] || err "target does not exist: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"

# --- Preflight ---------------------------------------------------------------

cd "$TARGET"
git rev-parse --git-dir >/dev/null 2>&1 || err "$TARGET is not a git repo"

PKG_VERSION="$(cat "$PKG_ROOT/VERSION")"

# Detect existing install
if [[ -f "$TARGET/.claude/swe-team/VERSION" ]]; then
  INSTALLED_VERSION="$(cat "$TARGET/.claude/swe-team/VERSION")"
  if (( FORCE == 0 )); then
    err "already installed at version $INSTALLED_VERSION — use --upgrade to overwrite"
  fi
  info "upgrading from $INSTALLED_VERSION to $PKG_VERSION"
fi

# --- Stack detection ---------------------------------------------------------

detect_stack() {
  local tc="auto" lc="auto" tyc="auto"
  if [[ -f "package.json" ]]; then
    local pm="npm"
    [[ -f "pnpm-lock.yaml" ]] && pm="pnpm"
    [[ -f "yarn.lock"      ]] && pm="yarn"
    if grep -q '"test"' package.json 2>/dev/null; then
      tc="$pm test"
    fi
    if grep -q '"lint"' package.json 2>/dev/null; then
      lc="$pm run lint"
    else
      lc=""
    fi
    if grep -q '"typecheck"' package.json 2>/dev/null; then
      tyc="$pm run typecheck"
    elif [[ -f "tsconfig.json" ]]; then
      tyc="npx tsc --noEmit"
    else
      tyc=""
    fi
  elif [[ -f "go.mod" ]]; then
    tc="go test ./..."
    lc="go vet ./..."
    tyc=""
  elif [[ -f "pyproject.toml" || -f "requirements.txt" ]]; then
    tc="pytest"
    lc="ruff check . 2>/dev/null || true"
    tyc="mypy . 2>/dev/null || true"
  fi

  echo "$tc|$lc|$tyc"
}

detect_base_branch() {
  for b in dev develop main master; do
    if git rev-parse --verify "$b" >/dev/null 2>&1; then
      echo "$b"; return
    fi
  done
  echo "main"
}

IFS='|' read -r DETECTED_TEST DETECTED_LINT DETECTED_TYPE < <(detect_stack)
DETECTED_BASE="$(detect_base_branch)"

info "detected: base=$DETECTED_BASE  test='$DETECTED_TEST'  lint='$DETECTED_LINT'  typecheck='$DETECTED_TYPE'"

# --- Copy .claude/* ----------------------------------------------------------

info "copying .claude/ template"
mkdir -p "$TARGET/.claude"

for sub in commands agents skills references hooks swe-team; do
  src="$PKG_ROOT/.claude/$sub"
  dst="$TARGET/.claude/$sub"
  [[ -d "$src" ]] || continue
  mkdir -p "$dst"
  # Only copy swe-team-prefixed files to avoid clobbering user files
  case "$sub" in
    commands)
      cp "$src/swe-team.md" "$dst/swe-team.md" ;;
    agents)
      for f in "$src"/swe-*.md; do
        [[ -f "$f" ]] && cp "$f" "$dst/$(basename "$f")"
      done ;;
    skills)
      for d in "$src"/swe-team-*; do
        [[ -d "$d" ]] && cp -R "$d" "$dst/$(basename "$d")"
      done ;;
    references)
      for f in "$src"/*.{json,md}; do
        [[ -f "$f" ]] && cp "$f" "$dst/$(basename "$f")"
      done ;;
    hooks)
      for f in "$src"/*.sh; do
        [[ -f "$f" ]] && cp "$f" "$dst/$(basename "$f")" && chmod +x "$dst/$(basename "$f")"
      done ;;
    swe-team)
      cp "$src/VERSION" "$dst/VERSION"
      cp "$src/config.default.json" "$dst/config.default.json" ;;
  esac
done

# --- Merge settings.json -----------------------------------------------------

if [[ -f "$TARGET/.claude/settings.json" ]]; then
  info "merging existing .claude/settings.json with swe-team hooks"
  python3 - "$TARGET/.claude/settings.json" "$PKG_ROOT/.claude/settings.json" <<'PY'
import json, sys
target, src = sys.argv[1], sys.argv[2]
with open(target) as f: t = json.load(f)
with open(src)    as f: s = json.load(f)

t.setdefault("hooks", {})
for event, entries in s.get("hooks", {}).items():
  t["hooks"].setdefault(event, [])
  # dedupe by exact JSON serialization
  existing = {json.dumps(e, sort_keys=True) for e in t["hooks"][event]}
  for entry in entries:
    key = json.dumps(entry, sort_keys=True)
    if key not in existing:
      t["hooks"][event].append(entry)

with open(target, "w") as f:
  json.dump(t, f, indent=2)
  f.write("\n")
PY
else
  cp "$PKG_ROOT/.claude/settings.json" "$TARGET/.claude/settings.json"
fi

# --- Generate swe-team.config.json -------------------------------------------

if [[ -f "$TARGET/swe-team.config.json" && $UPGRADE -eq 0 ]]; then
  info "swe-team.config.json exists — leaving untouched"
else
  info "writing swe-team.config.json with detected stack"
  python3 - "$PKG_ROOT/.claude/swe-team/config.default.json" \
           "$TARGET/swe-team.config.json" \
           "$DETECTED_BASE" "$DETECTED_TEST" "$DETECTED_LINT" "$DETECTED_TYPE" <<'PY'
import json, sys
_, src, dst, base, tc, lc, tyc = sys.argv
with open(src) as f: cfg = json.load(f)
cfg["$schema"] = "./.claude/references/config-schema.json"
cfg["branch"]["base"] = base
cfg["verification"]["test_cmd"]      = tc or ""
cfg["verification"]["lint_cmd"]      = lc or ""
cfg["verification"]["typecheck_cmd"] = tyc or ""
with open(dst, "w") as f:
  json.dump(cfg, f, indent=2)
  f.write("\n")
PY
fi

# --- Record version ----------------------------------------------------------

echo "$PKG_VERSION" > "$TARGET/.claude/swe-team/VERSION"

# --- .gitignore entries ------------------------------------------------------

GI="$TARGET/.gitignore"
add_ignore() {
  local pat="$1"
  if [[ -f "$GI" ]] && grep -qxF "$pat" "$GI"; then return; fi
  echo "$pat" >> "$GI"
  info "added to .gitignore: $pat"
}
add_ignore ".claude/swe-team/runs/*"
add_ignore "!.claude/swe-team/runs/.gitkeep"

mkdir -p "$TARGET/.claude/swe-team/runs"
touch "$TARGET/.claude/swe-team/runs/.gitkeep"

# --- Done --------------------------------------------------------------------

cat <<EOF

swe-team v$PKG_VERSION installed into $TARGET

Next steps:
  1. Review swe-team.config.json — adjust models/budget/base branch if needed.
  2. Commit .claude/ and swe-team.config.json (runs/ is gitignored).
  3. From inside the project, run:  claude  (then:  /swe-team "<your requirement>")

Spec: $PKG_ROOT/SPEC.md
EOF
