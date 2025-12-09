#!/bin/bash
# DM (Direct Message) Test Runner
# Launches two Geogram instances and tests device-to-device messaging
#
# Usage:
#   ./run_dm_test.sh          # Run the test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Use two different ports for the two instances
PORT_A=5678
PORT_B=5679

# PIDs for cleanup
GEOGRAM_PID_A=""
GEOGRAM_PID_B=""
TEMP_DIR_A=""
TEMP_DIR_B=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=============================================="
echo "Device-to-Device DM Test Runner"
echo "=============================================="
echo ""

# Check for flutter/dart
DART_CMD=""
if command -v dart &> /dev/null; then
    DART_CMD="dart"
elif [ -f "$HOME/flutter/bin/dart" ]; then
    DART_CMD="$HOME/flutter/bin/dart"
else
    echo -e "${RED}Error: dart not found${NC}"
    exit 1
fi

FLUTTER_CMD=""
if command -v flutter &> /dev/null; then
    FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/flutter/bin/flutter"
else
    echo -e "${RED}Error: flutter not found${NC}"
    exit 1
fi

# Check for existing build or build
GEOGRAM_BIN="$PROJECT_DIR/build/linux/x64/release/bundle/geogram_desktop"
if [ ! -f "$GEOGRAM_BIN" ]; then
    echo -e "${YELLOW}Building Geogram Desktop...${NC}"
    cd "$PROJECT_DIR"
    $FLUTTER_CMD build linux --release
fi

if [ ! -f "$GEOGRAM_BIN" ]; then
    echo -e "${RED}Error: Could not build Geogram Desktop${NC}"
    exit 1
fi

# Create temporary directories for both instances
TEMP_DIR_A=$(mktemp -d -t geogram_dm_test_A_XXXXXX)
TEMP_DIR_B=$(mktemp -d -t geogram_dm_test_B_XXXXXX)
echo "Instance A temp directory: $TEMP_DIR_A"
echo "Instance B temp directory: $TEMP_DIR_B"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."

    if [ -n "$GEOGRAM_PID_A" ] && kill -0 "$GEOGRAM_PID_A" 2>/dev/null; then
        echo "Stopping Instance A (PID: $GEOGRAM_PID_A)"
        kill "$GEOGRAM_PID_A" 2>/dev/null || true
        sleep 1
        kill -9 "$GEOGRAM_PID_A" 2>/dev/null || true
    fi

    if [ -n "$GEOGRAM_PID_B" ] && kill -0 "$GEOGRAM_PID_B" 2>/dev/null; then
        echo "Stopping Instance B (PID: $GEOGRAM_PID_B)"
        kill "$GEOGRAM_PID_B" 2>/dev/null || true
        sleep 1
        kill -9 "$GEOGRAM_PID_B" 2>/dev/null || true
    fi

    if [ -d "$TEMP_DIR_A" ]; then
        echo "Removing temp directory A: $TEMP_DIR_A"
        rm -rf "$TEMP_DIR_A"
    fi

    if [ -d "$TEMP_DIR_B" ]; then
        echo "Removing temp directory B: $TEMP_DIR_B"
        rm -rf "$TEMP_DIR_B"
    fi

    echo "Cleanup complete"
}

# Set up trap for cleanup on exit
trap cleanup EXIT

# Using --new-identity flag to create temporary identities
echo ""
echo -e "${BLUE}Creating new identities via --new-identity flag${NC}"
echo ""

# Start Instance A with new client identity
cd "$PROJECT_DIR/build/linux/x64/release/bundle"
echo -e "${YELLOW}Starting Instance A (client) on port $PORT_A...${NC}"
./geogram_desktop --port=$PORT_A --data-dir="$TEMP_DIR_A" --http-api --debug-api --new-identity --identity-type=client --nickname="Test Client A" &
GEOGRAM_PID_A=$!
echo "Instance A PID: $GEOGRAM_PID_A"

# Start Instance B with new client identity
echo -e "${YELLOW}Starting Instance B (client) on port $PORT_B...${NC}"
./geogram_desktop --port=$PORT_B --data-dir="$TEMP_DIR_B" --http-api --debug-api --new-identity --identity-type=client --nickname="Test Client B" &
GEOGRAM_PID_B=$!
echo "Instance B PID: $GEOGRAM_PID_B"

# Wait for both servers to be ready
echo ""
echo "Waiting for servers to start..."
MAX_WAIT=30
WAITED=0

# Wait for Instance A
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s "http://localhost:$PORT_A/api/" > /dev/null 2>&1; then
        echo -e "${GREEN}Instance A is ready!${NC}"
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    echo -n "."
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}Instance A failed to start within $MAX_WAIT seconds${NC}"
    exit 1
fi

# Wait for Instance B
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s "http://localhost:$PORT_B/api/" > /dev/null 2>&1; then
        echo -e "${GREEN}Instance B is ready!${NC}"
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    echo -n "."
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}Instance B failed to start within $MAX_WAIT seconds${NC}"
    exit 1
fi

# Give instances time to fully initialize
echo ""
echo "Waiting for full initialization..."
sleep 5

# Check API status for both instances and get callsigns
echo ""
echo "=============================================="
echo "API Status Check"
echo "=============================================="
echo ""

echo -e "${BLUE}Instance A status:${NC}"
STATUS_A=$(curl -s "http://localhost:$PORT_A/api/status")
echo "$STATUS_A" | head -c 500
echo ""
CALLSIGN_A=$(echo "$STATUS_A" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
echo -e "${GREEN}Instance A callsign: $CALLSIGN_A${NC}"
echo ""

echo -e "${BLUE}Instance B status:${NC}"
STATUS_B=$(curl -s "http://localhost:$PORT_B/api/status")
echo "$STATUS_B" | head -c 500
echo ""
CALLSIGN_B=$(echo "$STATUS_B" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
echo -e "${GREEN}Instance B callsign: $CALLSIGN_B${NC}"
echo ""

# Verify we got valid callsigns
if [ -z "$CALLSIGN_A" ] || [ -z "$CALLSIGN_B" ]; then
    echo -e "${RED}Error: Could not get callsigns from instances${NC}"
    exit 1
fi

# Run the DM tests
echo "=============================================="
echo "Running DM Tests"
echo "=============================================="
echo ""

TEST_PASSED=0
TEST_FAILED=0

# Test 1: Check DM conversations endpoint (should be empty initially)
echo -e "${YELLOW}Test 1: Check DM conversations (should be empty)${NC}"
CONVERSATIONS_A=$(curl -s "http://localhost:$PORT_A/api/dm/conversations")
echo "Instance A conversations: $CONVERSATIONS_A"

if echo "$CONVERSATIONS_A" | grep -q '"total":0'; then
    echo -e "${GREEN}✓ Instance A has no conversations (expected)${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Instance A should have 0 conversations${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 2: Send a DM from Instance A to Instance B via API
echo -e "${YELLOW}Test 2: Send DM from A to B via API${NC}"
TIMESTAMP=$(date +%s)
TEST_MESSAGE="Hello from Instance A at $TIMESTAMP"

SEND_RESULT=$(curl -s -X POST "http://localhost:$PORT_A/api/dm/$CALLSIGN_B/messages" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"$TEST_MESSAGE\"}")
echo "Send result: $SEND_RESULT"

if echo "$SEND_RESULT" | grep -q '"success":true'; then
    echo -e "${GREEN}✓ Message sent successfully${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Failed to send message${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 3: Check that Instance A now has a conversation
echo -e "${YELLOW}Test 3: Check A has conversation with B${NC}"
CONVERSATIONS_A=$(curl -s "http://localhost:$PORT_A/api/dm/conversations")
echo "Instance A conversations: $CONVERSATIONS_A"

if echo "$CONVERSATIONS_A" | grep -q "$CALLSIGN_B"; then
    echo -e "${GREEN}✓ Instance A has conversation with $CALLSIGN_B${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Instance A should have conversation with $CALLSIGN_B${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 4: Read messages from Instance A's conversation with B
echo -e "${YELLOW}Test 4: Read messages from A's conversation with B${NC}"
MESSAGES=$(curl -s "http://localhost:$PORT_A/api/dm/$CALLSIGN_B/messages")
echo "Messages: $MESSAGES"

if echo "$MESSAGES" | grep -q "$TEST_MESSAGE"; then
    echo -e "${GREEN}✓ Message content found${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Message content not found${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 5: Send a reply from Instance B to Instance A
echo -e "${YELLOW}Test 5: Send reply from B to A via API${NC}"
REPLY_MESSAGE="Reply from Instance B at $TIMESTAMP"

REPLY_RESULT=$(curl -s -X POST "http://localhost:$PORT_B/api/dm/$CALLSIGN_A/messages" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"$REPLY_MESSAGE\"}")
echo "Reply result: $REPLY_RESULT"

if echo "$REPLY_RESULT" | grep -q '"success":true'; then
    echo -e "${GREEN}✓ Reply sent successfully${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Failed to send reply${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 6: Check that Instance B now has messages
echo -e "${YELLOW}Test 6: Read messages from B's conversation with A${NC}"
MESSAGES_B=$(curl -s "http://localhost:$PORT_B/api/dm/$CALLSIGN_A/messages")
echo "Instance B messages: $MESSAGES_B"

if echo "$MESSAGES_B" | grep -q "$REPLY_MESSAGE"; then
    echo -e "${GREEN}✓ Reply message found in B${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Reply message not found in B${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 7: Test sync endpoint - get messages for sync
echo -e "${YELLOW}Test 7: Test sync endpoint (GET)${NC}"
SYNC_GET=$(curl -s "http://localhost:$PORT_A/api/dm/sync/$CALLSIGN_B")
echo "Sync GET result: $SYNC_GET"

if echo "$SYNC_GET" | grep -q '"messages"'; then
    echo -e "${GREEN}✓ Sync GET endpoint works${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Sync GET endpoint failed${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 8: Check devices endpoint (requires debug API)
echo -e "${YELLOW}Test 8: Check devices endpoint${NC}"
DEVICES=$(curl -s "http://localhost:$PORT_A/api/devices")
echo "Devices result: $DEVICES"

if echo "$DEVICES" | grep -q '"myCallsign"'; then
    echo -e "${GREEN}✓ Devices endpoint works${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Devices endpoint failed${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Test 9: Test debug action for sending DM
echo -e "${YELLOW}Test 9: Send DM via debug action${NC}"
DEBUG_DM=$(curl -s -X POST "http://localhost:$PORT_A/api/debug" \
    -H "Content-Type: application/json" \
    -d "{\"action\": \"send_dm\", \"callsign\": \"$CALLSIGN_B\", \"content\": \"Debug API message\"}")
echo "Debug DM result: $DEBUG_DM"

if echo "$DEBUG_DM" | grep -q '"success":true'; then
    echo -e "${GREEN}✓ Debug send_dm action works${NC}"
    TEST_PASSED=$((TEST_PASSED + 1))
else
    echo -e "${RED}✗ Debug send_dm action failed${NC}"
    TEST_FAILED=$((TEST_FAILED + 1))
fi
echo ""

# Summary
echo "=============================================="
echo "Test Summary"
echo "=============================================="
echo ""
echo -e "Passed: ${GREEN}$TEST_PASSED${NC}"
echo -e "Failed: ${RED}$TEST_FAILED${NC}"
echo ""

if [ $TEST_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
