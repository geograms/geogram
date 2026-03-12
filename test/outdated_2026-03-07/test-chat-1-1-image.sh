#!/bin/bash
# Test 1:1 DM Image Transfer
#
# This script tests sending images in direct messages between two local instances.
#
# Usage:
#   ./test-chat-1-1-image.sh
#
# Steps:
#   1. Launch two temporary instances with localhost discovery
#   2. Wait for instances to discover each other
#   3. Open DM conversation on both instances
#   4. Send an image from A to B
#   5. Verify the image was received

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
PORT_A=5577
PORT_B=5588
TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"
NICKNAME_A="Alice"
NICKNAME_B="Bob"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "Test 1:1 DM Image Transfer"
echo "=============================================="
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

# Build or use existing binary
BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${YELLOW}Building Geogram...${NC}"
    cd "$PROJECT_DIR"
    $FLUTTER_CMD build linux --release
fi
echo -e "${GREEN}Binary ready${NC}"

# Clean up temp directories
echo -e "${BLUE}Preparing temp directories...${NC}"
rm -rf "$TEMP_DIR_A" "$TEMP_DIR_B"
mkdir -p "$TEMP_DIR_A" "$TEMP_DIR_B"
echo "  Created: $TEMP_DIR_A"
echo "  Created: $TEMP_DIR_B"

# Scan range for localhost discovery
SCAN_RANGE="${PORT_A}-${PORT_B}"

echo ""
echo -e "${CYAN}Configuration:${NC}"
echo "  Instance A: port=$PORT_A, name=$NICKNAME_A"
echo "  Instance B: port=$PORT_B, name=$NICKNAME_B"
echo "  Localhost scan range: $SCAN_RANGE"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping instances...${NC}"
    kill $PID_A $PID_B 2>/dev/null || true
    echo -e "${GREEN}Done${NC}"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Launch Instance A
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
echo "  PID: $PID_A"

# Launch Instance B
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
echo "  PID: $PID_B"

echo ""
echo -e "${YELLOW}Waiting for APIs to be ready...${NC}"

# Wait for both APIs
for i in {1..30}; do
    STATUS_A=$(curl -s "http://localhost:$PORT_A/api/status" 2>/dev/null || echo "")
    STATUS_B=$(curl -s "http://localhost:$PORT_B/api/status" 2>/dev/null || echo "")
    if [ -n "$STATUS_A" ] && [ -n "$STATUS_B" ]; then
        break
    fi
    sleep 1
done

# Get callsigns
CALLSIGN_A=$(curl -s "http://localhost:$PORT_A/api/status" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
CALLSIGN_B=$(curl -s "http://localhost:$PORT_B/api/status" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)

echo -e "${GREEN}Instance A ready: $CALLSIGN_A${NC}"
echo -e "${GREEN}Instance B ready: $CALLSIGN_B${NC}"

# Wait for device discovery (instances need to find each other)
echo ""
echo -e "${YELLOW}Waiting for device discovery (10 seconds)...${NC}"
sleep 10

# Check if they discovered each other
echo -e "${CYAN}Checking device discovery...${NC}"
DEVICES_A=$(curl -s "http://localhost:$PORT_A/api/devices" 2>/dev/null)
DEVICES_B=$(curl -s "http://localhost:$PORT_B/api/devices" 2>/dev/null)

if echo "$DEVICES_A" | grep -q "$CALLSIGN_B"; then
    echo -e "${GREEN}  Instance A sees Instance B ($CALLSIGN_B)${NC}"
else
    echo -e "${RED}  Instance A does NOT see Instance B${NC}"
fi

if echo "$DEVICES_B" | grep -q "$CALLSIGN_A"; then
    echo -e "${GREEN}  Instance B sees Instance A ($CALLSIGN_A)${NC}"
else
    echo -e "${RED}  Instance B does NOT see Instance A${NC}"
fi

echo ""
echo "=============================================="
echo "STEP 1: Open DM Conversations"
echo "=============================================="
echo ""

# Step 1a: Navigate to devices panel on Instance A
echo -e "${YELLOW}[A] Navigating to devices panel...${NC}"
RESULT_A=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action": "navigate", "panel": "devices"}')
echo "  Result: $RESULT_A"

# Wait for UI to update and DevicesBrowserPage to mount
echo -e "${YELLOW}[A] Waiting for devices panel to load (3s)...${NC}"
sleep 3

# Step 1b: Open DM conversation on Instance A with Instance B
echo -e "${YELLOW}[A] Opening DM with $CALLSIGN_B...${NC}"
RESULT_A=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H 'Content-Type: application/json' \
    -d "{\"action\": \"open_dm\", \"callsign\": \"$CALLSIGN_B\"}")
echo "  Result: $RESULT_A"

# Wait for DM page to open
echo -e "${YELLOW}[A] Waiting for DM page to load (2s)...${NC}"
sleep 2

# Step 1c: Navigate to devices panel on Instance B
echo -e "${YELLOW}[B] Navigating to devices panel...${NC}"
RESULT_B=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action": "navigate", "panel": "devices"}')
echo "  Result: $RESULT_B"

# Wait for UI to update and DevicesBrowserPage to mount
echo -e "${YELLOW}[B] Waiting for devices panel to load (3s)...${NC}"
sleep 3

# Step 1d: Open DM conversation on Instance B with Instance A
echo -e "${YELLOW}[B] Opening DM with $CALLSIGN_A...${NC}"
RESULT_B=$(curl -s -X POST "http://localhost:$PORT_B/api/debug" \
    -H 'Content-Type: application/json' \
    -d "{\"action\": \"open_dm\", \"callsign\": \"$CALLSIGN_A\"}")
echo "  Result: $RESULT_B"

# Wait for DM page to open
echo -e "${YELLOW}[B] Waiting for DM page to load (2s)...${NC}"
sleep 2

echo ""
echo "=============================================="
echo -e "${GREEN}DM Conversations Opened${NC}"
echo "=============================================="
echo ""
echo "Instance A ($CALLSIGN_A) has DM open with $CALLSIGN_B"
echo "Instance B ($CALLSIGN_B) has DM open with $CALLSIGN_A"

echo ""
echo "=============================================="
echo "STEP 2: Send Image from A to B"
echo "=============================================="
echo ""

# Find the test image dynamically
IMAGE_PATH=$(find "$PROJECT_DIR/tests/images" -type f \( -name "*.jpg" -o -name "*.png" -o -name "*.jpeg" \) | head -1)

if [ -z "$IMAGE_PATH" ] || [ ! -f "$IMAGE_PATH" ]; then
    echo -e "${RED}ERROR: No test image found in $PROJECT_DIR/tests/images/${NC}"
    exit 1
fi

echo -e "${CYAN}Image found: $IMAGE_PATH${NC}"
echo ""
echo -e "${YELLOW}Sending image from Instance A to Instance B...${NC}"
echo "  From: $CALLSIGN_A (port $PORT_A)"
echo "  To: $CALLSIGN_B (port $PORT_B)"
echo "  File: $(basename "$IMAGE_PATH")"
echo ""

RESULT=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H 'Content-Type: application/json' \
    -d "{\"action\": \"send_dm_file\", \"callsign\": \"$CALLSIGN_B\", \"file_path\": \"$IMAGE_PATH\"}")

echo "  API Response: $RESULT"

# Wait for transfer to complete
echo ""
echo -e "${YELLOW}Waiting for transfer (5s)...${NC}"
sleep 5

echo ""
echo "=============================================="
echo "STEP 3: Verify Transfer"
echo "=============================================="
echo ""

echo -e "${CYAN}Sender logs (Instance A):${NC}"
curl -s "http://localhost:$PORT_A/log?filter=DM%20FILE&limit=10" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('logs',[])))" 2>/dev/null || \
    curl -s "http://localhost:$PORT_A/log?filter=DM%20FILE&limit=10"

echo ""
echo -e "${CYAN}Receiver logs (Instance B):${NC}"
curl -s "http://localhost:$PORT_B/log?filter=DM%20FILE&limit=10" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(d.get('logs',[])))" 2>/dev/null || \
    curl -s "http://localhost:$PORT_B/log?filter=DM%20FILE&limit=10"

echo ""
echo -e "${CYAN}Checking received files on Instance B:${NC}"
RECEIVED_DIR="$TEMP_DIR_B/chat/$CALLSIGN_A/files"
if [ -d "$RECEIVED_DIR" ]; then
    RECEIVED_FILES=$(ls -la "$RECEIVED_DIR" 2>/dev/null)
    if [ -n "$RECEIVED_FILES" ]; then
        echo -e "${GREEN}SUCCESS - Files in $RECEIVED_DIR:${NC}"
        echo "$RECEIVED_FILES"
    else
        echo -e "${RED}FAILED: Directory exists but no files${NC}"
    fi
else
    echo -e "${RED}FAILED: Directory not found: $RECEIVED_DIR${NC}"
fi

echo ""
echo "=============================================="
echo "Test Complete"
echo "=============================================="
echo ""
echo "Instances are still running. Press Ctrl+C to stop."
echo ""

# Wait indefinitely
wait
