#!/bin/bash
# End-to-End Backup Test (Provider + Client)
#
# Flow:
# 1) Instance A enables backup provider mode
# 2) Instance B sends invite to A
# 3) A approves B
# 4) B creates test data
# 5) B triggers backup to A
# 6) Verify snapshot exists on A
# 7) Delete files on B
# 8) Restore snapshot on B
# 9) Verify restored files on B

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
PORT_A=5577
PORT_B=5588
TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"
NICKNAME_A="Backup-Provider"
NICKNAME_B="Backup-Client"
SKIP_BUILD=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

show_help() {
  echo "End-to-End Backup Test"
  echo ""
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --port-a=PORT     Port for Instance A (default: $PORT_A)"
  echo "  --port-b=PORT     Port for Instance B (default: $PORT_B)"
  echo "  --name-a=NAME     Nickname for Instance A (default: $NICKNAME_A)"
  echo "  --name-b=NAME     Nickname for Instance B (default: $NICKNAME_B)"
  echo "  --skip-build      Skip rebuilding the app"
  echo "  --help            Show this help"
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --port-a=*)
      PORT_A="${1#*=}"
      TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
      shift
      ;;
    --port-b=*)
      PORT_B="${1#*=}"
      TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"
      shift
      ;;
    --name-a=*)
      NICKNAME_A="${1#*=}"
      shift
      ;;
    --name-b=*)
      NICKNAME_B="${1#*=}"
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --help|-h)
      show_help
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
 done

# Find flutter
FLUTTER_CMD=""
if command -v flutter &> /dev/null; then
  FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
  FLUTTER_CMD="$HOME/flutter/bin/flutter"
else
  echo -e "${RED}Error: flutter not found${NC}"
  exit 1
fi

BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ "$SKIP_BUILD" = true ]; then
  if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}Binary not found at $BINARY_PATH${NC}"
    exit 1
  fi
else
  echo -e "${YELLOW}Building Geogram...${NC}"
  cd "$PROJECT_DIR"
  $FLUTTER_CMD build linux --release
fi

# Clean temp dirs
rm -rf "$TEMP_DIR_A" "$TEMP_DIR_B"
mkdir -p "$TEMP_DIR_A" "$TEMP_DIR_B"

cleanup() {
  echo ""
  echo -e "${YELLOW}Stopping instances...${NC}"
  kill $PID_A $PID_B 2>/dev/null || true
  echo -e "${GREEN}Done${NC}"
}
trap cleanup EXIT

SCAN_START=$((PORT_A < PORT_B ? PORT_A : PORT_B))
SCAN_END=$((PORT_A > PORT_B ? PORT_A : PORT_B))
SCAN_RANGE="${SCAN_START}-${SCAN_END}"

# Start Instance A (Provider)
echo -e "${YELLOW}Starting Instance A ($NICKNAME_A) on port $PORT_A...${NC}"
"$BINARY_PATH" \
  --port=$PORT_A \
  --data-dir="$TEMP_DIR_A" \
  --new-identity \
  --nickname="$NICKNAME_A" \
  --skip-intro \
  --http-api \
  --debug-api \
  --scan-localhost=$SCAN_RANGE \
  &
PID_A=$!

# Start Instance B (Client)
echo -e "${YELLOW}Starting Instance B ($NICKNAME_B) on port $PORT_B...${NC}"
"$BINARY_PATH" \
  --port=$PORT_B \
  --data-dir="$TEMP_DIR_B" \
  --new-identity \
  --nickname="$NICKNAME_B" \
  --skip-intro \
  --http-api \
  --debug-api \
  --scan-localhost=$SCAN_RANGE \
  &
PID_B=$!

# Wait for APIs
echo -e "${YELLOW}Waiting for APIs...${NC}"
for i in {1..30}; do
  STATUS_A=$(curl -s "http://localhost:$PORT_A/api/status" 2>/dev/null || echo "")
  STATUS_B=$(curl -s "http://localhost:$PORT_B/api/status" 2>/dev/null || echo "")
  if [ -n "$STATUS_A" ] && [ -n "$STATUS_B" ]; then
    break
  fi
  sleep 1
done

CALLSIGN_A=$(curl -s "http://localhost:$PORT_A/api/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('callsign',''))")
CALLSIGN_B=$(curl -s "http://localhost:$PORT_B/api/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('callsign',''))")
NPUB_B=$(curl -s "http://localhost:$PORT_B/api/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('npub',''))")

if [ -z "$CALLSIGN_A" ] || [ -z "$CALLSIGN_B" ] || [ -z "$NPUB_B" ]; then
  echo -e "${RED}Failed to read callsigns${NC}"
  exit 1
fi

echo -e "${GREEN}Instance A callsign: $CALLSIGN_A${NC}"
echo -e "${GREEN}Instance B callsign: $CALLSIGN_B${NC}"

# Wait for discovery
echo -e "${YELLOW}Waiting for device discovery (8 seconds)...${NC}"
sleep 8

# Add a test file on B
TEST_FILE="$TEMP_DIR_B/backup-test.txt"
echo "Backup test file - $(date)" > "$TEST_FILE"

echo ""
echo "=============================================="
echo "STEP 1: Enable Provider Mode on A (debug action)"
echo "=============================================="

PROVIDER_ENABLE=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
  -H 'Content-Type: application/json' \
  -d '{
    "action": "backup_provider_enable",
    "enabled": true,
    "max_storage_gb": 1,
    "max_client_storage_gb": 0.5,
    "max_snapshots": 5
  }' | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))")

if [ "$PROVIDER_ENABLE" != "True" ]; then
  echo -e "${RED}Provider mode not enabled${NC}"
  exit 1
fi

echo -e "${GREEN}Provider mode enabled on A${NC}"


echo ""
echo "=============================================="
echo "STEP 2: B Sends Invite to A (debug action)"
echo "=============================================="

INVITE_RESPONSE_FILE=$(mktemp)
curl -s -X POST "http://localhost:$PORT_B/api/debug" \
  -H 'Content-Type: application/json' \
  -d "{
    \"action\": \"backup_send_invite\",
    \"provider_callsign\": \"$CALLSIGN_A\",
    \"interval_days\": 1
  }" > "$INVITE_RESPONSE_FILE" &
INVITE_PID=$!

echo -e "${GREEN}Invite request started from B to A${NC}"

# Wait for invite to arrive
for i in {1..20}; do
  STATUS_JSON=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action":"backup_get_status"}')
  FOUND=$(echo "$STATUS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(any(c.get('client_callsign')=='$CALLSIGN_B' for c in d.get('clients',[])))")
  if [ "$FOUND" = "True" ]; then
    break
  fi
  sleep 1
done

STATUS_JSON=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
  -H 'Content-Type: application/json' \
  -d '{"action":"backup_get_status"}')
FOUND=$(echo "$STATUS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(any(c.get('client_callsign')=='$CALLSIGN_B' for c in d.get('clients',[])))")
if [ "$FOUND" != "True" ]; then
  echo -e "${RED}Invite not received on A${NC}"
  echo "$STATUS_JSON"
  exit 1
fi

echo -e "${GREEN}Invite received on A${NC}"


echo ""
echo "=============================================="
echo "STEP 3: A Accepts B (debug action)"
echo "=============================================="

INVITE_ACCEPTED=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
  -H 'Content-Type: application/json' \
  -d "{
    \"action\": \"backup_accept_invite\",
    \"client_callsign\": \"$CALLSIGN_B\",
    \"client_npub\": \"$NPUB_B\",
    \"max_storage_mb\": 256,
    \"max_snapshots\": 3
  }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))")

if [ "$INVITE_ACCEPTED" != "True" ]; then
  echo -e "${RED}Invite approval failed${NC}"
  exit 1
fi

# Wait for provider to be active on B
for i in {1..20}; do
  STATUS_JSON=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action":"backup_get_status"}')
  STATUS=$(echo "$STATUS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); p=[p for p in d.get('providers',[]) if p.get('provider_callsign')=='$CALLSIGN_A']; print(p[0].get('status','') if p else '')")
  if [ "$STATUS" = "active" ]; then
    break
  fi
  sleep 1
done

STATUS_JSON=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
  -H 'Content-Type: application/json' \
  -d '{"action":"backup_get_status"}')
STATUS=$(echo "$STATUS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); p=[p for p in d.get('providers',[]) if p.get('provider_callsign')=='$CALLSIGN_A']; print(p[0].get('status','') if p else '')")
if [ "$STATUS" != "active" ]; then
  echo -e "${RED}Provider not active on B${NC}"
  echo "$STATUS_JSON"
  exit 1
fi

echo -e "${GREEN}Provider relationship active${NC}"

wait $INVITE_PID
INVITE_SENT=$(cat "$INVITE_RESPONSE_FILE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))")
rm -f "$INVITE_RESPONSE_FILE"
if [ "$INVITE_SENT" != "True" ]; then
  echo -e "${RED}Invite send failed${NC}"
  exit 1
fi


echo ""
echo "=============================================="
echo "STEP 4: Create Test Data on B"
echo "=============================================="

TEST_DATA_DIR="$TEMP_DIR_B/test-backup-data"
mkdir -p "$TEST_DATA_DIR"
TEST_FILES=()

for i in 1 2 3; do
  FILE_PATH="$TEST_DATA_DIR/test_file_${i}.bin"
  dd if=/dev/urandom of="$FILE_PATH" bs=1024 count=8 status=none
  FILE_SHA=$(python3 - "$FILE_PATH" <<'PY'
import hashlib
import sys

path = sys.argv[1]
hash_obj = hashlib.sha1()
with open(path, 'rb') as handle:
    for chunk in iter(lambda: handle.read(8192), b''):
        hash_obj.update(chunk)
print(hash_obj.hexdigest())
PY
  )
  TEST_FILES+=("${FILE_PATH}|${FILE_SHA}")
done

if [ "${#TEST_FILES[@]}" -lt 1 ]; then
  echo -e "${RED}No test files created${NC}"
  exit 1
fi

echo -e "${GREEN}Test data created on B${NC}"


echo ""
echo "=============================================="
echo "STEP 5: B Triggers Backup (debug action)"
echo "=============================================="

BACKUP_STARTED=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
  -H 'Content-Type: application/json' \
  -d "{
    \"action\": \"backup_start\",
    \"provider_callsign\": \"$CALLSIGN_A\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))")

if [ "$BACKUP_STARTED" != "True" ]; then
  echo -e "${RED}Backup start failed${NC}"
  exit 1
fi

# Poll backup status
STATUS=""
for i in {1..120}; do
  STATUS_JSON=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action":"backup_get_status"}')
  STATUS=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backup_status',{}).get('status',''))")
  if [ "$STATUS" = "complete" ]; then
    break
  fi
  if [ "$STATUS" = "failed" ]; then
    echo -e "${RED}Backup failed${NC}"
    echo "$STATUS_JSON"
    exit 1
  fi
  sleep 1
done

if [ "$STATUS" != "complete" ]; then
  echo -e "${RED}Backup did not complete in time${NC}"
  exit 1
fi

echo -e "${GREEN}Backup completed${NC}"


echo ""
echo "=============================================="
echo "STEP 6: Verify Snapshot on A"
echo "=============================================="

SNAPSHOT_DIR=""
for i in {1..30}; do
  SNAPSHOT_DIR=$(find "$TEMP_DIR_A/backups/$CALLSIGN_B" -maxdepth 1 -type d -name '????-??-??*' 2>/dev/null | sort | tail -n 1)
  if [ -n "$SNAPSHOT_DIR" ] && [ -f "$SNAPSHOT_DIR/manifest.json" ]; then
    break
  fi
  sleep 1
done

if [ -z "$SNAPSHOT_DIR" ]; then
  echo -e "${RED}No snapshots found on A${NC}"
  exit 1
fi

if [ ! -f "$SNAPSHOT_DIR/manifest.json" ]; then
  echo -e "${RED}Manifest not found in snapshot${NC}"
  exit 1
fi

if [ ! -f "$SNAPSHOT_DIR/status.json" ]; then
  echo -e "${RED}Status file not found in snapshot${NC}"
  exit 1
fi

if [ ! -f "$SNAPSHOT_DIR/files.zip" ]; then
  echo -e "${RED}Encrypted archive not found in snapshot${NC}"
  exit 1
fi

ZIP_PATH="$SNAPSHOT_DIR/files.zip"
FILE_COUNT=0
for i in {1..20}; do
  FILE_COUNT=$(python3 - "$ZIP_PATH" <<'PY'
import zipfile,sys
path=sys.argv[1] if len(sys.argv) > 1 else ""
if not path or not zipfile.is_zipfile(path):
    print(0)
    sys.exit(0)
with zipfile.ZipFile(path) as zf:
    names=[n for n in zf.namelist() if not n.endswith('/')]
    print(len(names))
PY
  )
  if [ "$FILE_COUNT" -ge 1 ]; then
    break
  fi
  sleep 1
done
if [ "$FILE_COUNT" -lt 1 ]; then
  echo -e "${RED}No encrypted files found in archive${NC}"
  exit 1
fi

echo -e "${GREEN}Snapshot verified on provider${NC}"

SNAPSHOT_ID=$(basename "$SNAPSHOT_DIR")

echo ""
echo "=============================================="
echo "STEP 7: Delete Files on B"
echo "=============================================="

DELETED_FILES=()
for entry in "${TEST_FILES[@]}"; do
  if [ "${#DELETED_FILES[@]}" -ge 2 ]; then
    break
  fi
  FILE_PATH="${entry%%|*}"
  FILE_SHA="${entry##*|}"
  rm -f "$FILE_PATH"
  if [ -f "$FILE_PATH" ]; then
    echo -e "${RED}Failed to delete $FILE_PATH${NC}"
    exit 1
  fi
  DELETED_FILES+=("${FILE_PATH}|${FILE_SHA}")
done

if [ "${#DELETED_FILES[@]}" -lt 1 ]; then
  echo -e "${RED}No files deleted for restore test${NC}"
  exit 1
fi

echo -e "${GREEN}Deleted ${#DELETED_FILES[@]} files on B${NC}"

echo ""
echo "=============================================="
echo "STEP 8: B Restores Snapshot from A (debug action)"
echo "=============================================="

RESTORE_STARTED=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
  -H 'Content-Type: application/json' \
  -d "{
    \"action\": \"backup_restore\",
    \"provider_callsign\": \"$CALLSIGN_A\",
    \"snapshot_id\": \"$SNAPSHOT_ID\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))")

if [ "$RESTORE_STARTED" != "True" ]; then
  echo -e "${RED}Restore start failed${NC}"
  exit 1
fi

# Poll restore status
RESTORE_STATUS=""
for i in {1..120}; do
  STATUS_JSON=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action":"backup_get_status"}')
  RESTORE_STATUS=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('restore_status',{}).get('status',''))")
  if [ "$RESTORE_STATUS" = "complete" ]; then
    break
  fi
  if [ "$RESTORE_STATUS" = "failed" ]; then
    echo -e "${RED}Restore failed${NC}"
    echo "$STATUS_JSON"
    exit 1
  fi
  sleep 1
done

if [ "$RESTORE_STATUS" != "complete" ]; then
  echo -e "${RED}Restore did not complete in time${NC}"
  exit 1
fi

echo -e "${GREEN}Restore completed${NC}"

echo ""
echo "=============================================="
echo "STEP 9: Verify Restored Files on B"
echo "=============================================="

for entry in "${DELETED_FILES[@]}"; do
  FILE_PATH="${entry%%|*}"
  EXPECTED_SHA="${entry##*|}"
  if [ ! -f "$FILE_PATH" ]; then
    echo -e "${RED}Restored file missing: $FILE_PATH${NC}"
    exit 1
  fi
  ACTUAL_SHA=$(python3 - "$FILE_PATH" <<'PY'
import hashlib
import sys

path = sys.argv[1]
hash_obj = hashlib.sha1()
with open(path, 'rb') as handle:
    for chunk in iter(lambda: handle.read(8192), b''):
        hash_obj.update(chunk)
print(hash_obj.hexdigest())
PY
  )
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo -e "${RED}SHA1 mismatch for restored file: $FILE_PATH${NC}"
    echo -e "${RED}Expected: $EXPECTED_SHA, got: $ACTUAL_SHA${NC}"
    exit 1
  fi
done

echo -e "${GREEN}Restore verified on client${NC}"

echo ""
echo "=============================================="
echo "Backup + Restore Test Completed Successfully"
echo "=============================================="
