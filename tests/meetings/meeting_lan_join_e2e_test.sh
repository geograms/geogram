#!/bin/bash
# End-to-end test: host a LAN meeting in one desktop instance and verify
# a second visitor can join the same room.
#
# Prerequisites: the main desktop app must already be running via
# ./launch-desktop.sh on port 3456.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MAIN_PORT=3456
MAIN_API="http://localhost:${MAIN_PORT}/api/debug"
MAIN_STATUS_URL="http://localhost:${MAIN_PORT}/api/status"
VISITOR_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
VISITOR_API="http://localhost:${VISITOR_PORT}/api/debug"
VISITOR_STATUS_URL="http://localhost:${VISITOR_PORT}/api/status"
VISITOR_BIN="${ROOT_DIR}/build/linux/x64/debug/bundle/geogram"

PASS=0
FAIL=0
TOTAL=0

VISITOR_PID=""
VISITOR_TMPDIR=""
HOST_CALLSIGN=""
ATTENDEE_CALLSIGN=""
ROOM_ID=""
SIGNALING_PORT=""

ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }

post() {
  curl -sf -X POST "$1" -H "Content-Type: application/json" -d "$2" 2>/dev/null
}

get_json() {
  curl -sf "$1" 2>/dev/null
}

cleanup() {
  post "$MAIN_API" '{"action":"conference_end"}' >/dev/null || true
  if [ -n "$VISITOR_PID" ]; then
    post "$VISITOR_API" '{"action":"conference_end"}' >/dev/null || true
    kill "$VISITOR_PID" >/dev/null 2>&1 || true
    wait "$VISITOR_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$VISITOR_TMPDIR" ] && [ -d "$VISITOR_TMPDIR" ]; then
    rm -rf "$VISITOR_TMPDIR"
  fi
}

trap cleanup EXIT

json_field() {
  local expression="$1"
  python3 -c "import json, sys; data=json.load(sys.stdin); print($expression)"
}

echo "=== Meetings LAN Join E2E Test ==="
echo ""

echo "[0] Checking main debug API and desktop bundle..."
if ! post "$MAIN_API" '{"action":"conference_status"}' >/dev/null; then
  echo "FATAL: debug API not reachable on $MAIN_API"
  echo "       Is the desktop app running? (./launch-desktop.sh)"
  exit 1
fi
if [ ! -x "$VISITOR_BIN" ]; then
  echo "FATAL: visitor desktop bundle not found at $VISITOR_BIN"
  echo "       Run ./launch-desktop.sh once so the Linux desktop bundle is built."
  exit 1
fi
ok "main debug API reachable and visitor bundle exists"

echo ""
echo "[1] Resetting any prior conference state..."
post "$MAIN_API" '{"action":"conference_end"}' >/dev/null || true
ok "main desktop conference reset"

echo ""
echo "[2] Launching isolated visitor desktop instance on port $VISITOR_PORT..."
VISITOR_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/geogram-meetings.XXXXXX")"
cat > "${VISITOR_TMPDIR}/config.json" <<'JSON'
{
  "version": "1.0.0",
  "created": "2026-03-11T00:00:00Z",
  "apps": {
    "favorites": []
  },
  "settings": {
    "theme": "system",
    "language": "en_US"
  },
  "stations": [],
  "firstLaunchComplete": true
}
JSON
DISPLAY="${DISPLAY:-}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
  "$VISITOR_BIN" \
  --port="$VISITOR_PORT" \
  --data-dir="$VISITOR_TMPDIR" \
  --test-mode \
  --nickname="Meeting Host" \
  --no-update \
  >"${VISITOR_TMPDIR}/visitor.log" 2>&1 &
VISITOR_PID=$!

for _ in $(seq 1 60); do
  if get_json "$VISITOR_STATUS_URL" >/dev/null; then
    break
  fi
  sleep 1
done
if ! get_json "$VISITOR_STATUS_URL" >/dev/null; then
  echo "FATAL: visitor debug API did not start on $VISITOR_STATUS_URL"
  echo "Visitor log:"
  tail -n 100 "${VISITOR_TMPDIR}/visitor.log" || true
  exit 1
fi
ok "visitor desktop instance started"

HOST_CALLSIGN="$(get_json "$VISITOR_STATUS_URL" | json_field "data['callsign']")"
ATTENDEE_CALLSIGN="$(get_json "$MAIN_STATUS_URL" | json_field "data['callsign']")"
echo "  host_callsign=$HOST_CALLSIGN"
echo "  attendee_callsign=$ATTENDEE_CALLSIGN"

echo ""
echo "[3] Hosting a LAN meeting from the isolated visitor instance..."
HOST_RESPONSE="$(post "$VISITOR_API" '{"action":"conference_host","room_name":"Regression Meeting","max_speakers":4}')"
ROOM_ID="$(echo "$HOST_RESPONSE" | json_field "data['room']['room_id']")"
HOST_MODE="$(echo "$HOST_RESPONSE" | json_field "data['room']['signaling_mode']")"
if [ "$HOST_MODE" = "lan" ]; then
  ok "visitor hosted meeting in LAN mode"
else
  fail "visitor meeting used $HOST_MODE mode instead of lan"
  echo "$HOST_RESPONSE"
fi

ACTIVE_RESPONSE="$(get_json "http://localhost:${VISITOR_PORT}/api/meet/active")"
SIGNALING_PORT="$(echo "$ACTIVE_RESPONSE" | json_field "data['signaling_port']")"
if [ "$SIGNALING_PORT" != "None" ] && [ "$SIGNALING_PORT" != "null" ]; then
  ok "host exposed a LAN signaling port ($SIGNALING_PORT)"
else
  fail "host did not expose a signaling port"
  echo "$ACTIVE_RESPONSE"
fi

echo ""
echo "[4] Joining the host meeting from the main desktop instance..."
JOIN_URL="ws://127.0.0.1:${SIGNALING_PORT}/meet/ws"
JOIN_RESPONSE="$(post "$MAIN_API" "{\"action\":\"conference_join\",\"url\":\"${JOIN_URL}\",\"role\":\"listener\"}")"
if echo "$JOIN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "main desktop accepted the join request"
else
  fail "main desktop rejected the join request"
  echo "$JOIN_RESPONSE"
fi

echo ""
echo "[5] Waiting for both conference participants to appear..."
JOINED=0
HOST_STATUS=""
ATTENDEE_STATUS=""
MEET_INFO=""
for _ in $(seq 1 45); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
  MEET_INFO="$(get_json "http://127.0.0.1:${SIGNALING_PORT}/meet/info")"
  if HOST_STATUS="$HOST_STATUS" \
     ATTENDEE_STATUS="$ATTENDEE_STATUS" \
     MEET_INFO="$MEET_INFO" \
     HOST_CALLSIGN="$HOST_CALLSIGN" \
     ATTENDEE_CALLSIGN="$ATTENDEE_CALLSIGN" \
     ROOM_ID="$ROOM_ID" \
     python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
meet = json.loads(os.environ['MEET_INFO'])
room_id = os.environ['ROOM_ID']
expected = sorted([os.environ['HOST_CALLSIGN'], os.environ['ATTENDEE_CALLSIGN']])

def room_participants(payload):
    room = payload.get('room') or {}
    return sorted(p['callsign'] for p in room.get('participants') or [])

if host.get('state') != 'active' or host.get('role') != 'host':
    sys.exit(1)
if attendee.get('state') != 'active' or attendee.get('role') != 'joiner':
    sys.exit(1)
if (host.get('room') or {}).get('room_id') != room_id:
    sys.exit(1)
if (attendee.get('room') or {}).get('room_id') != room_id:
    sys.exit(1)
if (host.get('room') or {}).get('participant_count') != 2:
    sys.exit(1)
if (attendee.get('room') or {}).get('participant_count') != 2:
    sys.exit(1)
if room_participants(host) != expected:
    sys.exit(1)
if room_participants(attendee) != expected:
    sys.exit(1)
if meet.get('room_id') != room_id:
    sys.exit(1)
if meet.get('participant_count') != 2:
    sys.exit(1)
if sorted(meet.get('participants') or []) != expected:
    sys.exit(1)
PY
  then
    JOINED=1
    break
  fi
  sleep 1
done

if [ "$JOINED" -eq 1 ]; then
  ok "host, attendee, and signaling server all report the same two participants"
else
  fail "meeting never converged to two shared participants"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
  echo "Meet info: $MEET_INFO"
fi

echo ""
echo "[6] Ending the meeting and checking cleanup..."
post "$MAIN_API" '{"action":"conference_end"}' >/dev/null || true
post "$VISITOR_API" '{"action":"conference_end"}' >/dev/null || true
sleep 2
HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
if HOST_STATUS="$HOST_STATUS" ATTENDEE_STATUS="$ATTENDEE_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
if host.get('state') != 'idle':
    sys.exit(1)
if attendee.get('state') != 'idle':
    sys.exit(1)
PY
then
  ok "both conference services returned to idle"
else
  fail "conference services did not return to idle"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
