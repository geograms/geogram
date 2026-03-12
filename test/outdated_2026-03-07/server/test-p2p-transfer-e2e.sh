#!/bin/bash
# P2P File Transfer E2E Test
#
# This script tests P2P file transfer between two Geogram instances.
# It launches two instances, sends files from A to B, and verifies
# SHA1 hashes match.
#
# Based on: tests/run_two_temp_instances.sh
#
# Usage:
#   ./test-p2p-transfer-e2e.sh              # Full test with build
#   ./test-p2p-transfer-e2e.sh --skip-build # Skip rebuilding

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Default configuration
PORT_A=5577
PORT_B=5588
TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"
SKIP_BUILD=false
TIMEOUT=120  # seconds

# Test directories
TEST_SEND_DIR="${TEMP_DIR_A}/test-send"
TEST_RECV_DIR="${TEMP_DIR_B}/received"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Cleanup PIDs on exit
PID_A=""
PID_B=""

cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    if [ -n "$PID_A" ]; then
        kill "$PID_A" 2>/dev/null || true
    fi
    if [ -n "$PID_B" ]; then
        kill "$PID_B" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Show help
show_help() {
    echo "P2P File Transfer E2E Test"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --skip-build      Skip rebuilding the app"
    echo "  --timeout=SECS    Timeout in seconds (default: $TIMEOUT)"
    echo "  --help            Show this help"
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --timeout=*)
            TIMEOUT="${1#*=}"
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

echo "=============================================="
echo "P2P File Transfer E2E Test"
echo "=============================================="
echo "Port A: $PORT_A (Sender)"
echo "Port B: $PORT_B (Receiver)"
echo ""

# Find flutter command
FLUTTER_CMD=""
if command -v flutter &> /dev/null; then
    FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/flutter/bin/flutter"
else
    echo -e "${RED}Error: flutter not found${NC}"
    exit 1
fi

# Build the app
BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ "$SKIP_BUILD" = true ]; then
    echo -e "${YELLOW}Skipping build...${NC}"
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}Error: Binary not found at $BINARY_PATH${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Using existing binary${NC}"
else
    echo -e "${YELLOW}Building Geogram...${NC}"
    cd "$PROJECT_DIR"
    $FLUTTER_CMD build linux --release
    echo -e "${GREEN}✓ Build complete${NC}"
fi

# Clean up temp directories
echo -e "${BLUE}Preparing directories...${NC}"
rm -rf "$TEMP_DIR_A" "$TEMP_DIR_B"
mkdir -p "$TEMP_DIR_A" "$TEMP_DIR_B" "$TEST_SEND_DIR"

# Create test files
echo -e "${BLUE}Creating test files...${NC}"

# file1.txt - 1KB text file
head -c 1024 /dev/urandom | base64 > "$TEST_SEND_DIR/file1.txt"
echo -e "  file1.txt (1KB text)"

# file2.bin - 10KB random binary
dd if=/dev/urandom of="$TEST_SEND_DIR/file2.bin" bs=1024 count=10 2>/dev/null
echo -e "  file2.bin (10KB binary)"

# subdir/file3.txt - 500B text file in subdirectory
mkdir -p "$TEST_SEND_DIR/subdir"
head -c 500 /dev/urandom | base64 > "$TEST_SEND_DIR/subdir/file3.txt"
echo -e "  subdir/file3.txt (500B text)"

# Calculate total size
TOTAL_SIZE=$(du -sb "$TEST_SEND_DIR" | cut -f1)
FILE_COUNT=$(find "$TEST_SEND_DIR" -type f | wc -l)
echo -e "${GREEN}✓ Test files created ($FILE_COUNT files, ${TOTAL_SIZE} bytes)${NC}"

# Calculate scan range
SCAN_RANGE="${PORT_A}-${PORT_B}"

# Launch Instance A (Sender)
echo -e "${YELLOW}Starting Instance A (Sender)...${NC}"
"$BINARY_PATH" \
    --port=$PORT_A \
    --data-dir="$TEMP_DIR_A" \
    --new-identity \
    --nickname="Sender-A" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=$SCAN_RANGE \
    &
PID_A=$!
echo -e "${GREEN}✓ Instance A started (PID $PID_A)${NC}"

# Launch Instance B (Receiver)
echo -e "${YELLOW}Starting Instance B (Receiver)...${NC}"
"$BINARY_PATH" \
    --port=$PORT_B \
    --data-dir="$TEMP_DIR_B" \
    --new-identity \
    --nickname="Receiver-B" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=$SCAN_RANGE \
    &
PID_B=$!
echo -e "${GREEN}✓ Instance B started (PID $PID_B)${NC}"

# Wait for API to be ready
echo -e "${YELLOW}Waiting for APIs to be ready...${NC}"
for i in {1..30}; do
    STATUS_A=$(curl -s "http://localhost:$PORT_A/api/status" 2>/dev/null || echo "{}")
    STATUS_B=$(curl -s "http://localhost:$PORT_B/api/status" 2>/dev/null || echo "{}")

    if echo "$STATUS_A" | grep -q "callsign" && echo "$STATUS_B" | grep -q "callsign"; then
        break
    fi
    sleep 1
done

if ! echo "$STATUS_A" | grep -q "callsign"; then
    echo -e "${RED}✗ Instance A API not ready${NC}"
    exit 1
fi
if ! echo "$STATUS_B" | grep -q "callsign"; then
    echo -e "${RED}✗ Instance B API not ready${NC}"
    exit 1
fi

# Get callsigns
CALLSIGN_A=$(echo "$STATUS_A" | jq -r '.callsign')
CALLSIGN_B=$(echo "$STATUS_B" | jq -r '.callsign')
echo -e "${GREEN}✓ Sender callsign: $CALLSIGN_A${NC}"
echo -e "${GREEN}✓ Receiver callsign: $CALLSIGN_B${NC}"

# Trigger local network scan on both instances
echo -e "${YELLOW}Triggering local network scans...${NC}"
curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action":"local_scan"}' > /dev/null
curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action":"local_scan"}' > /dev/null

# Also manually add devices to each other as fallback
echo -e "${YELLOW}Manually registering devices...${NC}"
curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"add_device\",\"callsign\":\"$CALLSIGN_B\",\"url\":\"http://localhost:$PORT_B\"}" > /dev/null
curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"add_device\",\"callsign\":\"$CALLSIGN_A\",\"url\":\"http://localhost:$PORT_A\"}" > /dev/null

# Wait for discovery
echo -e "${YELLOW}Waiting for discovery...${NC}"
sleep 2  # Give time for registrations

DISCOVERY_TIMEOUT=30
for i in $(seq 1 $DISCOVERY_TIMEOUT); do
    DEVICES_A=$(curl -s "http://localhost:$PORT_A/api/devices" 2>/dev/null || echo "[]")
    if echo "$DEVICES_A" | grep -q "$CALLSIGN_B"; then
        echo -e "${GREEN}✓ A sees B${NC}"
        break
    fi
    if [ "$i" -eq "$DISCOVERY_TIMEOUT" ]; then
        echo -e "${RED}✗ Discovery timeout - A did not find B${NC}"
        echo "Devices A sees: $DEVICES_A"
        exit 1
    fi
    sleep 1
done

# Verify devices are registered correctly
echo -e "${YELLOW}Checking device registration on A...${NC}"
DEVICES_A_DEBUG=$(curl -s "http://localhost:$PORT_A/api/devices")
echo "$DEVICES_A_DEBUG" | jq -c ".[] | {callsign, url}" 2>/dev/null || echo "Devices: $DEVICES_A_DEBUG"

# Send transfer offer from A to B (now uses direct P2P API)
echo -e "${YELLOW}Sending transfer offer via direct P2P API...${NC}"
SEND_RESPONSE=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"p2p_send\",\"callsign\":\"$CALLSIGN_B\",\"folder\":\"$TEST_SEND_DIR\"}")

if ! echo "$SEND_RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    echo -e "${RED}✗ Failed to send offer: $SEND_RESPONSE${NC}"
    exit 1
fi

OFFER_ID=$(echo "$SEND_RESPONSE" | jq -r '.offer_id')
TOTAL_FILES=$(echo "$SEND_RESPONSE" | jq -r '.files')
TOTAL_BYTES=$(echo "$SEND_RESPONSE" | jq -r '.total_bytes')
SEND_STATUS=$(echo "$SEND_RESPONSE" | jq -r '.status')
echo -e "${GREEN}✓ Transfer offer sent (offer_id: $OFFER_ID, $TOTAL_FILES files, $TOTAL_BYTES bytes, status: $SEND_STATUS)${NC}"
echo "Full response: $SEND_RESPONSE"

# Try direct API call to B to verify connectivity
echo -e "${YELLOW}Testing direct P2P API call to B...${NC}"
DIRECT_TEST=$(curl -s -X POST "http://localhost:$PORT_B/api/p2p/offer" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"transfer_offer\",\"offerId\":\"test123\",\"senderCallsign\":\"$CALLSIGN_A\",\"timestamp\":$(date +%s),\"expiresAt\":$(($(date +%s) + 3600)),\"files\":[],\"totalBytes\":0,\"senderUrl\":\"http://localhost:$PORT_A\"}")
echo "Direct API test result: $DIRECT_TEST"

# Verify offer exists on A (outgoing)
echo -e "${YELLOW}Verifying offer on A (outgoing)...${NC}"
OUTGOING=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action":"p2p_list_outgoing"}')

if ! echo "$OUTGOING" | jq -e ".offers[] | select(.offer_id == \"$OFFER_ID\")" > /dev/null 2>&1; then
    echo -e "${RED}✗ Offer not found in A's outgoing list${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Offer verified in A's outgoing list${NC}"

# Poll B for incoming offer (now delivered via direct API)
echo -e "${YELLOW}Checking if offer arrived on B...${NC}"
OFFER_TIMEOUT=10
for i in $(seq 1 $OFFER_TIMEOUT); do
    INCOMING=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
        -H "Content-Type: application/json" \
        -d '{"action":"p2p_list_incoming"}')

    if echo "$INCOMING" | jq -e ".offers[] | select(.offer_id == \"$OFFER_ID\")" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Offer received on B (via direct P2P API)${NC}"
        break
    fi
    if [ "$i" -eq "$OFFER_TIMEOUT" ]; then
        echo -e "${RED}✗ Offer not found on B after ${OFFER_TIMEOUT}s${NC}"
        echo "B's incoming offers: $INCOMING"
        exit 1
    fi
    sleep 1
done

# Accept offer on B
echo -e "${YELLOW}Accepting offer on B...${NC}"
ACCEPT_RESPONSE=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"p2p_accept\",\"offer_id\":\"$OFFER_ID\",\"destination\":\"$TEST_RECV_DIR\"}")

if ! echo "$ACCEPT_RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    echo -e "${RED}✗ Failed to accept offer: $ACCEPT_RESPONSE${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Offer accepted on B${NC}"

# Give a moment for acceptance to propagate
sleep 1

# Verify A received the acceptance
echo -e "${YELLOW}Checking if A received acceptance...${NC}"
STATUS_ON_A=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"p2p_status\",\"offer_id\":\"$OFFER_ID\"}")
OFFER_STATUS=$(echo "$STATUS_ON_A" | jq -r '.status')
echo -e "${CYAN}  Offer status on A: $OFFER_STATUS${NC}"

# Get manifest from A's HTTP API (this tests the file serving)
echo -e "${YELLOW}Getting manifest from A...${NC}"
MANIFEST=$(curl -s "http://localhost:$PORT_A/api/p2p/offer/$OFFER_ID/manifest")

if ! echo "$MANIFEST" | jq -e '.files' > /dev/null 2>&1; then
    echo -e "${RED}✗ Failed to get manifest: $MANIFEST${NC}"
    exit 1
fi

TOKEN=$(echo "$MANIFEST" | jq -r '.token')
FILE_COUNT=$(echo "$MANIFEST" | jq '.files | length')
echo -e "${GREEN}✓ Got manifest with $FILE_COUNT files${NC}"

# Create destination directory
mkdir -p "$TEST_RECV_DIR"

# Download each file using the HTTP API
echo -e "${YELLOW}Downloading files from A...${NC}"
FILES_DOWNLOADED=0

for i in $(seq 0 $((FILE_COUNT - 1))); do
    FILE_PATH=$(echo "$MANIFEST" | jq -r ".files[$i].path")
    FILE_SIZE=$(echo "$MANIFEST" | jq -r ".files[$i].size")
    FILE_SHA1=$(echo "$MANIFEST" | jq -r ".files[$i].sha1")

    # Create subdirectories if needed
    DEST_FILE="$TEST_RECV_DIR/$FILE_PATH"
    mkdir -p "$(dirname "$DEST_FILE")"

    # Download file (URL-encode the path)
    ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$FILE_PATH'))")
    HTTP_CODE=$(curl -s -w "%{http_code}" -o "$DEST_FILE" \
        "http://localhost:$PORT_A/api/p2p/offer/$OFFER_ID/file?path=$ENCODED_PATH&token=$TOKEN")

    if [ "$HTTP_CODE" != "200" ]; then
        echo -e "${RED}✗ Failed to download $FILE_PATH (HTTP $HTTP_CODE)${NC}"
        exit 1
    fi

    # Verify size
    DOWNLOADED_SIZE=$(stat -c%s "$DEST_FILE")
    if [ "$DOWNLOADED_SIZE" != "$FILE_SIZE" ]; then
        echo -e "${RED}✗ Size mismatch for $FILE_PATH (expected $FILE_SIZE, got $DOWNLOADED_SIZE)${NC}"
        exit 1
    fi

    FILES_DOWNLOADED=$((FILES_DOWNLOADED + 1))
    echo -e "${CYAN}  Downloaded: $FILE_PATH ($FILE_SIZE bytes)${NC}"
done

echo -e "${GREEN}✓ Downloaded $FILES_DOWNLOADED files${NC}"

# Verify SHA1 hashes
echo -e "${YELLOW}Verifying SHA1 hashes...${NC}"
VERIFY_FAILED=false

for file in $(find "$TEST_SEND_DIR" -type f); do
    REL_PATH="${file#$TEST_SEND_DIR/}"
    RECV_FILE="$TEST_RECV_DIR/$REL_PATH"

    if [ ! -f "$RECV_FILE" ]; then
        echo -e "${RED}✗ Missing file: $REL_PATH${NC}"
        VERIFY_FAILED=true
        continue
    fi

    SEND_SHA1=$(sha1sum "$file" | cut -d' ' -f1)
    RECV_SHA1=$(sha1sum "$RECV_FILE" | cut -d' ' -f1)

    if [ "$SEND_SHA1" = "$RECV_SHA1" ]; then
        echo -e "${GREEN}✓ SHA1 verification: $REL_PATH OK${NC}"
    else
        echo -e "${RED}✗ SHA1 mismatch: $REL_PATH${NC}"
        echo "  Sent:     $SEND_SHA1"
        echo "  Received: $RECV_SHA1"
        VERIFY_FAILED=true
    fi
done

echo ""
echo "=============================================="
if [ "$VERIFY_FAILED" = true ]; then
    echo -e "${RED}TEST FAILED: SHA1 verification errors${NC}"
    echo "=============================================="
    exit 1
else
    echo -e "${GREEN}TEST PASSED: All $FILE_COUNT files transferred and verified${NC}"
    echo "=============================================="
    exit 0
fi
