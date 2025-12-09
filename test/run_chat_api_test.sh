#!/bin/bash
# Chat API Test Runner
# Creates a temporary environment, launches Geogram, runs tests, and cleans up
#
# Usage:
#   ./run_chat_api_test.sh          # Run with GUI mode (default)
#   ./run_chat_api_test.sh --cli    # Run with CLI mode (station/server)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_PORT=5678
GEOGRAM_PID=""
CLI_MODE=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --cli)
            CLI_MODE=true
            shift
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "Chat API Test Runner"
if [ "$CLI_MODE" = true ]; then
    echo "Mode: CLI (Station/Server)"
else
    echo "Mode: GUI (Desktop)"
fi
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

# Create directory structure
echo "Creating test environment..."

mkdir -p "$TEMP_DIR/devices"

# Generate a test callsign and identity
# Use a fixed test npub/nsec pair (valid NOSTR keys for testing)
# These are deterministic test keys - DO NOT use in production
TEST_PRIVATE_KEY_HEX="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
TEST_NSEC="nsec1qy93g5tznv0a0hzfn5j4v4z0m7lwy2c5rx6tykum2e4kf6vfn0mqqp96j0"
TEST_NPUB="npub1test000000000000000000000000000000000000000000000000testpub"
TEST_CALLSIGN="X1TEST"
TEST_PROFILE_ID="test123"

# Create device directory
mkdir -p "$TEMP_DIR/devices/$TEST_CALLSIGN"

# Create config.json (main app config) - must be properly formatted
# profiles is a LIST, not an object
cat > "$TEMP_DIR/config.json" << EOF
{
  "version": "1.0",
  "activeProfileId": "$TEST_PROFILE_ID",
  "language": "en_US",
  "firstLaunchComplete": true,
  "profiles": [
    {
      "id": "$TEST_PROFILE_ID",
      "type": "client",
      "callsign": "$TEST_CALLSIGN",
      "nickname": "Test User",
      "description": "Test profile for API testing",
      "npub": "$TEST_NPUB",
      "nsec": "$TEST_NSEC",
      "useExtension": false,
      "preferredColor": "blue",
      "createdAt": "$(date -Iseconds)",
      "isActive": true
    }
  ]
}
EOF

# Create a test chat collection
COLLECTION_DIR="$TEMP_DIR/devices/$TEST_CALLSIGN/test-collection"
mkdir -p "$COLLECTION_DIR/extra"
mkdir -p "$COLLECTION_DIR/main/$(date +%Y)/files"

# Generate test NOSTR keys (using openssl for simplicity)
# This creates a 32-byte private key
PRIVATE_KEY_HEX=$(openssl rand -hex 32)

# For the public key, we'd need secp256k1 - for now use a placeholder npub
# The actual test will generate its own keys
TEST_NPUB="npub1test000000000000000000000000000000000000000000000000test"

# Create security.json with test admin
cat > "$COLLECTION_DIR/extra/security.json" << EOF
{
  "version": "1.0",
  "admin": "$TEST_NPUB",
  "moderators": {}
}
EOF

# Create channels.json with public and private rooms
cat > "$COLLECTION_DIR/extra/channels.json" << EOF
{
  "version": "1.0",
  "channels": [
    {
      "id": "main",
      "type": "main",
      "name": "Main Chat",
      "folder": "main",
      "participants": ["*"],
      "description": "Public chat room",
      "created": "$(date -Iseconds)",
      "config": {
        "id": "main",
        "name": "Main Chat",
        "visibility": "PUBLIC",
        "readonly": false
      }
    },
    {
      "id": "private-room",
      "type": "group",
      "name": "Private Room",
      "folder": "private-room",
      "participants": ["$TEST_CALLSIGN"],
      "description": "Private room for owner only",
      "created": "$(date -Iseconds)",
      "config": {
        "id": "private-room",
        "name": "Private Room",
        "visibility": "PRIVATE",
        "readonly": false
      }
    }
  ]
}
EOF

# Create participants.json
cat > "$COLLECTION_DIR/extra/participants.json" << EOF
{
  "version": "1.0",
  "participants": {
    "$TEST_CALLSIGN": {
      "callsign": "$TEST_CALLSIGN",
      "npub": "$TEST_NPUB",
      "lastSeen": "$(date -Iseconds)"
    }
  }
}
EOF

# Create sample chat messages in main room
TODAY=$(date +%Y-%m-%d)
YEAR=$(date +%Y)
cat > "$COLLECTION_DIR/main/$YEAR/${TODAY}_chat.txt" << EOF
# MAIN: Main Chat from $TODAY

> $TODAY 10:00_00 -- $TEST_CALLSIGN
Hello from the public chat!
--> npub: $TEST_NPUB

> $TODAY 10:01_00 -- $TEST_CALLSIGN
This is a test message.
--> npub: $TEST_NPUB
EOF

# Create private room folder with sample messages
mkdir -p "$COLLECTION_DIR/private-room/files"
cat > "$COLLECTION_DIR/private-room/messages.txt" << EOF
# PRIVATE-ROOM: Private Room from $TODAY

> $TODAY 11:00_00 -- $TEST_CALLSIGN
This is a secret message in the private room!
--> npub: $TEST_NPUB

> $TODAY 11:01_00 -- $TEST_CALLSIGN
Only the owner should see this.
--> npub: $TEST_NPUB
EOF

# Create station_config.json
cat > "$TEMP_DIR/station_config.json" << EOF
{
  "version": "1.0",
  "stations": []
}
EOF

# NOTE: The chat collection we created above is at /devices/$TEST_CALLSIGN/test-collection
# but Geogram will create a new identity with a different callsign, and the chat directory
# must be at /devices/{NEW_CALLSIGN}/chat - so we can't pre-create it accurately.
# Instead, we wait for Geogram to create its own identity and then check if it auto-creates the chat.

echo "Test environment created"
echo "NOTE: Chat rooms will be created by Geogram during first launch"
echo ""

# Start Geogram
cd "$PROJECT_DIR/build/linux/x64/release/bundle"

if [ "$CLI_MODE" = true ]; then
    echo -e "${RED}CLI mode is interactive and not supported for automated testing.${NC}"
    echo "The CLI requires user input. For automated testing, use GUI mode (default)."
    echo ""
    echo "To run the CLI manually with HTTP API:"
    echo "  ./geogram_desktop --cli --port=$TEST_PORT --data-dir=<DIR> --http-api"
    echo ""
    echo "Then in the CLI, the HTTP API will be available at http://localhost:$TEST_PORT/"
    exit 1
else
    echo "Starting Geogram Desktop (GUI) on port $TEST_PORT..."
    # GUI mode: Run with all necessary flags
    ./geogram_desktop --port=$TEST_PORT --data-dir="$TEMP_DIR" --http-api --debug-api &
    GEOGRAM_PID=$!
fi

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
# The chat collection is created during deferred initialization which takes a few seconds
sleep 10

# Check API status
echo "Checking API status..."
curl -s "http://localhost:$TEST_PORT/api/" | head -c 200
echo ""
echo ""

# Run the tests
echo "=============================================="
echo "Running Chat API Tests"
echo "=============================================="
echo ""

cd "$PROJECT_DIR"
$DART_CMD run test/chat_api_test.dart --port=$TEST_PORT

TEST_RESULT=$?

echo ""
if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    echo ""
    echo "Note: Tests that require chat rooms may be skipped on a fresh install."
    echo "To test with existing rooms, run against a Geogram instance with a loaded chat collection."
else
    echo -e "${RED}Some tests failed${NC}"
fi

exit $TEST_RESULT
