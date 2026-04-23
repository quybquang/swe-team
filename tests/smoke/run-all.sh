#!/usr/bin/env bash
# tests/smoke/run-all.sh — run all swe-team smoke tests

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

fail=0
run() {
  local t="$1"
  echo ""
  echo "━━━ $t ━━━"
  if bash "$DIR/$t"; then
    echo "PASS $t"
  else
    echo "FAIL $t"
    fail=$((fail + 1))
  fi
}

run test-schemas.sh
run test-hooks.sh
run test-install.sh

echo ""
if (( fail == 0 )); then
  echo "All smoke tests passed."
else
  echo "$fail smoke test(s) failed."
  exit 1
fi
