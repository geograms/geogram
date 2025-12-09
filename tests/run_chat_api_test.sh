#!/bin/bash
# Chat API Test Runner
# Creates a temporary environment, launches Geogram, runs tests, and cleans up
#
# Usage:
#   ./run_chat_api_test.sh          # Run the test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_PORT=5678
GEOGRAM_PID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "Chat API Test Runner"
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

# Create temporary directory
TEMP_DIR=$(mktemp -d -t geogram_chat_test_XXXXXX)
echo "Temp directory: $TEMP_DIR"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."

    if [ -n "$GEOGRAM_PID" ] && kill -0 "$GEOGRAM_PID" 2>/dev/null; then
        echo "Stopping Geogram (PID: $GEOGRAM_PID)"
        kill "$GEOGRAM_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$GEOGRAM_PID" 2>/dev/null || true
    fi

    if [ -d "$TEMP_DIR" ]; then
        echo "Removing temp directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi

    echo "Cleanup complete"
}

# Set up trap for cleanup on exit
trap cleanup EXIT

# Using --new-identity flag to create temporary identity
echo ""
echo -e "${YELLOW}Creating new identity via --new-identity flag${NC}"
echo ""

# Start Geogram with new identity
cd "$PROJECT_DIR/build/linux/x64/release/bundle"
echo "Starting Geogram Desktop on port $TEST_PORT..."
./geogram_desktop --port=$TEST_PORT --data-dir="$TEMP_DIR" --http-api --debug-api --new-identity --identity-type=client --nickname="Chat Test User" &
GEOGRAM_PID=$!
echo "Geogram PID: $GEOGRAM_PID"

# Wait for server to be ready
echo "Waiting for server to start..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s "http://localhost:$TEST_PORT/api/" > /dev/null 2>&1; then
        echo -e "${GREEN}Server is ready!${NC}"
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    echo -n "."
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}Server failed to start within $MAX_WAIT seconds${NC}"
    exit 1
fi

# Give it time to fully initialize (create collections, etc.)
echo "Waiting for full initialization..."
sleep 5

# Check API status and get callsign
echo ""
echo "Checking API status..."
STATUS=$(curl -s "http://localhost:$TEST_PORT/api/status")
echo "$STATUS" | head -c 300
echo ""
CALLSIGN=$(echo "$STATUS" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
echo -e "${GREEN}Test callsign: $CALLSIGN${NC}"
echo ""

# Run the tests
echo "=============================================="
echo "Running Chat API Tests"
echo "=============================================="
echo ""

cd "$PROJECT_DIR"
$DART_CMD run tests/chat_api_test.dart --port=$TEST_PORT

TEST_RESULT=$?

echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
else
    echo -e "${RED}Some tests failed${NC}"
fi

exit $TEST_RESULT
