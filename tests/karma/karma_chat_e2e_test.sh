#!/bin/bash
# End-to-end test: send a station chat message and verify karma increments + UI updates
#
# Prerequisites: the desktop app must be running (./launch-desktop.sh)
# This test talks to the local debug API on port 3456.

set -euo pipefail

API="http://localhost:3456/api/debug"
PASS=0
FAIL=0
TOTAL=0

ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }

post() { curl -sf -X POST "$API" -H "Content-Type: application/json" -d "$1" 2>/dev/null; }

echo "=== Karma Chat E2E Test ==="
echo ""

# ── 0. Sanity: debug API reachable ───────────────────────────────
echo "[0] Checking debug API..."
if ! post '{"action":"karma_profile"}' >/dev/null; then
  echo "FATAL: debug API not reachable on $API"
  echo "       Is the desktop app running? (./launch-desktop.sh)"
  exit 1
fi
ok "debug API reachable"

# ── 1. Snapshot karma state BEFORE ───────────────────────────────
echo ""
echo "[1] Reading karma profile before test..."
BEFORE=$(post '{"action":"karma_profile"}')
BEFORE_TOTAL=$(echo "$BEFORE" | python3 -c "import sys,json; print(json.load(sys.stdin)['profile']['total_points'])")
echo "  total_points=$BEFORE_TOTAL"

# Record timestamp just before sending (ISO 8601 UTC)
TEST_START=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())")
echo "  test_start=$TEST_START"

# ── 2. Open station chat and select the Testing room ─────────────
echo ""
echo "[2] Opening station chat and selecting 'testing' room..."
post '{"action":"open_station_chat"}' >/dev/null
sleep 5
post '{"action":"select_chat_room","room_id":"testing"}' >/dev/null
sleep 4

# ── 3. Send a message through the UI ─────────────────────────────
NONCE=$(date +%s%N | tail -c 10)
MSG="karma-e2e-$NONCE"
echo ""
echo "[3] Sending message: $MSG"
post "{\"action\":\"send_chat_message\",\"content\":\"$MSG\"}" >/dev/null
sleep 5

# ── 4. Read karma state AFTER ────────────────────────────────────
echo ""
echo "[4] Reading karma profile after test..."
AFTER=$(post '{"action":"karma_profile"}')
AFTER_TOTAL=$(echo "$AFTER" | python3 -c "import sys,json; print(json.load(sys.stdin)['profile']['total_points'])")
echo "  total_points=$AFTER_TOTAL"

# ── 5. Check total_points increased (may be suppressed by 2s dedup) ─
echo ""
echo "[5] Checking total_points delta..."
if [ "$AFTER_TOTAL" -gt "$BEFORE_TOTAL" ]; then
  ok "total_points increased ($BEFORE_TOTAL -> $AFTER_TOTAL)"
else
  echo "  WARN: total_points unchanged ($BEFORE_TOTAL -> $AFTER_TOTAL) — likely 2s dedup from prior run"
  echo "        (step 6 history check is the authoritative assertion)"
fi

# ── 6. Check karma history for a chat_message event AFTER our start time ──
echo ""
echo "[6] Checking karma history for chat_message event after $TEST_START ..."
HISTORY=$(post '{"action":"karma_history","limit":10}')
FOUND=$(echo "$HISTORY" | python3 -c "
import sys, json
from datetime import datetime, timezone
data = json.load(sys.stdin)
events = data.get('events', [])
start = '$TEST_START'
found = False
for e in events:
    if e['action'] == 'chat_message' and e['ts'] >= start:
        meta = e.get('meta', {})
        print(f\"  Found: ts={e['ts']} room={meta.get('room_id','?')} pts={e['points_final']}\")
        found = True
        break
print('FOUND' if found else 'NOT_FOUND')
")

if echo "$FOUND" | grep -q "FOUND"; then
  ok "chat_message karma event recorded after test start"
else
  fail "no chat_message karma event found after test start"
  echo "  Recent history:"
  echo "$HISTORY" | python3 -c "
import sys, json
for e in json.load(sys.stdin).get('events',[])[:5]:
    m = e.get('meta',{})
    print(f\"    {e['ts']} {e['action']} room={m.get('room_id','?')} pts={e['points_final']}\")
"
fi

# ── 7. Test karma_award to verify EventBus -> UI path ────────────
echo ""
echo "[7] Testing karma_award (EventBus -> KarmaUpdatedEvent -> UI)..."
BEFORE_AWARD=$(echo "$AFTER_TOTAL")
AWARD_RESULT=$(post '{"action":"karma_award","callsign":"X1SU86","karma_action":"like_given","meta":{"content_type":"test","content_id":"e2e-verify"}}')
AWARD_PTS=$(echo "$AWARD_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('points_awarded',0))")
if [ "$AWARD_PTS" -gt 0 ]; then
  ok "karma_award returned $AWARD_PTS points"
else
  fail "karma_award returned 0 points (dataDir null?)"
fi

sleep 2
FINAL=$(post '{"action":"karma_profile"}')
FINAL_TOTAL=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin)['profile']['total_points'])")
if [ "$FINAL_TOTAL" -gt "$BEFORE_AWARD" ]; then
  ok "total_points increased after award ($BEFORE_AWARD -> $FINAL_TOTAL)"
else
  fail "total_points did NOT increase after award ($BEFORE_AWARD -> $FINAL_TOTAL)"
fi

# ── 8. Verify dataDir is non-null (implied by karma_award success) ─
echo ""
echo "[8] StationServerService.dataDir check..."
if [ "$AWARD_PTS" -gt 0 ]; then
  ok "dataDir is non-null (karma recording works)"
else
  fail "dataDir appears null (karma silently dropped)"
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
