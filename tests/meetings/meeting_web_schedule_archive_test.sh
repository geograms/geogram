#!/bin/bash
# Regression test: scheduled Meetings pages stay reachable before start and
# become read-only archives after the meeting ends.

set -euo pipefail

API="http://127.0.0.1:3456/api/debug"
WEB_ROOT="http://127.0.0.1:3456/meet"

post() {
  curl -sf -X POST "$API" -H "Content-Type: application/json" -d "$1"
}

get_text() {
  curl -sf "$1"
}

json_field() {
  local expression="$1"
  python3 -c "import json, sys; data=json.load(sys.stdin); print($expression)"
}

fail() {
  echo "FAIL: $1"
  exit 1
}

ok() {
  echo "PASS: $1"
}

cleanup() {
  post '{"action":"conference_end"}' >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "=== Meetings Web Schedule/Archive Test ==="
echo ""

post '{"action":"conference_end"}' >/dev/null 2>&1 || true

SCHEDULE_RESPONSE="$(post '{"action":"conference_schedule","room_name":"Web Archive Regression","max_speakers":4}')"
ROOM_ID="$(echo "$SCHEDULE_RESPONSE" | json_field "data['schedule']['room_id']")"
ROOM_CODE="${ROOM_ID%%@*}"

if [ -z "$ROOM_CODE" ]; then
  fail "scheduled meeting did not return a room code"
fi
ok "scheduled meeting created with room code $ROOM_CODE"

STATE_JSON="$(get_text "$WEB_ROOT/$ROOM_CODE/state.json")"
if ! echo "$STATE_JSON" | json_field "data['state']" | grep -qx "scheduled"; then
  fail "scheduled meeting state.json did not report scheduled"
fi
ok "scheduled meeting state.json reports scheduled"

SCHEDULE_PAGE="$(get_text "$WEB_ROOT/$ROOM_CODE")"
if ! rg -q "Meeting scheduled" <<<"$SCHEDULE_PAGE"; then
  fail "scheduled meeting page did not render scheduled state"
fi
if ! rg -q "Web Archive Regression" <<<"$SCHEDULE_PAGE"; then
  fail "scheduled meeting page did not include the meeting title"
fi
ok "scheduled meeting page renders the title and scheduled state"

START_RESPONSE="$(post "{\"action\":\"conference_start_scheduled\",\"room_id\":\"$ROOM_ID\"}")"
if ! echo "$START_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  fail "scheduled meeting did not start"
fi
ok "scheduled meeting started"

ACTIVE_STATE="$(get_text "$WEB_ROOT/$ROOM_CODE/state.json")"
if ! echo "$ACTIVE_STATE" | json_field "data['state']" | grep -qx "active"; then
  fail "started meeting state.json did not report active"
fi
ok "started meeting state.json reports active"

post '{"action":"conference_send_chat","content":"Archive regression message"}' >/dev/null
ok "chat message posted during the meeting"

END_RESPONSE="$(post '{"action":"conference_end"}')"
if ! echo "$END_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  fail "conference_end failed"
fi
ok "meeting ended"

ARCHIVE_STATE="$(get_text "$WEB_ROOT/$ROOM_CODE/state.json")"
if ! echo "$ARCHIVE_STATE" | json_field "data['state']" | grep -qx "archive"; then
  fail "ended meeting state.json did not report archive"
fi
if ! echo "$ARCHIVE_STATE" | json_field "data['message_count']" | grep -qx "1"; then
  fail "archive state did not persist the chat transcript"
fi
ok "ended meeting state.json reports archive with persisted chat"

ARCHIVE_PAGE="$(get_text "$WEB_ROOT/$ROOM_CODE")"
if ! rg -q "Meeting archive" <<<"$ARCHIVE_PAGE"; then
  fail "archive meeting page did not render archive state"
fi
if ! rg -q "Archive regression message" <<<"$ARCHIVE_PAGE"; then
  fail "archive meeting page did not include the persisted chat content"
fi
ok "archive meeting page renders persisted chat in read-only mode"

SCHEDULES="$(post '{"action":"conference_list_schedules"}')"
if ! echo "$SCHEDULES" | json_field "any(item['room_id'] == '$ROOM_ID' and item['status'] == 'completed' for item in data['schedules'])" | grep -qx "True"; then
  fail "completed meeting schedule entry was not persisted"
fi
ok "scheduled meeting metadata persisted as completed"

echo ""
echo "meeting_web_schedule_archive_test.sh: OK"
