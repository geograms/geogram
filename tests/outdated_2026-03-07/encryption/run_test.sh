#!/bin/bash
# Encrypted Storage Integration Test
#
# This script:
# 1. Cleans up any previous test directory
# 2. Creates a fresh temp directory with test files
# 3. Launches a Geogram instance with auto-generated identity
# 4. Runs encryption API tests
# 5. Cleans up (kills instance)
#
# Usage:
#   ./tests/encryption/run_test.sh              # Run full test
#   ./tests/encryption/run_test.sh --skip-build # Skip rebuilding
#   ./tests/encryption/run_test.sh --keep       # Keep instance running after test
#
# Default port: 13457
# Temp directory: /tmp/geogram-encrypt-test

# Don't exit on error - we handle errors ourselves
# set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
PORT=13457
TEMP_DIR="/tmp/geogram-encrypt-test"
NICKNAME="EncryptTest"
SKIP_BUILD=false
KEEP_RUNNING=false
INSTANCE_PID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1${2:+ - $2}"; TESTS_FAILED=$((TESTS_FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

cleanup() {
    if [ -n "$INSTANCE_PID" ] && kill -0 "$INSTANCE_PID" 2>/dev/null; then
        if [ "$KEEP_RUNNING" = true ]; then
            echo ""
            log "Instance still running (--keep specified)"
            log "  PID: $INSTANCE_PID"
            log "  API: http://localhost:$PORT/api/status"
            log "  Data: $TEMP_DIR"
            log "  To stop: kill $INSTANCE_PID"
        else
            log "Stopping instance (PID: $INSTANCE_PID)..."
            kill "$INSTANCE_PID" 2>/dev/null || true
            wait "$INSTANCE_PID" 2>/dev/null || true
        fi
    fi
}

trap cleanup EXIT

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build) SKIP_BUILD=true; shift ;;
        --keep) KEEP_RUNNING=true; shift ;;
        --port=*) PORT="${1#*=}"; shift ;;
        --help|-h)
            echo "Encrypted Storage Integration Test"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-build    Skip rebuilding the app"
            echo "  --keep          Keep instance running after test"
            echo "  --port=PORT     Use custom port (default: $PORT)"
            echo "  --help          Show this help"
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "         Encrypted Storage Integration Test"
echo "════════════════════════════════════════════════════════════════════════"
echo ""

# Find flutter
FLUTTER_CMD=""
if command -v flutter &> /dev/null; then
    FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/flutter/bin/flutter"
elif [ -f "$HOME/dev/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/dev/flutter/bin/flutter"
else
    echo -e "${RED}Error: flutter not found${NC}"
    exit 1
fi

# Build if needed
BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"
LIBAPP_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/lib/libapp.so"

needs_rebuild() {
    [ ! -f "$BINARY_PATH" ] || [ ! -f "$LIBAPP_PATH" ] && return 0
    [ -n "$(find "$PROJECT_DIR/lib" -name "*.dart" -newer "$LIBAPP_PATH" 2>/dev/null | head -1)" ] && return 0
    return 1
}

if [ "$SKIP_BUILD" = true ]; then
    log "Skipping build (--skip-build)"
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}Error: Binary not found. Run without --skip-build${NC}"
        exit 1
    fi
elif needs_rebuild; then
    log "Building Geogram..."
    cd "$PROJECT_DIR"
    $FLUTTER_CMD build linux --release
    echo -e "${GREEN}✓ Build complete${NC}"
else
    echo -e "${GREEN}✓ Binary up-to-date${NC}"
fi

# Clean up and create temp directory
section "SETUP"

if [ -d "$TEMP_DIR" ]; then
    log "Removing previous test directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
fi
mkdir -p "$TEMP_DIR"
log "Created temp directory: $TEMP_DIR"

# Create test files in the profile folder (will be created after instance starts)
# We'll create them after we know the callsign

# Start instance
section "STARTING INSTANCE"

log "Launching Geogram on port $PORT..."
"$BINARY_PATH" \
    --port=$PORT \
    --data-dir="$TEMP_DIR" \
    --new-identity \
    --nickname="$NICKNAME" \
    --skip-intro \
    --http-api \
    --debug-api \
    > "$TEMP_DIR/geogram.log" 2>&1 &
INSTANCE_PID=$!
log "Started with PID: $INSTANCE_PID"

# Wait for API to be ready
log "Waiting for API..."
for i in {1..30}; do
    if curl -s "http://localhost:$PORT/api/status" > /dev/null 2>&1; then
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

# Get instance info
STATUS=$(curl -s "http://localhost:$PORT/api/status" 2>/dev/null || echo "{}")
CALLSIGN=$(echo "$STATUS" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
VERSION=$(echo "$STATUS" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)

if [ -z "$CALLSIGN" ]; then
    echo -e "${RED}Error: Instance failed to start${NC}"
    cat "$TEMP_DIR/geogram.log"
    exit 1
fi

echo -e "${GREEN}✓ Instance ready: $CALLSIGN (v$VERSION)${NC}"

# Create test files in the profile directory
PROFILE_DIR="$TEMP_DIR/devices/$CALLSIGN"
log "Creating test files in $PROFILE_DIR"
mkdir -p "$PROFILE_DIR/chat" "$PROFILE_DIR/work" "$PROFILE_DIR/contacts"
echo '{"test": "chat_data", "messages": [1, 2, 3]}' > "$PROFILE_DIR/chat/messages.json"
echo '{"contacts": ["alice", "bob"]}' > "$PROFILE_DIR/contacts/list.json"
echo 'This is a test document for encryption.' > "$PROFILE_DIR/work/document.txt"
echo 'Binary test: §±²³µ¶·' > "$PROFILE_DIR/work/binary.dat"

# Count files
FILE_COUNT=$(find "$PROFILE_DIR" -type f | wc -l)
log "Created $FILE_COUNT test files"

# ============================================================
# RUN TESTS
# ============================================================

section "ENCRYPTION STATUS"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action": "encrypt_storage_status"}')

ENABLED=$(echo "$RESPONSE" | grep -o '"enabled":[^,}]*' | cut -d':' -f2)
HAS_NSEC=$(echo "$RESPONSE" | grep -o '"has_nsec":[^,}]*' | cut -d':' -f2)

log "Status: enabled=$ENABLED, has_nsec=$HAS_NSEC"

if [ "$HAS_NSEC" = "true" ]; then
    pass "Profile has nsec configured"
else
    fail "Profile missing nsec" "Encryption requires NOSTR key"
    echo -e "${RED}Cannot continue without nsec${NC}"
    exit 1
fi

if [ "$ENABLED" = "false" ]; then
    pass "Initially using folder storage"
else
    fail "Should start with folder storage"
fi

# Verify profile folder exists
if [ -d "$PROFILE_DIR" ]; then
    pass "Profile folder exists: $PROFILE_DIR"
else
    fail "Profile folder missing"
fi

section "ENABLE ENCRYPTION"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action": "encrypt_storage_enable"}')

SUCCESS=$(echo "$RESPONSE" | grep -o '"success":[^,}]*' | cut -d':' -f2)
FILES=$(echo "$RESPONSE" | grep -o '"files_processed":[^,}]*' | cut -d':' -f2)
ERROR=$(echo "$RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)

if [ "$SUCCESS" = "true" ]; then
    pass "Encryption enabled ($FILES files processed)"
else
    fail "Failed to enable encryption" "$ERROR"
    echo "Response: $RESPONSE"
fi

# Verify archive exists
ARCHIVE_PATH="$TEMP_DIR/devices/$CALLSIGN.sqlite"
if [ -f "$ARCHIVE_PATH" ]; then
    SIZE=$(stat -c%s "$ARCHIVE_PATH" 2>/dev/null || stat -f%z "$ARCHIVE_PATH" 2>/dev/null)
    pass "Archive created: $ARCHIVE_PATH ($SIZE bytes)"
else
    fail "Archive not created"
    ls -la "$TEMP_DIR/devices/"
fi

# Verify profile folder removed
if [ ! -d "$PROFILE_DIR" ]; then
    pass "Profile folder removed after encryption"
else
    fail "Profile folder still exists after encryption"
fi

# Check status
RESPONSE=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action": "encrypt_storage_status"}')

ENABLED=$(echo "$RESPONSE" | grep -o '"enabled":[^,}]*' | cut -d':' -f2)
if [ "$ENABLED" = "true" ]; then
    pass "Status shows enabled: true"
else
    fail "Status should show enabled: true"
fi

section "DOUBLE ENABLE (should fail)"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action": "encrypt_storage_enable"}')

SUCCESS=$(echo "$RESPONSE" | grep -o '"success":[^,}]*' | cut -d':' -f2)
CODE=$(echo "$RESPONSE" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)

if [ "$SUCCESS" = "false" ] && [ "$CODE" = "ALREADY_ENCRYPTED" ]; then
    pass "Double enable rejected: ALREADY_ENCRYPTED"
else
    fail "Should reject with ALREADY_ENCRYPTED" "got: success=$SUCCESS, code=$CODE"
fi

section "DISABLE ENCRYPTION"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action": "encrypt_storage_disable"}')

SUCCESS=$(echo "$RESPONSE" | grep -o '"success":[^,}]*' | cut -d':' -f2)
FILES=$(echo "$RESPONSE" | grep -o '"files_processed":[^,}]*' | cut -d':' -f2)
ERROR=$(echo "$RESPONSE" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)

if [ "$SUCCESS" = "true" ]; then
    pass "Encryption disabled ($FILES files extracted)"
else
    fail "Failed to disable encryption" "$ERROR"
fi

# Verify profile folder restored
if [ -d "$PROFILE_DIR" ]; then
    pass "Profile folder restored"
else
    fail "Profile folder not restored"
fi

# Verify archive removed
if [ ! -f "$ARCHIVE_PATH" ]; then
    pass "Archive file removed"
else
    fail "Archive file still exists"
fi

# Verify data integrity
section "DATA INTEGRITY"

if [ -f "$PROFILE_DIR/chat/messages.json" ]; then
    CONTENT=$(cat "$PROFILE_DIR/chat/messages.json")
    if echo "$CONTENT" | grep -q '"test"'; then
        pass "chat/messages.json restored correctly"
    else
        fail "chat/messages.json content corrupted"
    fi
else
    fail "chat/messages.json not restored"
fi

if [ -f "$PROFILE_DIR/work/document.txt" ]; then
    CONTENT=$(cat "$PROFILE_DIR/work/document.txt")
    if [ "$CONTENT" = "This is a test document for encryption." ]; then
        pass "work/document.txt restored correctly"
    else
        fail "work/document.txt content corrupted"
    fi
else
    fail "work/document.txt not restored"
fi

section "DOUBLE DISABLE (should fail)"

RESPONSE=$(curl -s -X POST "http://localhost:$PORT/api/debug" \
    -H "Content-Type: application/json" \
    -d '{"action": "encrypt_storage_disable"}')

SUCCESS=$(echo "$RESPONSE" | grep -o '"success":[^,}]*' | cut -d':' -f2)
CODE=$(echo "$RESPONSE" | grep -o '"code":"[^"]*"' | cut -d'"' -f4)

if [ "$SUCCESS" = "false" ] && [ "$CODE" = "NOT_ENCRYPTED" ]; then
    pass "Double disable rejected: NOT_ENCRYPTED"
else
    fail "Should reject with NOT_ENCRYPTED" "got: success=$SUCCESS, code=$CODE"
fi

# ============================================================
# SUMMARY
# ============================================================

echo ""
echo "════════════════════════════════════════════════════════════════════════"
if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "         ${GREEN}ALL TESTS PASSED! ($TESTS_PASSED/$TESTS_RUN)${NC}"
else
    echo -e "         ${YELLOW}TESTS: $TESTS_PASSED passed, $TESTS_FAILED failed${NC}"
fi
echo "════════════════════════════════════════════════════════════════════════"
echo ""

exit $TESTS_FAILED
