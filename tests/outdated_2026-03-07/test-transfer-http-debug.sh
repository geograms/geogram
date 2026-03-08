#!/bin/bash
# Test: Transfer debug HTTP download
#
# Launches a temporary Geogram instance with Debug API enabled, then triggers
# an HTTP download via the debug transfer endpoint. Leaves the UI running so
# you can observe the transfer in the Transfers panel.
#
# Usage:
#   ./tests/test-transfer-http-debug.sh
#   REMOTE_URL=https://p2p.radio/bot/models/ggml-small.bin ./tests/test-transfer-http-debug.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PORT=${PORT:-5678}
TEMP_DIR="/tmp/geogram-transfer-${PORT}"
NICKNAME=${NICKNAME:-"Transfer-Debug"}
REMOTE_URL=${REMOTE_URL:-"https://p2p.radio/bot/models/whisper/ggml-small.bin"}
LOCAL_PATH="${TEMP_DIR}/downloads/transfer.bin"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=============================================="
echo "Transfer Debug HTTP Download"
echo "=============================================="
echo "Port:       $PORT"
echo "Temp dir:   $TEMP_DIR"
echo "Remote URL: $REMOTE_URL"
echo "Local path: $LOCAL_PATH"
echo ""

# Find flutter command
FLUTTER_CMD=""
if command -v flutter &>/dev/null; then
  FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
  FLUTTER_CMD="$HOME/flutter/bin/flutter"
else
  echo -e "${RED}Error: flutter not found${NC}"
  exit 1
fi

BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ ! -f "$BINARY_PATH" ]; then
  echo -e "${YELLOW}Building Geogram...${NC}"
  cd "$PROJECT_DIR"
  $FLUTTER_CMD build linux --release
fi
echo -e "${GREEN}Binary ready${NC}"

echo -e "${YELLOW}Preparing temp directory...${NC}"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR/downloads"
echo "  Created: $TEMP_DIR"

echo -e "${YELLOW}Starting instance on port $PORT...${NC}"
"$BINARY_PATH" \
  --port=$PORT \
  --data-dir="$TEMP_DIR" \
  --new-identity \
  --nickname="$NICKNAME" \
  --skip-intro \
  --http-api \
  --debug-api \
  &
PID=$!
echo "  PID: $PID"

cleanup() {
  echo ""
  echo -e "${YELLOW}Leave the UI open to inspect transfers.${NC}"
  echo "PID: $PID"
  echo "When done, stop it with: kill $PID"
}
trap cleanup EXIT

# Wait for API to come up
echo -e "${YELLOW}Waiting for API...${NC}"
for i in {1..30}; do
  STATUS=$(curl -s "http://localhost:${PORT}/api/status" 2>/dev/null || true)
  if [[ "$STATUS" == *"Geogram"* ]]; then
    echo -e "${GREEN}API is up${NC}"
    break
  fi
  sleep 1
done

echo -e "${YELLOW}Triggering debug transfer...${NC}"
RESP=$(curl -s -X POST "http://localhost:${PORT}/api/debug" \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"transfer_http_download\",\"remote_url\":\"${REMOTE_URL}\",\"local_path\":\"${LOCAL_PATH}\"}")

echo "Response: $RESP"

if command -v python3 &>/dev/null; then
  PYTHON=python3
elif command -v python &>/dev/null; then
  PYTHON=python
else
  echo -e "${RED}python/python3 not found${NC}"
  exit 1
fi

TRANSFER_ID=$(printf '%s' "$RESP" | "$PYTHON" -c 'import json,sys
try:
    data=json.load(sys.stdin)
    print(data.get("transfer_id",""))
except Exception:
    print("")')

if [ -z "$TRANSFER_ID" ]; then
  echo -e "${RED}Could not parse transfer_id from response${NC}"
  exit 1
fi

echo -e "${YELLOW}Polling transfer record (id: $TRANSFER_ID)...${NC}"
RECORD_PATH="${TEMP_DIR}/transfers/records/${TRANSFER_ID}.json"
for i in {1..120}; do
  if [ -f "$RECORD_PATH" ]; then
    STATUS=$("$PYTHON" -c 'import json,sys,pathlib
p=pathlib.Path(sys.argv[1])
if not p.exists():
    print("missing")
    raise SystemExit(0)
data=json.loads(p.read_text())
status=data.get("status","unknown")
err=data.get("error") or ""
print(f"{status} {err}")' "$RECORD_PATH") || true
    STATE=$(echo "$STATUS" | awk '{print $1}')
    ERR=$(echo "$STATUS" | cut -d' ' -f2-)
    echo "  [$i] status=$STATE error=${ERR:-none}"
    if [ "$STATE" = "completed" ]; then
      ls -lh "$LOCAL_PATH"
      break
    fi
    if [ "$STATE" = "failed" ]; then
      echo -e "${RED}Transfer failed: $ERR${NC}"
      break
    fi
  else
    echo "  [$i] waiting for record..."
  fi
  sleep 5
done

echo ""
echo -e "${GREEN}Transfer requested. Open the Transfers panel to observe progress.${NC}"
echo "Instance running (PID $PID). Use kill to stop when finished."
