#!/bin/bash
# Test DM Notification from Desktop to Android
#
# This script tests sending a DM from desktop to an Android device and
# monitors the notification tap behavior via logcat.
#
# Prerequisites:
#   - Android device connected via USB with Geogram installed
#   - Both devices should be connected to the same station (p2p.radio) OR same local network
#
# Usage:
#   ./test-dm-desktop-to-android.sh [ANDROID_CALLSIGN]
#
# If ANDROID_CALLSIGN is not provided, the script will try to get it from the Android API.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
DESKTOP_PORT=5577
TEMP_DIR="/tmp/geogram-desktop-test-${DESKTOP_PORT}"
NICKNAME="DesktopTest"
ADB="/home/brito/Android/Sdk/platform-tools/adb"
ANDROID_API_PORT=5599

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "Test DM Notification: Desktop -> Android"
echo "=============================================="
echo ""

# Check ADB
if [ ! -f "$ADB" ]; then
    echo -e "${RED}Error: ADB not found at $ADB${NC}"
    exit 1
fi

# Check Android device
DEVICES=$($ADB devices | grep -v "List of devices" | grep "device$" | wc -l)
if [ "$DEVICES" -eq 0 ]; then
    echo -e "${RED}Error: No Android device connected${NC}"
    exit 1
fi
echo -e "${GREEN}Android device connected${NC}"

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
echo -e "${GREEN}Binary ready: $BINARY_PATH${NC}"

# Set up port forwarding for Android API
echo -e "${YELLOW}Setting up ADB port forwarding...${NC}"
$ADB forward tcp:$ANDROID_API_PORT tcp:$ANDROID_API_PORT 2>/dev/null || true

# Try to get Android callsign from API
ANDROID_CALLSIGN="${1:-}"
if [ -z "$ANDROID_CALLSIGN" ]; then
    echo -e "${YELLOW}Trying to get Android callsign from API...${NC}"
    API_RESPONSE=$(curl -s "http://localhost:$ANDROID_API_PORT/api/status" 2>/dev/null || echo "")
    if [ -n "$API_RESPONSE" ]; then
        ANDROID_CALLSIGN=$(echo "$API_RESPONSE" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
    fi
fi

if [ -z "$ANDROID_CALLSIGN" ]; then
    echo -e "${RED}Error: Could not determine Android callsign${NC}"
    echo "Please provide it as an argument: $0 <CALLSIGN>"
    echo ""
    echo "To find your Android callsign:"
    echo "  1. Open Geogram on Android"
    echo "  2. Go to Settings (gear icon)"
    echo "  3. Look for your callsign/identity"
    exit 1
fi

echo -e "${GREEN}Android callsign: $ANDROID_CALLSIGN${NC}"

# Prepare temp directory
echo -e "${BLUE}Preparing temp directory...${NC}"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping...${NC}"
    kill $DESKTOP_PID 2>/dev/null || true
    kill $LOGCAT_PID 2>/dev/null || true
    echo -e "${GREEN}Done${NC}"
}
trap cleanup SIGINT SIGTERM EXIT

echo ""
echo "=============================================="
echo "STEP 1: Start Logcat Monitoring"
echo "=============================================="
echo ""

# Start logcat monitoring in background
echo -e "${YELLOW}Starting logcat monitor (filtering for Geogram/notification)...${NC}"
$ADB logcat -c  # Clear old logs
$ADB logcat -v time flutter:I *:S 2>/dev/null | tee /tmp/geogram-android-logcat.txt &
LOGCAT_PID=$!
echo "  Logcat PID: $LOGCAT_PID"
sleep 2

echo ""
echo "=============================================="
echo "STEP 2: Launch Desktop Instance"
echo "=============================================="
echo ""

# Launch desktop instance
echo -e "${YELLOW}Starting Desktop instance on port $DESKTOP_PORT...${NC}"
"$BINARY_PATH" \
    --port=$DESKTOP_PORT \
    --data-dir="$TEMP_DIR" \
    --new-identity \
    --nickname="$NICKNAME" \
    --skip-intro \
    --http-api \
    --debug-api \
    &
DESKTOP_PID=$!
echo "  PID: $DESKTOP_PID"

# Wait for API to be ready
echo -e "${YELLOW}Waiting for Desktop API to be ready...${NC}"
for i in {1..30}; do
    STATUS=$(curl -s "http://localhost:$DESKTOP_PORT/api/status" 2>/dev/null || echo "")
    if [ -n "$STATUS" ]; then
        break
    fi
    sleep 1
done

DESKTOP_CALLSIGN=$(curl -s "http://localhost:$DESKTOP_PORT/api/status" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
echo -e "${GREEN}Desktop ready: $DESKTOP_CALLSIGN${NC}"

echo ""
echo "=============================================="
echo "STEP 3: Send DM to Android"
echo "=============================================="
echo ""

echo -e "${CYAN}From: $DESKTOP_CALLSIGN (Desktop)${NC}"
echo -e "${CYAN}To: $ANDROID_CALLSIGN (Android)${NC}"
echo ""

# Navigate to devices panel and open DM
echo -e "${YELLOW}Navigating to devices panel...${NC}"
curl -s -X POST "http://localhost:$DESKTOP_PORT/api/debug" \
    -H 'Content-Type: application/json' \
    -d '{"action": "navigate", "panel": "devices"}'
sleep 3

echo -e "${YELLOW}Opening DM with $ANDROID_CALLSIGN...${NC}"
RESULT=$(curl -s -X POST "http://localhost:$DESKTOP_PORT/api/debug" \
    -H 'Content-Type: application/json' \
    -d "{\"action\": \"open_dm\", \"callsign\": \"$ANDROID_CALLSIGN\"}")
echo "  Result: $RESULT"
sleep 2

# Send a test message
TEST_MSG="Test notification $(date +%H:%M:%S)"
echo -e "${YELLOW}Sending message: '$TEST_MSG'...${NC}"
RESULT=$(curl -s -X POST "http://localhost:$DESKTOP_PORT/api/debug" \
    -H 'Content-Type: application/json' \
    -d "{\"action\": \"send_dm\", \"callsign\": \"$ANDROID_CALLSIGN\", \"content\": \"$TEST_MSG\"}")
echo "  Result: $RESULT"

echo ""
echo "=============================================="
echo -e "${GREEN}Message Sent!${NC}"
echo "=============================================="
echo ""
echo "Check your Android device for the notification."
echo "When you tap the notification, watch the logcat output above."
echo ""
echo "Key things to look for in logs:"
echo "  - 'Processing pending notification'"
echo "  - 'navigateToPanel'"
echo "  - 'openDM'"
echo "  - 'DMChatPage'"
echo ""
echo -e "${CYAN}Logcat is being saved to: /tmp/geogram-android-logcat.txt${NC}"
echo ""
echo "Press Ctrl+C to stop."
echo ""

# Wait indefinitely
wait $LOGCAT_PID
