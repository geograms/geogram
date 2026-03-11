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
CRASH_LOG="${HOME}/.local/share/geogram/logs/crash.txt"

PASS=0
FAIL=0
TOTAL=0

VISITOR_PID=""
VISITOR_TMPDIR=""
HOST_CALLSIGN=""
ATTENDEE_CALLSIGN=""
ROOM_ID=""
SIGNALING_PORT=""
CRASH_BASELINE_LINES=0

ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: $1"; }

post() {
  curl -sf -X POST "$1" -H "Content-Type: application/json" -d "$2" 2>/dev/null
}

get_json() {
  curl -sf "$1" 2>/dev/null
}

capture_crash_baseline() {
  if [ -f "$CRASH_LOG" ]; then
    CRASH_BASELINE_LINES="$(wc -l < "$CRASH_LOG")"
  else
    CRASH_BASELINE_LINES=0
  fi
}

check_webrtc_cleanup_logs() {
  local found=0
  local pattern='No active stream to cancel|MediaStreamDisposeFailed'

  if [ -f "$CRASH_LOG" ]; then
    local crash_excerpt=""
    if [ "$CRASH_BASELINE_LINES" -gt 0 ]; then
      crash_excerpt="$(sed -n "$((CRASH_BASELINE_LINES + 1)),\$p" "$CRASH_LOG")"
    else
      crash_excerpt="$(cat "$CRASH_LOG")"
    fi
    if printf '%s' "$crash_excerpt" | rg -n "$pattern" >/dev/null; then
      fail "main client crash log contains WebRTC teardown errors"
      printf '%s\n' "$crash_excerpt" | rg -n "$pattern" || true
      found=1
    else
      ok "main client crash log contains no WebRTC teardown errors"
    fi
  else
    ok "main client crash log contains no WebRTC teardown errors"
  fi

  if [ -n "$VISITOR_TMPDIR" ] && [ -f "${VISITOR_TMPDIR}/visitor.log" ]; then
    if rg -n "$pattern" "${VISITOR_TMPDIR}/visitor.log" >/dev/null; then
      fail "visitor client log contains WebRTC teardown errors"
      rg -n "$pattern" "${VISITOR_TMPDIR}/visitor.log" || true
      found=1
    else
      ok "visitor client log contains no WebRTC teardown errors"
    fi
  fi

  return "$found"
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
capture_crash_baseline
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
for _ in $(seq 1 60); do
  if post "$VISITOR_API" '{"action":"conference_status"}' >/dev/null; then
    break
  fi
  sleep 1
done
if ! post "$VISITOR_API" '{"action":"conference_status"}' >/dev/null; then
  echo "FATAL: visitor debug API did not become ready on $VISITOR_API"
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
echo "[4] Starting direct screen sharing from the host before join..."
HOST_SCREEN_RESPONSE="$(post "$VISITOR_API" '{"action":"conference_start_screen_share"}')"
if echo "$HOST_SCREEN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "host started screen sharing before the attendee joined"
else
  fail "host could not start screen sharing before the attendee joined"
  echo "$HOST_SCREEN_RESPONSE"
fi

echo ""
echo "[5] Joining the host meeting from the main desktop instance..."
JOIN_URL="ws://127.0.0.1:${SIGNALING_PORT}/meet/ws"
JOIN_RESPONSE="$(post "$MAIN_API" "{\"action\":\"conference_join\",\"url\":\"${JOIN_URL}\",\"role\":\"listener\"}")"
if echo "$JOIN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "main desktop accepted the join request"
else
  fail "main desktop rejected the join request"
  echo "$JOIN_RESPONSE"
fi

echo ""
echo "[6] Waiting for both conference participants to appear and receive the active host screen share..."
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

def participant_map(payload):
    room = payload.get('room') or {}
    return {p['callsign']: p for p in room.get('participants') or []}

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
host_participants = participant_map(host)
attendee_participants = participant_map(attendee)
if not host_participants.get(os.environ['ATTENDEE_CALLSIGN'], {}).get('is_connected'):
    sys.exit(1)
if not attendee_participants.get(os.environ['HOST_CALLSIGN'], {}).get('is_connected'):
    sys.exit(1)
if host.get('active_screen_sharer') != os.environ['HOST_CALLSIGN']:
    sys.exit(1)
if attendee.get('active_screen_sharer') != os.environ['HOST_CALLSIGN']:
    sys.exit(1)
if not host.get('local_screen_sharing'):
    sys.exit(1)
if attendee.get('remote_audio_stream_count', 0) < 1:
    sys.exit(1)
if attendee.get('remote_screen_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    JOINED=1
    break
  fi
  sleep 1
done

if [ "$JOINED" -eq 1 ]; then
  ok "host, attendee, and signaling server agree, and the late joiner received the active host screen share"
else
  fail "meeting never converged with the pre-existing host screen share"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
  echo "Meet info: $MEET_INFO"
fi

echo ""
echo "[7] Stopping the pre-join host screen share and waiting for cleanup..."
post "$VISITOR_API" '{"action":"conference_stop_screen_share"}' >/dev/null || true
PREJOIN_HOST_SCREEN_STOPPED=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_STATUS="$ATTENDEE_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
if host.get('active_screen_sharer') is not None:
    sys.exit(1)
if attendee.get('active_screen_sharer') is not None:
    sys.exit(1)
if host.get('local_screen_sharing'):
    sys.exit(1)
if attendee.get('remote_screen_stream_count', 0) != 0:
    sys.exit(1)
PY
  then
    PREJOIN_HOST_SCREEN_STOPPED=1
    break
  fi
  sleep 1
done

if [ "$PREJOIN_HOST_SCREEN_STOPPED" -eq 1 ]; then
  ok "pre-join host screen share stopped cleanly"
else
  fail "pre-join host screen share did not stop cleanly"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
fi

echo ""
echo "[8] Requesting speaker access from the attendee..."
REQUEST_RESPONSE="$(post "$MAIN_API" '{"action":"conference_request_speaker"}')"
if echo "$REQUEST_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "attendee requested speaker access"
else
  fail "attendee could not request speaker access"
  echo "$REQUEST_RESPONSE"
fi

echo ""
echo "[9] Waiting for the host to see the speaker request..."
REQUESTED=0
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_CALLSIGN="$ATTENDEE_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
pending = host.get('pending_speaker_requests') or []
if os.environ['ATTENDEE_CALLSIGN'] in pending:
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
  ok "host received the attendee speaker request"
else
  fail "host never saw the attendee speaker request"
  echo "$HOST_STATUS"
fi

echo ""
echo "[10] Promoting the attendee to speaker..."
PROMOTE_RESPONSE="$(post "$VISITOR_API" "{\"action\":\"conference_promote\",\"callsign\":\"${ATTENDEE_CALLSIGN}\"}")"
if echo "$PROMOTE_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "host promoted the attendee to speaker"
else
  fail "host could not promote the attendee"
  echo "$PROMOTE_RESPONSE"
fi

echo ""
echo "[11] Waiting for both sides to reflect the new speaker role..."
PROMOTED=0
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_STATUS="$ATTENDEE_STATUS" ATTENDEE_CALLSIGN="$ATTENDEE_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
target = os.environ['ATTENDEE_CALLSIGN']

def participant(payload, callsign):
    room = payload.get('room') or {}
    for entry in room.get('participants') or []:
        if entry.get('callsign') == callsign:
            return entry
    return {}

host_target = participant(host, target)
attendee_self = participant(attendee, target)
if host_target.get('role') != 'speaker':
    sys.exit(1)
if attendee_self.get('role') != 'speaker':
    sys.exit(1)
if host_target.get('speaker_request_pending'):
    sys.exit(1)
if attendee_self.get('speaker_request_pending'):
    sys.exit(1)
if host.get('remote_audio_stream_count', 0) < 1:
    sys.exit(1)
if attendee.get('remote_audio_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    PROMOTED=1
    break
  fi
  sleep 1
done

if [ "$PROMOTED" -eq 1 ]; then
  ok "host and attendee both show the attendee as a speaker"
else
  fail "speaker promotion did not propagate"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
fi

echo ""
echo "[12] Sending a meeting chat message from the attendee..."
CHAT_TEXT="LAN regression chat"
CHAT_RESPONSE="$(post "$MAIN_API" "{\"action\":\"conference_send_chat\",\"content\":\"${CHAT_TEXT}\"}")"
if echo "$CHAT_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "attendee sent a meeting chat message"
else
  fail "attendee could not send a meeting chat message"
  echo "$CHAT_RESPONSE"
fi

echo ""
echo "[13] Waiting for the host transcript to persist the chat message..."
CHAT_SYNCED=0
TRANSCRIPT_PATH=""
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
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
echo "[14] Starting direct screen sharing from the host..."
HOST_SCREEN_RESPONSE="$(post "$VISITOR_API" '{"action":"conference_start_screen_share"}')"
if echo "$HOST_SCREEN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "host started a direct screen share"
else
  fail "host could not start a direct screen share"
  echo "$HOST_SCREEN_RESPONSE"
fi

echo ""
echo "[15] Waiting for the attendee to receive the host screen share..."
HOST_SCREEN_ACTIVE=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_STATUS="$ATTENDEE_STATUS" HOST_CALLSIGN="$HOST_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
host_callsign = os.environ['HOST_CALLSIGN']
if host.get('active_screen_sharer') != host_callsign:
    sys.exit(1)
if attendee.get('active_screen_sharer') != host_callsign:
    sys.exit(1)
if not host.get('local_screen_sharing'):
    sys.exit(1)
if attendee.get('remote_screen_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    HOST_SCREEN_ACTIVE=1
    break
  fi
  sleep 1
done

if [ "$HOST_SCREEN_ACTIVE" -eq 1 ]; then
  ok "attendee received the host screen share"
else
  fail "host screen share did not propagate"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
fi

echo ""
echo "[16] Stopping the host screen share and waiting for cleanup..."
post "$VISITOR_API" '{"action":"conference_stop_screen_share"}' >/dev/null || true
HOST_SCREEN_STOPPED=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_STATUS="$ATTENDEE_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
if host.get('active_screen_sharer') is not None:
    sys.exit(1)
if attendee.get('active_screen_sharer') is not None:
    sys.exit(1)
if host.get('local_screen_sharing'):
    sys.exit(1)
if attendee.get('remote_screen_stream_count', 0) != 0:
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
  echo "Attendee status: $ATTENDEE_STATUS"
fi

echo ""
echo "[17] Requesting attendee screen share access and approving it..."
REQUEST_SCREEN_RESPONSE="$(post "$MAIN_API" '{"action":"conference_request_screen_share"}')"
if echo "$REQUEST_SCREEN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "attendee requested screen-share access"
else
  fail "attendee could not request screen-share access"
  echo "$REQUEST_SCREEN_RESPONSE"
fi

SCREEN_REQUESTED=0
for _ in $(seq 1 20); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_CALLSIGN="$ATTENDEE_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
pending = host.get('pending_screen_share_requests') or []
if os.environ['ATTENDEE_CALLSIGN'] in pending:
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
  ok "host received the attendee screen-share request"
else
  fail "host never saw the attendee screen-share request"
  echo "$HOST_STATUS"
fi

APPROVE_SCREEN_RESPONSE="$(post "$VISITOR_API" "{\"action\":\"conference_approve_screen_share\",\"callsign\":\"${ATTENDEE_CALLSIGN}\"}")"
if echo "$APPROVE_SCREEN_RESPONSE" | json_field "data['success']" | grep -qx "True"; then
  ok "host approved attendee screen sharing"
else
  fail "host could not approve attendee screen sharing"
  echo "$APPROVE_SCREEN_RESPONSE"
fi

echo ""
echo "[18] Waiting for the attendee screen share to reach the host..."
ATTENDEE_SCREEN_ACTIVE=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_STATUS="$ATTENDEE_STATUS" ATTENDEE_CALLSIGN="$ATTENDEE_CALLSIGN" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
callsign = os.environ['ATTENDEE_CALLSIGN']
if host.get('active_screen_sharer') != callsign:
    sys.exit(1)
if attendee.get('active_screen_sharer') != callsign:
    sys.exit(1)
if not attendee.get('local_screen_sharing'):
    sys.exit(1)
if host.get('remote_screen_stream_count', 0) < 1:
    sys.exit(1)
PY
  then
    ATTENDEE_SCREEN_ACTIVE=1
    break
  fi
  sleep 1
done

if [ "$ATTENDEE_SCREEN_ACTIVE" -eq 1 ]; then
  ok "host received the attendee screen share"
else
  fail "attendee screen share did not propagate"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
fi

echo ""
echo "[19] Stopping the attendee screen share and waiting for cleanup..."
post "$MAIN_API" '{"action":"conference_stop_screen_share"}' >/dev/null || true
ATTENDEE_SCREEN_STOPPED=0
for _ in $(seq 1 30); do
  HOST_STATUS="$(post "$VISITOR_API" '{"action":"conference_status"}')"
  ATTENDEE_STATUS="$(post "$MAIN_API" '{"action":"conference_status"}')"
  if HOST_STATUS="$HOST_STATUS" ATTENDEE_STATUS="$ATTENDEE_STATUS" python3 - <<'PY'
import json
import os
import sys

host = json.loads(os.environ['HOST_STATUS'])
attendee = json.loads(os.environ['ATTENDEE_STATUS'])
if host.get('active_screen_sharer') is not None:
    sys.exit(1)
if attendee.get('active_screen_sharer') is not None:
    sys.exit(1)
if host.get('remote_screen_stream_count', 0) != 0:
    sys.exit(1)
if attendee.get('local_screen_sharing'):
    sys.exit(1)
PY
  then
    ATTENDEE_SCREEN_STOPPED=1
    break
  fi
  sleep 1
done

if [ "$ATTENDEE_SCREEN_STOPPED" -eq 1 ]; then
  ok "attendee screen share stopped cleanly"
else
  fail "attendee screen share did not stop cleanly"
  echo "Host status: $HOST_STATUS"
  echo "Attendee status: $ATTENDEE_STATUS"
fi

echo ""
echo "[20] Ending the meeting and checking cleanup..."
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
check_webrtc_cleanup_logs || true
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
