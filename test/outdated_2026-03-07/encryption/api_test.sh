#!/bin/bash
#
# Encrypted Storage API Test
#
# Tests the encryption API endpoints against a running Geogram instance.
# Run this after starting Geogram with debug API enabled.
#
# Usage:
#   ./tests/encryption/api_test.sh [--port PORT]
#
# Default port: 3456

set -e

# Configuration
PORT="${1:-3456}"
if [ "$1" = "--port" ] && [ -n "$2" ]; then
    PORT="$2"
fi

BASE_URL="http://localhost:$PORT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    if [ -n "$2" ]; then
        echo -e "        ${YELLOW}Details: $2${NC}"
    fi
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

api_debug() {
    curl -s -X POST "$BASE_URL/api/debug" \
        -H "Content-Type: application/json" \
        -d "{\"action\": \"$1\"}"
}

# ============================================================
# Tests
# ============================================================

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "         Encrypted Storage API Test Suite"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
info "Target: $BASE_URL"
echo ""

# Check instance
section "CONNECTIVITY CHECK"

RESPONSE=$(curl -s "$BASE_URL/api/status" 2>/dev/null || echo '{"error":"connection failed"}')
CALLSIGN=$(echo "$RESPONSE" | jq -r '.callsign // empty' 2>/dev/null)

if [ -n "$CALLSIGN" ]; then
    pass "Instance running: $CALLSIGN"
else
    fail "Cannot connect to instance" "$RESPONSE"
    echo ""
    echo "Make sure Geogram is running on port $PORT with HTTP API enabled."
    exit 1
fi

# Check debug API
RESPONSE=$(curl -s "$BASE_URL/api/debug" 2>/dev/null || echo '{"error":"connection failed"}')
if echo "$RESPONSE" | jq -e '.actions' > /dev/null 2>&1; then
    pass "Debug API enabled"
else
    fail "Debug API disabled or not accessible"
    echo ""
    echo "Enable Debug API in Settings > Security > Debug API"
    exit 1
fi

# Initial status
section "INITIAL STATUS"

RESPONSE=$(api_debug "encrypt_storage_status")
ENABLED=$(echo "$RESPONSE" | jq -r '.enabled // "unknown"')
HAS_NSEC=$(echo "$RESPONSE" | jq -r '.has_nsec // false')
ARCHIVE_PATH=$(echo "$RESPONSE" | jq -r '.archive_path // empty')

info "Current status: enabled=$ENABLED, has_nsec=$HAS_NSEC"

if [ "$HAS_NSEC" = "true" ]; then
    pass "Profile has nsec (encryption key available)"
else
    fail "Profile missing nsec (encryption requires NOSTR secret key)"
    echo ""
    echo "Add nsec to your profile in Settings > Profile to use encryption."
    exit 1
fi

# Store initial state
INITIAL_ENABLED="$ENABLED"

# If already encrypted, test disable first
if [ "$ENABLED" = "true" ]; then
    info "Profile is currently encrypted - will test disable then re-enable"

    section "DISABLE ENCRYPTION (to establish clean state)"

    RESPONSE=$(api_debug "encrypt_storage_disable")
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
    FILES=$(echo "$RESPONSE" | jq -r '.files_processed // 0')

    if [ "$SUCCESS" = "true" ]; then
        pass "Disabled encryption ($FILES files extracted)"
    else
        ERROR=$(echo "$RESPONSE" | jq -r '.error // "unknown"')
        fail "Failed to disable encryption: $ERROR"
    fi

    # Verify status
    RESPONSE=$(api_debug "encrypt_storage_status")
    ENABLED=$(echo "$RESPONSE" | jq -r '.enabled // true')

    if [ "$ENABLED" = "false" ]; then
        pass "Status confirms: enabled=false"
    else
        fail "Status should show enabled=false"
    fi
fi

# Test enable encryption
section "ENABLE ENCRYPTION"

RESPONSE=$(api_debug "encrypt_storage_enable")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
FILES=$(echo "$RESPONSE" | jq -r '.files_processed // 0')
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

if [ "$SUCCESS" = "true" ]; then
    pass "Enabled encryption ($FILES files encrypted)"
else
    fail "Failed to enable encryption: $ERROR"
    echo "Response: $RESPONSE"
fi

# Verify status after enable
RESPONSE=$(api_debug "encrypt_storage_status")
ENABLED=$(echo "$RESPONSE" | jq -r '.enabled // false')
ARCHIVE_PATH=$(echo "$RESPONSE" | jq -r '.archive_path // empty')
TOTAL_SIZE=$(echo "$RESPONSE" | jq -r '.total_size // 0')

if [ "$ENABLED" = "true" ]; then
    pass "Status shows enabled: true"
else
    fail "Status should show enabled: true" "got: $ENABLED"
fi

if [ -n "$ARCHIVE_PATH" ] && [ "$ARCHIVE_PATH" != "null" ]; then
    pass "Archive path reported: $ARCHIVE_PATH"
    info "Archive size: $TOTAL_SIZE bytes"
else
    fail "No archive path in status"
fi

# Test double enable (should fail)
section "DOUBLE ENABLE (should fail)"

RESPONSE=$(api_debug "encrypt_storage_enable")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // true')
CODE=$(echo "$RESPONSE" | jq -r '.code // empty')

if [ "$SUCCESS" = "false" ] && [ "$CODE" = "ALREADY_ENCRYPTED" ]; then
    pass "Double enable correctly rejected: ALREADY_ENCRYPTED"
else
    fail "Double enable should return ALREADY_ENCRYPTED" "got: success=$SUCCESS, code=$CODE"
fi

# Test disable encryption
section "DISABLE ENCRYPTION"

RESPONSE=$(api_debug "encrypt_storage_disable")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
FILES=$(echo "$RESPONSE" | jq -r '.files_processed // 0')
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

if [ "$SUCCESS" = "true" ]; then
    pass "Disabled encryption ($FILES files decrypted)"
else
    fail "Failed to disable encryption: $ERROR"
fi

# Verify status after disable
RESPONSE=$(api_debug "encrypt_storage_status")
ENABLED=$(echo "$RESPONSE" | jq -r '.enabled // true')
ARCHIVE_PATH=$(echo "$RESPONSE" | jq -r '.archive_path // "exists"')

if [ "$ENABLED" = "false" ]; then
    pass "Status shows enabled: false"
else
    fail "Status should show enabled: false" "got: $ENABLED"
fi

if [ "$ARCHIVE_PATH" = "null" ] || [ -z "$ARCHIVE_PATH" ]; then
    pass "Archive path is null (removed)"
else
    fail "Archive path should be null" "got: $ARCHIVE_PATH"
fi

# Test double disable (should fail)
section "DOUBLE DISABLE (should fail)"

RESPONSE=$(api_debug "encrypt_storage_disable")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // true')
CODE=$(echo "$RESPONSE" | jq -r '.code // empty')

if [ "$SUCCESS" = "false" ] && [ "$CODE" = "NOT_ENCRYPTED" ]; then
    pass "Double disable correctly rejected: NOT_ENCRYPTED"
else
    fail "Double disable should return NOT_ENCRYPTED" "got: success=$SUCCESS, code=$CODE"
fi

# Restore initial state if it was encrypted
if [ "$INITIAL_ENABLED" = "true" ]; then
    section "RESTORE INITIAL STATE"
    info "Re-enabling encryption to restore original state..."

    RESPONSE=$(api_debug "encrypt_storage_enable")
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')

    if [ "$SUCCESS" = "true" ]; then
        pass "Restored encrypted state"
    else
        fail "Failed to restore encrypted state"
    fi
fi

# Summary
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
