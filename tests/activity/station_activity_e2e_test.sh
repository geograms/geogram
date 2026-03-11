#!/bin/bash
# End-to-end test: create public content and verify it appears in the station
# activity feed served by the local station server.

set -euo pipefail

API="http://localhost:3456/api/debug"
PASS=0
FAIL=0
TOTAL=0

ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }

post() { curl -sf -X POST "$API" -H "Content-Type: application/json" -d "$1" 2>/dev/null; }

json_field() {
  local expr="$1"
  python3 -c "import sys,json; data=json.load(sys.stdin); print($expr)"
}

post_expect_success() {
  local payload="$1"
  local response success

  response=$(post "$payload")
  success=$(echo "$response" | json_field "str(data.get('success', False)).lower()")
  if [ "$success" != "true" ]; then
    echo "  Request failed for payload: $payload"
    echo "$response"
    return 1
  fi

  printf '%s' "$response"
}

wait_for_station_connected() {
  local attempts=20
  local status_json connected
  for _ in $(seq 1 "$attempts"); do
    status_json=$(post '{"action":"station_status"}')
    connected=$(echo "$status_json" | json_field "str(data.get('connected', False)).lower()")
    if [ "$connected" = "true" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_feed_item() {
  local station_http="$1"
  local app_type="$2"
  local needle="$3"
  local attempts=30
  local feed_json=""

  for _ in $(seq 1 "$attempts"); do
    feed_json=$(curl -sf "$station_http/api/activity?limit=100" 2>/dev/null || true)
    if [ -n "$feed_json" ] && FEED_JSON="$feed_json" python3 - "$app_type" "$needle" <<'PY'
import json
import os
import sys

app_type = sys.argv[1]
needle = sys.argv[2]

data = json.loads(os.environ["FEED_JSON"])
for item in data.get("activities", []):
    haystack = " ".join([
        str(item.get("source_name", "")),
        str(item.get("summary", "")),
        str(item.get("action", "")),
    ])
    if item.get("app_type") == app_type and needle in haystack:
        sys.exit(0)
sys.exit(1)
PY
    then
      return 0
    fi
    sleep 1
  done

  echo "  Last feed payload:"
  if [ -n "$feed_json" ]; then
    echo "$feed_json" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), indent=2)[:4000])"
  else
    echo "  <empty>"
  fi
  return 1
}

echo "=== Station Activity E2E Test ==="
echo ""

echo "[0] Checking debug API..."
if ! post '{"action":"karma_profile"}' >/dev/null; then
  echo "FATAL: debug API not reachable on $API"
  echo "       Is the desktop app running? (./launch-desktop.sh)"
  exit 1
fi
ok "debug API reachable"

echo ""
echo "[1] Starting local station server..."
post '{"action":"station_server_stop"}' >/dev/null || true
START=$(post '{"action":"station_server_start"}')
SERVER_RUNNING=$(echo "$START" | json_field "str(data.get('running', False)).lower()")
SERVER_PORT=$(echo "$START" | json_field "data.get('port', '')")
if [ "$SERVER_RUNNING" = "true" ] && [ -n "$SERVER_PORT" ] && [ "$SERVER_PORT" != "None" ]; then
  ok "station server running on port $SERVER_PORT"
else
  fail "failed to start station server"
  echo "$START"
fi

STATION_WS="ws://127.0.0.1:$SERVER_PORT"
STATION_HTTP="http://127.0.0.1:$SERVER_PORT"

echo ""
echo "[2] Connecting desktop app to the local station..."
post "{\"action\":\"station_connect\",\"url\":\"$STATION_WS\",\"name\":\"Activity Test Station\"}" >/dev/null
if wait_for_station_connected; then
  ok "connected to preferred station $STATION_WS"
else
  fail "desktop app did not connect to preferred station"
fi

echo ""
echo "[3] Discovering a public chat room..."
ROOMS=$(curl -sf "$STATION_HTTP/api/chat/rooms")
ROOM_ID=$(echo "$ROOMS" | json_field "next((room.get('id') for room in data.get('rooms', []) if room.get('id')), '')")
if [ -n "$ROOM_ID" ]; then
  ok "found station chat room $ROOM_ID"
else
  fail "no station chat room available"
fi

NONCE=$(date +%s%N | tail -c 10)
BLOG_TITLE="activity-blog-$NONCE"
EVENT_TITLE="activity-event-$NONCE"
ALERT_TITLE="activity-alert-$NONCE"
CHAT_MESSAGE="activity-chat-$NONCE"

echo ""
echo "[4] Creating public content..."
post_expect_success "{\"action\":\"blog_create\",\"title\":\"$BLOG_TITLE\",\"content\":\"Blog content $NONCE\",\"status\":\"published\"}" >/dev/null
post_expect_success "{\"action\":\"event_create\",\"title\":\"$EVENT_TITLE\",\"content\":\"Event content $NONCE\",\"location\":\"online\",\"visibility\":\"public\"}" >/dev/null
post_expect_success "{\"action\":\"alert_create\",\"title\":\"$ALERT_TITLE\",\"description\":\"Alert description $NONCE\"}" >/dev/null
post_expect_success "{\"action\":\"chat_post_local\",\"room\":\"$ROOM_ID\",\"content\":\"$CHAT_MESSAGE\"}" >/dev/null
ok "content creation requests sent"

echo ""
echo "[5] Verifying activity feed entries..."
if wait_for_feed_item "$STATION_HTTP" "blog" "$BLOG_TITLE"; then
  ok "blog entry present in /api/activity"
else
  fail "blog entry missing from /api/activity"
fi

if wait_for_feed_item "$STATION_HTTP" "events" "$EVENT_TITLE"; then
  ok "event entry present in /api/activity"
else
  fail "event entry missing from /api/activity"
fi

if wait_for_feed_item "$STATION_HTTP" "alerts" "$ALERT_TITLE"; then
  ok "alert entry present in /api/activity"
else
  fail "alert entry missing from /api/activity"
fi

if wait_for_feed_item "$STATION_HTTP" "chat" "$CHAT_MESSAGE"; then
  ok "chat entry present in /api/activity"
else
  fail "chat entry missing from /api/activity"
fi

echo ""
echo "[6] Verifying feed metadata..."
FEED=$(curl -sf "$STATION_HTTP/api/activity?limit=100")
LATEST_INDEX=$(echo "$FEED" | json_field "data.get('latest_index', 0)")
COUNT=$(echo "$FEED" | json_field "data.get('count', 0)")
if [ "$LATEST_INDEX" -gt 0 ]; then
  ok "feed reports a latest_index ($LATEST_INDEX)"
else
  fail "feed latest_index is not greater than zero"
fi
if [ "$COUNT" -gt 0 ]; then
  ok "feed returned public activities ($COUNT)"
else
  fail "feed returned no activities"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
