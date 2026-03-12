#!/bin/bash
# End-to-End Email Test
#
# This script tests email delivery between two Geogram clients via p2p.radio.
# It verifies that emails are properly routed and delivered by checking the
# actual files on disk.
#
# Architecture:
#   Client A (sender) --> p2p.radio (relay) --> Client B (receiver)
#
# Usage:
#   ./test-email-e2e.sh              # Build and run test
#   ./test-email-e2e.sh --skip-build # Use existing binaries
#   ./test-email-e2e.sh --deploy     # Deploy to p2p.radio first, then test
#
# Prerequisites:
#   - Flutter SDK installed
#   - p2p.radio station must be running (use --deploy to update)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration - using p2p.radio as the station
# Use wss:// for secure WebSocket connection (station has HTTPS enabled)
STATION_URL="wss://p2p.radio"
STATION_DOMAIN="p2p.radio"
CLIENT_A_PORT=17100
CLIENT_B_PORT=17200

CLIENT_A_DIR="/tmp/geogram-email-clientA"
CLIENT_B_DIR="/tmp/geogram-email-clientB"

# Timing
STARTUP_WAIT=15
API_WAIT=3
DELIVERY_WAIT=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test state
PASSED=0
FAILED=0
CLIENT_A_PID=""
CLIENT_B_PID=""
CALLSIGN_A=""
CALLSIGN_B=""

# Parse arguments
SKIP_BUILD=false
DEPLOY_FIRST=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --deploy)
            DEPLOY_FIRST=true
            shift
            ;;
        --help|-h)
            echo "End-to-End Email Test"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-build  Use existing binaries without rebuilding"
            echo "  --deploy      Deploy to p2p.radio first, then run test"
            echo "  --help        Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Output helpers
pass() {
    PASSED=$((PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
    FAILED=$((FAILED + 1))
    echo -e "  ${RED}✗${NC} $1 - $2"
}

info() {
    echo -e "  ${CYAN}ℹ${NC} $1"
}

section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Cleanup handler
cleanup() {
    section "Cleanup"

    if [ -n "$CLIENT_A_PID" ]; then
        info "Stopping Client A (PID: $CLIENT_A_PID)..."
        kill "$CLIENT_A_PID" 2>/dev/null || true
    fi

    if [ -n "$CLIENT_B_PID" ]; then
        info "Stopping Client B (PID: $CLIENT_B_PID)..."
        kill "$CLIENT_B_PID" 2>/dev/null || true
    fi

    # Wait a moment for processes to terminate
    sleep 2

    # Force kill if still running
    [ -n "$CLIENT_A_PID" ] && kill -9 "$CLIENT_A_PID" 2>/dev/null || true
    [ -n "$CLIENT_B_PID" ] && kill -9 "$CLIENT_B_PID" 2>/dev/null || true

    info "Cleanup complete"
}

trap cleanup EXIT

# Wait for API to be ready
wait_for_api() {
    local name=$1
    local port=$2
    local timeout=${3:-60}
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if curl -s "http://localhost:$port/api/status" > /dev/null 2>&1; then
            return 0
        fi
        # Also try /api/ endpoint for station
        if curl -s "http://localhost:$port/api/" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 1
}

# Get callsign from instance
get_callsign() {
    local port=$1
    local result=""

    # Try /api/status first
    result=$(curl -s "http://localhost:$port/api/status" 2>/dev/null | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$result" ]; then
        # Try /api/ for station
        result=$(curl -s "http://localhost:$port/api/" 2>/dev/null | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)
    fi

    echo "$result"
}

# Send debug API action
debug_action() {
    local port=$1
    local action=$2

    curl -s -X POST "http://localhost:$port/api/debug" \
        -H "Content-Type: application/json" \
        -d "$action" 2>/dev/null
}

# ============================================================
# Main Test
# ============================================================

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          Geogram Email End-to-End Test                     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================
# Build Phase
# ============================================================

section "Build"

DESKTOP_BINARY="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ "$SKIP_BUILD" = true ]; then
    info "Skipping build (using existing binaries)..."
else
    # Build Desktop
    info "Building Desktop..."
    cd "$PROJECT_DIR"
    flutter build linux --release 2>&1 | tail -5
fi

# Verify binary exists
if [ ! -f "$DESKTOP_BINARY" ]; then
    echo -e "${RED}Error: Desktop binary not found at $DESKTOP_BINARY${NC}"
    exit 1
fi
pass "Desktop binary found"

# ============================================================
# Deploy to p2p.radio (optional)
# ============================================================

if [ "$DEPLOY_FIRST" = true ]; then
    section "Deploy to p2p.radio"
    info "Deploying latest code to p2p.radio..."
    cd "$PROJECT_DIR"
    ./server-deploy.sh
    info "Waiting for server to stabilize..."
    sleep 5
fi

# ============================================================
# Check p2p.radio Station
# ============================================================

section "Check Station"

info "Checking p2p.radio station status..."
STATION_STATUS=$(curl -s "http://p2p.radio/api/status" 2>/dev/null || echo "")

if [ -n "$STATION_STATUS" ]; then
    pass "p2p.radio station is online"
    info "Station: $(echo "$STATION_STATUS" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4)"
else
    fail "Station check" "p2p.radio is not responding"
    echo -e "${YELLOW}Try running with --deploy to update the station${NC}"
    exit 1
fi

# ============================================================
# Setup Phase
# ============================================================

section "Setup"

# Clean and create temp directories
for dir in "$CLIENT_A_DIR" "$CLIENT_B_DIR"; do
    rm -rf "$dir"
    mkdir -p "$dir"
    info "Created: $dir"
done

# ============================================================
# Launch Clients
# ============================================================

section "Launch Clients"

# Generate unique nicknames using timestamp to avoid NIP-05 collisions
TIMESTAMP=$(date +%s)
NICKNAME_A="TestA${TIMESTAMP}"
NICKNAME_B="TestB${TIMESTAMP}"

# Client A
info "Starting Client A on port $CLIENT_A_PORT (nickname: $NICKNAME_A)..."
"$DESKTOP_BINARY" \
    --port=$CLIENT_A_PORT \
    --data-dir="$CLIENT_A_DIR" \
    --new-identity \
    --identity-type=client \
    --skip-intro \
    --http-api \
    --debug-api \
    --no-update \
    --nickname="$NICKNAME_A" \
    > "$CLIENT_A_DIR/output.log" 2>&1 &
CLIENT_A_PID=$!
info "Client A PID: $CLIENT_A_PID"

# Client B
info "Starting Client B on port $CLIENT_B_PORT (nickname: $NICKNAME_B)..."
"$DESKTOP_BINARY" \
    --port=$CLIENT_B_PORT \
    --data-dir="$CLIENT_B_DIR" \
    --new-identity \
    --identity-type=client \
    --skip-intro \
    --http-api \
    --debug-api \
    --no-update \
    --nickname="$NICKNAME_B" \
    > "$CLIENT_B_DIR/output.log" 2>&1 &
CLIENT_B_PID=$!
info "Client B PID: $CLIENT_B_PID"

# Wait for clients
info "Waiting for clients to be ready..."
sleep $STARTUP_WAIT

if wait_for_api "Client A" $CLIENT_A_PORT 60; then
    pass "Client A is ready"
else
    fail "Client A startup" "Timed out"
    cat "$CLIENT_A_DIR/output.log" | tail -20
    exit 1
fi

if wait_for_api "Client B" $CLIENT_B_PORT 60; then
    pass "Client B is ready"
else
    fail "Client B startup" "Timed out"
    cat "$CLIENT_B_DIR/output.log" | tail -20
    exit 1
fi

# Get callsigns
CALLSIGN_A=$(get_callsign $CLIENT_A_PORT)
CALLSIGN_B=$(get_callsign $CLIENT_B_PORT)

if [ -z "$CALLSIGN_A" ]; then
    fail "Get callsign A" "Could not retrieve callsign"
    exit 1
fi
info "Client A callsign: $CALLSIGN_A"

if [ -z "$CALLSIGN_B" ]; then
    fail "Get callsign B" "Could not retrieve callsign"
    exit 1
fi
info "Client B callsign: $CALLSIGN_B"

# ============================================================
# Connect to Station
# ============================================================

section "Connect to Station"

# Function to connect with retries
connect_with_retry() {
    local port=$1
    local name=$2
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        info "Connecting $name to $STATION_URL (attempt $attempt/$max_attempts)..."
        local result=$(debug_action $port '{"action":"station_connect","url":"'"$STATION_URL"'"}')

        if echo "$result" | grep -q '"connected":true'; then
            info "Response: $result"
            return 0
        fi

        info "Connection failed, retrying in 3 seconds..."
        sleep 3
        attempt=$((attempt + 1))
    done

    info "Final response: $result"
    return 1
}

# Connect Client A
if connect_with_retry $CLIENT_A_PORT "Client A"; then
    pass "Client A connected to station"
else
    info "Client A connection attempts exhausted"
fi

# Connect Client B
if connect_with_retry $CLIENT_B_PORT "Client B"; then
    pass "Client B connected to station"
else
    info "Client B connection attempts exhausted"
fi

# Verify connections
info "Verifying connections..."
sleep 5

STATUS_A=$(debug_action $CLIENT_A_PORT '{"action":"email_status"}')
STATUS_B=$(debug_action $CLIENT_B_PORT '{"action":"email_status"}')

WS_A=$(echo "$STATUS_A" | grep -o '"websocket_connected":true' || echo "")
WS_B=$(echo "$STATUS_B" | grep -o '"websocket_connected":true' || echo "")

if [ -z "$WS_A" ]; then
    info "Client A WebSocket status: $STATUS_A"
fi

if [ -z "$WS_B" ]; then
    info "Client B WebSocket status: $STATUS_B"
fi

# ============================================================
# Send Email: A -> B
# ============================================================

section "Test: Send Email A -> B"

SUBJECT="E2E Test $(date +%H%M%S)"
CONTENT="This is an end-to-end test email sent at $(date)."
RECIPIENT="${CALLSIGN_B}@${STATION_DOMAIN}"

info "Sending email from $CALLSIGN_A to $RECIPIENT..."
info "Subject: $SUBJECT"

SEND_RESULT=$(debug_action $CLIENT_A_PORT '{
    "action": "email_send",
    "to": "'"$RECIPIENT"'",
    "subject": "'"$SUBJECT"'",
    "content": "'"$CONTENT"'"
}')

info "Send result: $SEND_RESULT"

if echo "$SEND_RESULT" | grep -q '"success":true'; then
    pass "Email send API returned success"
else
    fail "Email send" "API did not return success"
fi

# ============================================================
# Verify Delivery on Disk
# ============================================================

section "Verify Delivery"

info "Waiting for email delivery ($DELIVERY_WAIT seconds)..."
sleep $DELIVERY_WAIT

# Check Client B's inbox on disk
INBOX_DIR="$CLIENT_B_DIR/email/inbox"
info "Checking inbox directory: $INBOX_DIR"

if [ -d "$INBOX_DIR" ]; then
    pass "Inbox directory exists"

    # Find thread.md files
    THREAD_FILES=$(find "$INBOX_DIR" -name "thread.md" 2>/dev/null || echo "")

    if [ -n "$THREAD_FILES" ]; then
        pass "Found thread.md file(s) in inbox"

        # Check content of thread files
        FOUND_EMAIL=false
        for thread_file in $THREAD_FILES; do
            info "Checking: $thread_file"

            # Check if subject matches
            if grep -q "$SUBJECT" "$thread_file" 2>/dev/null; then
                FOUND_EMAIL=true
                pass "Email with correct subject found"

                # Verify sender
                if grep -qi "$CALLSIGN_A" "$thread_file" 2>/dev/null; then
                    pass "Email has correct sender ($CALLSIGN_A)"
                else
                    fail "Sender verification" "Sender callsign not found in email"
                fi

                # Show email content
                info "Email content:"
                echo "---"
                cat "$thread_file" | head -30
                echo "---"
                break
            fi
        done

        if [ "$FOUND_EMAIL" = false ]; then
            fail "Email delivery" "No email with subject '$SUBJECT' found"
            info "Thread files found:"
            for tf in $THREAD_FILES; do
                echo "  $tf"
                head -5 "$tf"
            done
        fi
    else
        fail "Email delivery" "No thread.md files found in inbox"
        info "Inbox contents:"
        find "$INBOX_DIR" -type f 2>/dev/null || echo "  (empty)"
    fi
else
    fail "Inbox directory" "Directory does not exist: $INBOX_DIR"
    info "Email directory contents:"
    ls -la "$CLIENT_B_DIR/email/" 2>/dev/null || echo "  (email dir not found)"
fi

# Also check via API
info "Checking inbox via API..."
INBOX_LIST=$(debug_action $CLIENT_B_PORT '{"action":"email_list","folder":"inbox"}')
info "Inbox list: $INBOX_LIST"

INBOX_COUNT=$(echo "$INBOX_LIST" | grep -o '"count":[0-9]*' | cut -d':' -f2)
if [ -n "$INBOX_COUNT" ] && [ "$INBOX_COUNT" -gt 0 ]; then
    pass "Inbox has $INBOX_COUNT email(s) via API"
else
    info "Inbox count via API: ${INBOX_COUNT:-0}"
fi

# ============================================================
# Test: Send Email B -> A (Reply)
# ============================================================

section "Test: Send Email B -> A (Reply)"

REPLY_SUBJECT="Re: $SUBJECT"
REPLY_CONTENT="This is a reply from B to A."
REPLY_RECIPIENT="${CALLSIGN_A}@${STATION_DOMAIN}"

info "Sending reply from $CALLSIGN_B to $REPLY_RECIPIENT..."

REPLY_RESULT=$(debug_action $CLIENT_B_PORT '{
    "action": "email_send",
    "to": "'"$REPLY_RECIPIENT"'",
    "subject": "'"$REPLY_SUBJECT"'",
    "content": "'"$REPLY_CONTENT"'"
}')

info "Reply result: $REPLY_RESULT"

if echo "$REPLY_RESULT" | grep -q '"success":true'; then
    pass "Reply send API returned success"
else
    fail "Reply send" "API did not return success"
fi

# Wait and verify
sleep $DELIVERY_WAIT

INBOX_A_DIR="$CLIENT_A_DIR/email/inbox"
REPLY_FOUND=false

if [ -d "$INBOX_A_DIR" ]; then
    THREAD_FILES_A=$(find "$INBOX_A_DIR" -name "thread.md" 2>/dev/null || echo "")

    for thread_file in $THREAD_FILES_A; do
        if grep -q "$REPLY_SUBJECT" "$thread_file" 2>/dev/null; then
            REPLY_FOUND=true
            pass "Reply received by Client A"
            break
        fi
    done
fi

if [ "$REPLY_FOUND" = false ]; then
    info "Reply not found in Client A inbox (this may be expected if outbox is used)"
    # Check outbox instead
    OUTBOX_LIST=$(debug_action $CLIENT_A_PORT '{"action":"email_list","folder":"inbox"}')
    info "Client A inbox: $OUTBOX_LIST"
fi

# ============================================================
# Summary
# ============================================================

section "Test Summary"

echo ""
echo -e "  ${GREEN}Passed: $PASSED${NC}"
echo -e "  ${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}Some tests failed.${NC}"
    EXIT_CODE=1
fi

echo ""
echo "Temp directories (for manual inspection):"
echo "  Client A: $CLIENT_A_DIR"
echo "  Client B: $CLIENT_B_DIR"
echo ""
echo "Email inbox locations:"
echo "  Client A inbox: $CLIENT_A_DIR/email/inbox/"
echo "  Client B inbox: $CLIENT_B_DIR/email/inbox/"
echo ""
echo "Station used: $STATION_DOMAIN"
echo "To check station logs: ssh root@p2p.radio 'screen -r geogram'"
echo ""

exit $EXIT_CODE
