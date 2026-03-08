#!/bin/bash
# Run all E2E test suites.
#
# Prerequisites: the desktop app must be running (./launch-desktop.sh)
#
# Usage:
#   ./tests/run-tests.sh          # run all suites
#   ./tests/run-tests.sh karma    # run only the karma suite

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
API="http://localhost:3456/api/debug"

SUITES_PASS=0
SUITES_FAIL=0
SUITES_SKIP=0
FILTER="${1:-}"

# ── Preflight: debug API reachable ────────────────────────────────
echo "=== Geogram E2E Test Runner ==="
echo ""
echo "Checking debug API at $API ..."
if ! curl -sf -X POST "$API" -H "Content-Type: application/json" -d '{"action":"karma_profile"}' >/dev/null 2>&1; then
  echo "FATAL: debug API not reachable. Is the desktop app running? (./launch-desktop.sh)"
  exit 1
fi
echo "Debug API OK."
echo ""

# ── Discover and run suites ───────────────────────────────────────
run_suite() {
  local suite_dir="$1"
  local suite_name
  suite_name="$(basename "$suite_dir")"

  if [ -n "$FILTER" ] && [ "$suite_name" != "$FILTER" ]; then
    return
  fi

  local tests=("$suite_dir"/*_test.sh)
  if [ ${#tests[@]} -eq 0 ] || [ ! -f "${tests[0]}" ]; then
    SUITES_SKIP=$((SUITES_SKIP + 1))
    echo "[$suite_name] SKIP (no *_test.sh files)"
    return
  fi

  echo "--- Suite: $suite_name (${#tests[@]} test(s)) ---"
  local suite_ok=true

  for test_file in "${tests[@]}"; do
    local test_name
    test_name="$(basename "$test_file")"
    echo ""
    echo "  Running $test_name ..."
    if bash "$test_file"; then
      echo "  $test_name: OK"
    else
      echo "  $test_name: FAILED"
      suite_ok=false
    fi
  done

  echo ""
  if $suite_ok; then
    SUITES_PASS=$((SUITES_PASS + 1))
    echo "[$suite_name] PASS"
  else
    SUITES_FAIL=$((SUITES_FAIL + 1))
    echo "[$suite_name] FAIL"
  fi
  echo ""
}

for suite_dir in "$DIR"/*/; do
  # skip the outdated archive
  case "$(basename "$suite_dir")" in
    outdated_*) continue ;;
  esac
  run_suite "$suite_dir"
done

# ── Summary ───────────────────────────────────────────────────────
TOTAL=$((SUITES_PASS + SUITES_FAIL + SUITES_SKIP))
echo "=== Summary: $SUITES_PASS/$TOTAL suites passed, $SUITES_FAIL failed, $SUITES_SKIP skipped ==="

if [ "$SUITES_FAIL" -gt 0 ]; then
  exit 1
fi
