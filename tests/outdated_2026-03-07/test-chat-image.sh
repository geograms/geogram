#!/bin/bash
# Test Chat Image Upload
#
# Launches a temporary Geogram instance with debug API enabled for testing
# chat image uploads.
#
# Usage:
#   ./test-chat-image.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PORT=8888
TEMP_DIR="/tmp/geogram-chat-test-${PORT}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo "=============================================="
echo "Test Chat Image Upload"
echo "=============================================="
echo ""

# Find flutter command
FLUTTER_CMD=""
if command -v flutter &> /dev/null; then
    FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/flutter/bin/flutter"
else
    echo "Error: flutter not found"
    exit 1
fi

# Build the app
BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${YELLOW}Building Geogram...${NC}"
    cd "$PROJECT_DIR"
    $FLUTTER_CMD build linux --release
fi
echo -e "${GREEN}Binary ready${NC}"

# Clean up and create fresh temp directory
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

echo ""
echo -e "${CYAN}Configuration:${NC}"
echo "  Port: $PORT"
echo "  Data: $TEMP_DIR"
echo ""

# Launch instance
echo -e "${YELLOW}Starting instance...${NC}"
"$BINARY_PATH" \
    --port=$PORT \
    --data-dir="$TEMP_DIR" \
    --new-identity \
    --nickname="ChatTest" \
    --skip-intro \
    --http-api \
    --debug-api \
    &
PID=$!
echo "  PID: $PID"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Stopping instance...${NC}"
    kill $PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGINT SIGTERM

# Wait for API to be ready
echo -e "${YELLOW}Waiting for API...${NC}"
for i in {1..30}; do
    if curl -s "http://localhost:$PORT/api/status" > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

CALLSIGN=$(curl -s "http://localhost:$PORT/api/status" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
echo -e "${GREEN}Instance ready: $CALLSIGN${NC}"

# Set the preferred station to p2p.radio
echo -e "${YELLOW}Setting preferred station to p2p.radio...${NC}"
RESULT=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action": "station_set", "url": "wss://p2p.radio", "name": "P2P Radio"}')
echo "  $RESULT"

# Connect to station
echo -e "${YELLOW}Connecting to station...${NC}"
RESULT=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action": "station_connect"}')
echo "  $RESULT"

# Wait for station connection to establish
echo -e "${YELLOW}Waiting for station connection (10s)...${NC}"
sleep 10

# Check station status
echo -e "${YELLOW}Checking station connection...${NC}"
RESULT=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action": "station_status"}')
echo "  $RESULT"

# Send test message with image using station_send_chat API
echo ""
echo -e "${CYAN}=============================================="
echo -e "Sending test message with image..."
echo -e "==============================================${NC}"
IMAGE_PATH="$PROJECT_DIR/tests/images/photo_2025-03-25_10-33-43.jpg"

if [ ! -f "$IMAGE_PATH" ]; then
    echo -e "${RED}ERROR: Test image not found at: $IMAGE_PATH${NC}"
    cleanup
fi

echo -e "${YELLOW}Image path: $IMAGE_PATH${NC}"
RESULT=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H 'Content-Type: application/json' \
    -d "{\"action\": \"station_send_chat\", \"room\": \"general\", \"content\": \"Test message from debug API at $(date)\", \"image_path\": \"$IMAGE_PATH\"}")

echo ""
echo -e "${CYAN}Response:${NC}"
echo "$RESULT" | jq . 2>/dev/null || echo "$RESULT"

# Check if successful
if echo "$RESULT" | grep -q '"success":true'; then
    echo ""
    echo -e "${GREEN}=============================================="
    echo -e "SUCCESS: Message with image uploaded!"
    echo -e "==============================================${NC}"
else
    echo ""
    echo -e "${RED}=============================================="
    echo -e "FAILED: Check logs above for details"
    echo -e "==============================================${NC}"
fi

# Check logs for upload details
echo ""
echo -e "${CYAN}Recent logs:${NC}"
curl -s "http://localhost:$PORT/api/log?limit=20&filter=upload" | jq -r '.entries[]?.message // .entries[]? // .' 2>/dev/null || curl -s "http://localhost:$PORT/api/log?limit=20"

echo ""
echo "=============================================="
echo "Instance Running"
echo "=============================================="
echo ""
echo "API: http://localhost:$PORT/api/status"
echo "Debug API: http://localhost:$PORT/api/debug"
echo ""
echo "Send another message with image:"
echo "  curl -X POST http://localhost:$PORT/api/debug -H 'Content-Type: application/json' -d '{\"action\": \"station_send_chat\", \"room\": \"general\", \"content\": \"Hello!\", \"image_path\": \"$IMAGE_PATH\"}'"
echo ""
echo "Check station status:"
echo "  curl -X POST http://localhost:$PORT/api/debug -H 'Content-Type: application/json' -d '{\"action\": \"station_status\"}'"
echo ""
echo "View logs:"
echo "  curl http://localhost:$PORT/api/log?limit=50"
echo ""
echo "Press Ctrl+C to stop"
echo ""

wait $PID
