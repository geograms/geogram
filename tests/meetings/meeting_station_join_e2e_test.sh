#!/bin/bash
# End-to-end test: host a station-relayed meeting from one temporary client and
# verify a second temporary client can join through the local station server.
#
# Prerequisites: the main desktop app must already be running via
# ./launch-desktop.sh on port 3456.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MAIN_PORT=3456
MAIN_API="http://localhost:${MAIN_PORT}/api/debug"
VISITOR_BIN="${ROOT_DIR}/build/linux/x64/debug/bundle/geogram"

PASS=0
FAIL=0
TOTAL=0

HOST_PID=""
HOST_TMPDIR=""
HOST_PORT=""
HOST_API=""
HOST_STATUS_URL=""
HOST_CALLSIGN=""

GUEST_PID=""
GUEST_TMPDIR=""
GUEST_PORT=""
GUEST_API=""
GUEST_STATUS_URL=""
GUEST_CALLSIGN=""

ROOM_ID=""
STATION_PORT=""

ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }

post() {
  curl -sf -X POST "$1" -H "Content-Type: application/json" -d "$2" 2>/dev/null
}

get_json() {
  curl -sf "$1" 2>/dev/null
}

json_field() {
  local expression="$1"
  python3 -c "import json, sys; data=json.load(sys.stdin); print($expression)"
}

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
}

start_temp_client() {
  local nickname="$1"
  local port_var="$2"
  local dir_var="$3"
  local pid_var="$4"
  local api_var="$5"
  local status_var="$6"

  local port
  port="$(free_port)"
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/geogram-meeting-station.XXXXXX")"
  cat > "${tmpdir}/config.json" <<'JSON'
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
    --port="$port" \
    --data-dir="$tmpdir" \
    --test-mode \
    --nickname="$nickname" \
    --no-update \
    >"${tmpdir}/client.log" 2>&1 &
  local pid=$!
  local status_url="http://localhost:${port}/api/status"

  for _ in $(seq 1 90); do
    if get_json "$status_url" >/dev/null; then
      local api_url="http://localhost:${port}/api/debug"
      for _ in $(seq 1 90); do
        if post "$api_url" '{"action":"conference_status"}' >/dev/null; then
          printf -v "$port_var" '%s' "$port"
          printf -v "$dir_var" '%s' "$tmpdir"
          printf -v "$pid_var" '%s' "$pid"
          printf -v "$api_var" '%s' "$api_url"
          printf -v "$status_var" '%s' "$status_url"
          return 0
        fi
        sleep 1
      done
      echo "FATAL: ${nickname} debug API did not become ready"
      tail -n 100 "${tmpdir}/client.log" || true
      exit 1
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "FATAL: ${nickname} client exited early"
      tail -n 100 "${tmpdir}/client.log" || true
      exit 1
    fi
    sleep 1
  done

  echo "FATAL: ${nickname} client did not start"
  tail -n 100 "${tmpdir}/client.log" || true
  exit 1
}

cleanup() {
  for api in "$HOST_API" "$GUEST_API"; do
    if [ -n "$api" ]; then
      post "$api" '{"action":"conference_end"}' >/dev/null || true
    fi
  done
  post "$MAIN_API" '{"action":"station_server_stop"}' >/dev/null || true

  for pid in "$HOST_PID" "$GUEST_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done

  for dir in "$HOST_TMPDIR" "$GUEST_TMPDIR"; do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      rm -rf "$dir"
    fi
  done
}

trap cleanup EXIT

echo "=== Meetings Station Join E2E Test ==="
echo ""

echo "[0] Checking main debug API and desktop bundle..."
if ! post "$MAIN_API" '{"action":"conference_status"}' >/dev/null; then
  echo "FATAL: debug API not reachable on $MAIN_API"
  echo "       Is the desktop app running? (./launch-desktop.sh)"
  exit 1
fi
if [ ! -x "$VISITOR_BIN" ]; then
  echo "FATAL: temporary client desktop bundle not found at $VISITOR_BIN"
  echo "       Run ./launch-desktop.sh once so the Linux desktop bundle is built."
  exit 1
fi
ok "main debug API reachable and temp client bundle exists"

echo ""
echo "[1] Starting the local station server..."
post "$MAIN_API" '{"action":"station_server_stop"}' >/dev/null || true
STATION_START="$(post "$MAIN_API" '{"action":"station_server_start"}')"
STATION_PORT="$(echo "$STATION_START" | json_field "data['port']")"
STATION_STATUS="$(post "$MAIN_API" '{"action":"station_server_status"}')"
if echo "$STATION_STATUS" | json_field "data['running']" | grep -qx "True"; then
  ok "local station server started on port $STATION_PORT"
else
  fail "local station server did not start"
  echo "$STATION_STATUS"
fi

echo ""
echo "[2] Launching isolated host and guest clients..."
start_temp_client "StationHost" HOST_PORT HOST_TMPDIR HOST_PID HOST_API HOST_STATUS_URL
start_temp_client "StationGuest" GUEST_PORT GUEST_TMPDIR GUEST_PID GUEST_API GUEST_STATUS_URL
HOST_CALLSIGN="$(get_json "$HOST_STATUS_URL" | json_field "data['callsign']")"
GUEST_CALLSIGN="$(get_json "$GUEST_STATUS_URL" | json_field "data['callsign']")"
echo "  host_callsign=$HOST_CALLSIGN"
echo "  guest_callsign=$GUEST_CALLSIGN"
ok "temporary host and guest clients started"

echo ""
echo "[3] Connecting both clients to the local station server..."
STATION_WS_URL="ws://127.0.0.1:${STATION_PORT}"
for api in "$HOST_API" "$GUEST_API"; do
  post "$api" "{\"action\":\"station_connect\",\"url\":\"${STATION_WS_URL}\"}" >/dev/null
done

CONNECTED=0
for _ in $(seq 1 30); do
  HOST_STATION_STATUS="$(post "$HOST_API" '{"action":"station_status"}')"
  GUEST_STATION_STATUS="$(post "$GUEST_API" '{"action":"station_status"}')"
  if HOST_STATION_STATUS="$HOST_STATION_STATUS" GUEST_STATION_STATUS="$GUEST_STATION_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATION_STATUS'])
guest = json.loads(os.environ['GUEST_STATION_STATUS'])
if host.get('connected') and guest.get('connected'):
    sys.exit(0)
sys.exit(1)
PY
  then
    CONNECTED=1
    break
  fi
  sleep 1
done

if [ "$CONNECTED" -eq 1 ]; then
  ok "both temporary clients connected to the local station server"
else
  fail "temporary clients never connected to the local station server"
  echo "Host station status: $HOST_STATION_STATUS"
  echo "Guest station status: $GUEST_STATION_STATUS"
fi

echo ""
echo "[4] Hosting a station-relayed meeting from the temporary host..."
HOST_RESPONSE="$(post "$HOST_API" '{"action":"conference_host","room_name":"Station Regression Meeting","max_speakers":4}')"
ROOM_ID="$(echo "$HOST_RESPONSE" | json_field "data['room']['room_id']")"
HOST_MODE="$(echo "$HOST_RESPONSE" | json_field "data['room']['signaling_mode']")"
if [ "$HOST_MODE" = "station" ]; then
  ok "temporary host created a station-mode meeting"
else
  fail "temporary host used $HOST_MODE mode instead of station"
  echo "$HOST_RESPONSE"
fi

echo ""
echo "[5] Joining the room from the temporary guest through the station relay..."
JOIN_RESPONSE="$(post "$GUEST_API" "{\"action\":\"conference_join\",\"room_id\":\"${ROOM_ID}\",\"role\":\"listener\"}")"
if echo "$JOIN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "temporary guest accepted the station join request"
else
  fail "temporary guest rejected the station join request"
  echo "$JOIN_RESPONSE"
fi

echo ""
echo "[6] Waiting for both station participants to appear..."
JOINED=0
HOST_STATUS=""
GUEST_STATUS=""
for _ in $(seq 1 45); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  GUEST_STATUS="$(post "$GUEST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" \
     GUEST_STATUS="$GUEST_STATUS" \
     HOST_CALLSIGN="$HOST_CALLSIGN" \
     GUEST_CALLSIGN="$GUEST_CALLSIGN" \
     ROOM_ID="$ROOM_ID" \
     python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
guest = json.loads(os.environ['GUEST_STATUS'])
room_id = os.environ['ROOM_ID']
expected = sorted([os.environ['HOST_CALLSIGN'], os.environ['GUEST_CALLSIGN']])

def room_participants(payload):
    room = payload.get('room') or {}
    return sorted(p['callsign'] for p in room.get('participants') or [])

def participant_map(payload):
    room = payload.get('room') or {}
    return {p['callsign']: p for p in room.get('participants') or []}

if host.get('state') != 'active' or host.get('role') != 'host':
    sys.exit(1)
if guest.get('state') != 'active' or guest.get('role') != 'joiner':
    sys.exit(1)
if (host.get('room') or {}).get('room_id') != room_id:
    sys.exit(1)
if (guest.get('room') or {}).get('room_id') != room_id:
    sys.exit(1)
if (host.get('room') or {}).get('participant_count') != 2:
    sys.exit(1)
if (guest.get('room') or {}).get('participant_count') != 2:
    sys.exit(1)
if room_participants(host) != expected:
    sys.exit(1)
if room_participants(guest) != expected:
    sys.exit(1)
host_participants = participant_map(host)
guest_participants = participant_map(guest)
if not host_participants.get(os.environ['GUEST_CALLSIGN'], {}).get('is_connected'):
    sys.exit(1)
if not guest_participants.get(os.environ['HOST_CALLSIGN'], {}).get('is_connected'):
    sys.exit(1)
if guest.get('remote_audio_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    JOINED=1
    break
  fi
  sleep 1
done

if [ "$JOINED" -eq 1 ]; then
  ok "station host and guest agree on the two meeting participants"
else
  fail "station meeting never converged to two shared participants"
  echo "Host status: $HOST_STATUS"
  echo "Guest status: $GUEST_STATUS"
fi

echo ""
echo "[7] Requesting speaker access from the guest..."
REQUEST_RESPONSE="$(post "$GUEST_API" '{"action":"conference_request_speaker"}')"
if echo "$REQUEST_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "guest requested speaker access"
else
  fail "guest could not request speaker access"
  echo "$REQUEST_RESPONSE"
fi

echo ""
echo "[8] Waiting for the host to see the guest speaker request..."
REQUESTED=0
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" GUEST_CALLSIGN="$GUEST_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
pending = host.get('pending_speaker_requests') or []
if os.environ['GUEST_CALLSIGN'] in pending:
    sys.exit(0)
sys.exit(1)
PY
  then
    REQUESTED=1
    break
  fi
  sleep 1
done

if [ "$REQUESTED" -eq 1 ]; then
  ok "host received the guest speaker request"
else
  fail "host never saw the guest speaker request"
  echo "$HOST_STATUS"
fi

echo ""
echo "[9] Promoting the guest to speaker..."
PROMOTE_RESPONSE="$(post "$HOST_API" "{\"action\":\"conference_promote\",\"callsign\":\"${GUEST_CALLSIGN}\"}")"
if echo "$PROMOTE_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "host promoted the guest to speaker"
else
  fail "host could not promote the guest"
  echo "$PROMOTE_RESPONSE"
fi

echo ""
echo "[10] Waiting for both sides to reflect the new speaker role..."
PROMOTED=0
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  GUEST_STATUS="$(post "$GUEST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" GUEST_STATUS="$GUEST_STATUS" GUEST_CALLSIGN="$GUEST_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
guest = json.loads(os.environ['GUEST_STATUS'])
target = os.environ['GUEST_CALLSIGN']

def participant(payload, callsign):
    room = payload.get('room') or {}
    for entry in room.get('participants') or []:
        if entry.get('callsign') == callsign:
            return entry
    return {}

host_target = participant(host, target)
guest_self = participant(guest, target)
if host_target.get('role') != 'speaker':
    sys.exit(1)
if guest_self.get('role') != 'speaker':
    sys.exit(1)
if host_target.get('speaker_request_pending'):
    sys.exit(1)
if guest_self.get('speaker_request_pending'):
    sys.exit(1)
if host.get('remote_audio_stream_count', 0) < 1:
    sys.exit(1)
if guest.get('remote_audio_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    PROMOTED=1
    break
  fi
  sleep 1
done

if [ "$PROMOTED" -eq 1 ]; then
  ok "host and guest both show the guest as a speaker"
else
  fail "guest promotion did not propagate"
  echo "Host status: $HOST_STATUS"
  echo "Guest status: $GUEST_STATUS"
fi

echo ""
echo "[11] Sending a meeting chat message from the guest..."
CHAT_TEXT="Station regression chat"
CHAT_RESPONSE="$(post "$GUEST_API" "{\"action\":\"conference_send_chat\",\"content\":\"${CHAT_TEXT}\"}")"
if echo "$CHAT_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "guest sent a meeting chat message"
else
  fail "guest could not send a meeting chat message"
  echo "$CHAT_RESPONSE"
fi

echo ""
echo "[12] Waiting for the host transcript to persist the chat message..."
CHAT_SYNCED=0
TRANSCRIPT_PATH=""
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  TRANSCRIPT_PATH="$(echo "$HOST_STATUS" | json_field "data.get('chat_transcript_path')")"
  if HOST_STATUS="$HOST_STATUS" CHAT_TEXT="$CHAT_TEXT" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
messages = host.get('chat_messages') or []
if any(m.get('content') == os.environ['CHAT_TEXT'] for m in messages):
    sys.exit(0)
sys.exit(1)
PY
  then
    if [ -n "$TRANSCRIPT_PATH" ] && [ "$TRANSCRIPT_PATH" != "None" ] && grep -Fq "$CHAT_TEXT" "$TRANSCRIPT_PATH"; then
      CHAT_SYNCED=1
      break
    fi
  fi
  sleep 1
done

if [ "$CHAT_SYNCED" -eq 1 ]; then
  ok "meeting chat reached the host status API and persisted transcript"
else
  fail "meeting chat did not persist on the host"
  echo "Host status: $HOST_STATUS"
  echo "Transcript path: $TRANSCRIPT_PATH"
fi

echo ""
echo "[13] Starting direct screen sharing from the host..."
HOST_SCREEN_RESPONSE="$(post "$HOST_API" '{"action":"conference_start_screen_share"}')"
if echo "$HOST_SCREEN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "host started a direct screen share"
else
  fail "host could not start a direct screen share"
  echo "$HOST_SCREEN_RESPONSE"
fi

echo ""
echo "[14] Waiting for the guest to receive the host screen share..."
HOST_SCREEN_ACTIVE=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  GUEST_STATUS="$(post "$GUEST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" GUEST_STATUS="$GUEST_STATUS" HOST_CALLSIGN="$HOST_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
guest = json.loads(os.environ['GUEST_STATUS'])
host_callsign = os.environ['HOST_CALLSIGN']
if host.get('active_screen_sharer') != host_callsign:
    sys.exit(1)
if guest.get('active_screen_sharer') != host_callsign:
    sys.exit(1)
if not host.get('local_screen_sharing'):
    sys.exit(1)
if guest.get('remote_screen_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    HOST_SCREEN_ACTIVE=1
    break
  fi
  sleep 1
done

if [ "$HOST_SCREEN_ACTIVE" -eq 1 ]; then
  ok "guest received the host screen share"
else
  fail "host screen share did not propagate"
  echo "Host status: $HOST_STATUS"
  echo "Guest status: $GUEST_STATUS"
fi

echo ""
echo "[15] Stopping the host screen share and waiting for cleanup..."
post "$HOST_API" '{"action":"conference_stop_screen_share"}' >/dev/null || true
HOST_SCREEN_STOPPED=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  GUEST_STATUS="$(post "$GUEST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" GUEST_STATUS="$GUEST_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
guest = json.loads(os.environ['GUEST_STATUS'])
if host.get('active_screen_sharer') is not None:
    sys.exit(1)
if guest.get('active_screen_sharer') is not None:
    sys.exit(1)
if host.get('local_screen_sharing'):
    sys.exit(1)
if guest.get('remote_screen_stream_count', 0) != 0:
    sys.exit(1)
PY
  then
    HOST_SCREEN_STOPPED=1
    break
  fi
  sleep 1
done

if [ "$HOST_SCREEN_STOPPED" -eq 1 ]; then
  ok "host screen share stopped cleanly"
else
  fail "host screen share did not stop cleanly"
  echo "Host status: $HOST_STATUS"
  echo "Guest status: $GUEST_STATUS"
fi

echo ""
echo "[16] Requesting guest screen share access and approving it..."
REQUEST_SCREEN_RESPONSE="$(post "$GUEST_API" '{"action":"conference_request_screen_share"}')"
if echo "$REQUEST_SCREEN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "guest requested screen-share access"
else
  fail "guest could not request screen-share access"
  echo "$REQUEST_SCREEN_RESPONSE"
fi

SCREEN_REQUESTED=0
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" GUEST_CALLSIGN="$GUEST_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
pending = host.get('pending_screen_share_requests') or []
if os.environ['GUEST_CALLSIGN'] in pending:
    sys.exit(0)
sys.exit(1)
PY
  then
    SCREEN_REQUESTED=1
    break
  fi
  sleep 1
done

if [ "$SCREEN_REQUESTED" -eq 1 ]; then
  ok "host received the guest screen-share request"
else
  fail "host never saw the guest screen-share request"
  echo "$HOST_STATUS"
fi

APPROVE_SCREEN_RESPONSE="$(post "$HOST_API" "{\"action\":\"conference_approve_screen_share\",\"callsign\":\"${GUEST_CALLSIGN}\"}")"
if echo "$APPROVE_SCREEN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "host approved guest screen sharing"
else
  fail "host could not approve guest screen sharing"
  echo "$APPROVE_SCREEN_RESPONSE"
fi

echo ""
echo "[17] Waiting for the guest screen share to reach the host..."
GUEST_SCREEN_ACTIVE=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  GUEST_STATUS="$(post "$GUEST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" GUEST_STATUS="$GUEST_STATUS" GUEST_CALLSIGN="$GUEST_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
guest = json.loads(os.environ['GUEST_STATUS'])
callsign = os.environ['GUEST_CALLSIGN']
if host.get('active_screen_sharer') != callsign:
    sys.exit(1)
if guest.get('active_screen_sharer') != callsign:
    sys.exit(1)
if not guest.get('local_screen_sharing'):
    sys.exit(1)
if host.get('remote_screen_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    GUEST_SCREEN_ACTIVE=1
    break
  fi
  sleep 1
done

if [ "$GUEST_SCREEN_ACTIVE" -eq 1 ]; then
  ok "host received the guest screen share"
else
  fail "guest screen share did not propagate"
  echo "Host status: $HOST_STATUS"
  echo "Guest status: $GUEST_STATUS"
fi

echo ""
echo "[18] Stopping the guest screen share and waiting for cleanup..."
post "$GUEST_API" '{"action":"conference_stop_screen_share"}' >/dev/null || true
GUEST_SCREEN_STOPPED=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
  GUEST_STATUS="$(post "$GUEST_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" GUEST_STATUS="$GUEST_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
guest = json.loads(os.environ['GUEST_STATUS'])
if host.get('active_screen_sharer') is not None:
    sys.exit(1)
if guest.get('active_screen_sharer') is not None:
    sys.exit(1)
if host.get('remote_screen_stream_count', 0) != 0:
    sys.exit(1)
if guest.get('local_screen_sharing'):
    sys.exit(1)
PY
  then
    GUEST_SCREEN_STOPPED=1
    break
  fi
  sleep 1
done

if [ "$GUEST_SCREEN_STOPPED" -eq 1 ]; then
  ok "guest screen share stopped cleanly"
else
  fail "guest screen share did not stop cleanly"
  echo "Host status: $HOST_STATUS"
  echo "Guest status: $GUEST_STATUS"
fi

echo ""
echo "[19] Verifying the local station server saw both clients..."
STATION_STATUS="$(post "$MAIN_API" '{"action":"station_server_status"}')"
if STATION_STATUS="$STATION_STATUS" python3 - <<'PY'
import json
import os
import sys

status = json.loads(os.environ['STATION_STATUS'])
if not status.get('running'):
    sys.exit(1)
if (status.get('connected_devices') or 0) < 2:
    sys.exit(1)
PY
then
  ok "local station server reports at least two connected devices"
else
  fail "local station server did not report both connected devices"
  echo "$STATION_STATUS"
fi

echo ""
echo "[20] Ending the meeting and stopping the local station server..."
post "$HOST_API" '{"action":"conference_end"}' >/dev/null || true
post "$GUEST_API" '{"action":"conference_end"}' >/dev/null || true
post "$MAIN_API" '{"action":"station_server_stop"}' >/dev/null || true
sleep 2
HOST_STATUS="$(post "$HOST_API" '{"action":"conference_status"}')"
GUEST_STATUS="$(post "$GUEST_API" '{"action":"conference_status"}')"
STATION_STATUS="$(post "$MAIN_API" '{"action":"station_server_status"}')"
if HOST_STATUS="$HOST_STATUS" GUEST_STATUS="$GUEST_STATUS" STATION_STATUS="$STATION_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
guest = json.loads(os.environ['GUEST_STATUS'])
station = json.loads(os.environ['STATION_STATUS'])
if host.get('state') != 'idle':
    sys.exit(1)
if guest.get('state') != 'idle':
    sys.exit(1)
if station.get('running'):
    sys.exit(1)
PY
then
  ok "both conference services are idle and the local station server stopped"
else
  fail "station meeting cleanup did not complete"
  echo "Host status: $HOST_STATUS"
  echo "Guest status: $GUEST_STATUS"
  echo "Station status: $STATION_STATUS"
fi

echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
