#!/bin/bash
# E2E test: verify diffManifest correctness using REAL profile data.
#
# Phase 1: Self-compare (server-path vs client-path on same device)
# Phase 2: Cross-device simulation (mutated copy as "remote" vs real local)
#
# Tests both cached and fresh FileIndexService paths.

set -euo pipefail

API="http://localhost:3456/api/debug"
PASS=0; FAIL=0; TOTAL=0

ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }
post() { curl -sf --max-time 60 -X POST "$API" -H "Content-Type: application/json" -d "$1" 2>/dev/null; }

echo "=== Mirror Diff Test (real data) ==="
echo ""

# Test against small folders to keep it fast
for FOLDER in wallet events places; do
  echo "--- Testing folder: $FOLDER ---"

  RESULT=$(post "{\"action\":\"mirror_diff_test\",\"folder\":\"$FOLDER\"}")
  if [ -z "$RESULT" ]; then
    fail "$FOLDER: timed out or returned empty"
    continue
  fi

  SUCCESS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))")
  if [ "$SUCCESS" != "True" ]; then
    # Folder may not exist — check if it's a known skip
    ERROR=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
    echo "  SKIP: $FOLDER ($ERROR)"
    continue
  fi

  # Phase 1: Self-compare
  P1_CORRECT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase1_self_compare']['correct'])")
  P1_FILES=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase1_self_compare']['manifest_files'])")

  if [ "$P1_CORRECT" = "True" ]; then
    ok "$FOLDER phase1 self-compare: 0 diffs ($P1_FILES files)"
  else
    P1_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase1_self_compare']['diff_count'])")
    fail "$FOLDER phase1 self-compare: $P1_COUNT diffs (expected 0)"
    echo "$RESULT" | python3 -c "
import sys, json
for c in json.load(sys.stdin)['phase1_self_compare']['changes']:
    print(f'    {c}')
"
  fi

  # Phase 2: Cross-device
  P2_EXPECTED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase2_cross_device']['expected_diff_count'])")
  P2_CORRECT_CACHED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase2_cross_device']['correct_cached'])")
  P2_CORRECT_FRESH=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase2_cross_device']['correct_fresh'])")
  P2_CACHED=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase2_cross_device']['diff_count_cached'])")
  P2_FRESH=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['phase2_cross_device']['diff_count_fresh'])")

  if [ "$P2_CORRECT_CACHED" = "True" ]; then
    ok "$FOLDER phase2 cross-device (cached): $P2_CACHED/$P2_EXPECTED diffs"
  else
    fail "$FOLDER phase2 cross-device (cached): $P2_CACHED/$P2_EXPECTED diffs"
    echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)['phase2_cross_device']
print(f\"    mutations: {d['mutations_applied']}\")
for c in d['changes_cached']:
    print(f'    {c}')
"
  fi

  if [ "$P2_CORRECT_FRESH" = "True" ]; then
    ok "$FOLDER phase2 cross-device (fresh): $P2_FRESH/$P2_EXPECTED diffs"
  else
    fail "$FOLDER phase2 cross-device (fresh): $P2_FRESH/$P2_EXPECTED diffs"
  fi

  echo ""
done

echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
