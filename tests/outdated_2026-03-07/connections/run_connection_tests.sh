#!/bin/bash
#
# Connection Test Suite: BLE, LAN, Internet (Station)
#
# Tests connectivity between two Android devices via three transport methods.
# Requires both devices running Geogram with debug API enabled.
#
# Usage:
#   ./tests/connections/run_connection_tests.sh [DEVICE_A_IP:PORT] [DEVICE_B_IP:PORT]
#
# Default devices:
#   Device A: 192.168.178.36:3456
#   Device B: 192.168.178.28:3456

set -e

# Configuration
DEVICE_A="${1:-192.168.178.36:3456}"
DEVICE_B="${2:-192.168.178.28:3456}"
BASE_A="http://$DEVICE_A"
BASE_B="http://$DEVICE_B"

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
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    if [ -n "$2" ]; then
        echo -e "        ${YELLOW}Details: $2${NC}"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

api_debug() {
    local base="$1"
    local action="$2"
    local extra_params="$3"
    if [ -n "$extra_params" ]; then
        curl -s -X POST "$base/api/debug" \
            -H "Content-Type: application/json" \
            -d "{\"action\": \"$action\", $extra_params}" 2>/dev/null || echo '{"error":"connection failed"}'
    else
        curl -s -X POST "$base/api/debug" \
            -H "Content-Type: application/json" \
            -d "{\"action\": \"$action\"}" 2>/dev/null || echo '{"error":"connection failed"}'
    fi
}

# Check jq dependency
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required. Install with: sudo apt install jq"
    exit 1
fi

# ============================================================
# Test Suite
# ============================================================

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "         Connection Test Suite: BLE, LAN, Internet"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
info "Device A: $BASE_A"
info "Device B: $BASE_B"
echo ""

# ── Phase 1: Basic LAN Reachability ──────────────────────────

section "PHASE 1: Basic LAN Reachability"

RESPONSE_A=$(curl -s "$BASE_A/api/status" 2>/dev/null || echo '{"error":"connection failed"}')
CALLSIGN_A=$(echo "$RESPONSE_A" | jq -r '.callsign // empty' 2>/dev/null)

if [ -n "$CALLSIGN_A" ]; then
    pass "Device A reachable: $CALLSIGN_A"
else
    fail "Cannot reach Device A at $BASE_A" "$RESPONSE_A"
    echo ""
    echo "Make sure Device A is running Geogram with HTTP API enabled."
    exit 1
fi

RESPONSE_B=$(curl -s "$BASE_B/api/status" 2>/dev/null || echo '{"error":"connection failed"}')
CALLSIGN_B=$(echo "$RESPONSE_B" | jq -r '.callsign // empty' 2>/dev/null)

if [ -n "$CALLSIGN_B" ]; then
    pass "Device B reachable: $CALLSIGN_B"
else
    fail "Cannot reach Device B at $BASE_B" "$RESPONSE_B"
    echo ""
    echo "Make sure Device B is running Geogram with HTTP API enabled."
    exit 1
fi

info "Callsigns: A=$CALLSIGN_A, B=$CALLSIGN_B"

# ── Phase 2: Debug API Check ─────────────────────────────────

section "PHASE 2: Debug API Check"

RESPONSE=$(curl -s "$BASE_A/api/debug" 2>/dev/null || echo '{"error":"connection failed"}')
if echo "$RESPONSE" | jq -e '.available_actions' > /dev/null 2>&1; then
    pass "Debug API enabled on Device A"
else
    fail "Debug API disabled on Device A"
    echo "  Enable Debug API in Settings > Security > Debug API"
    exit 1
fi

RESPONSE=$(curl -s "$BASE_B/api/debug" 2>/dev/null || echo '{"error":"connection failed"}')
if echo "$RESPONSE" | jq -e '.available_actions' > /dev/null 2>&1; then
    pass "Debug API enabled on Device B"
else
    fail "Debug API disabled on Device B"
    echo "  Enable Debug API in Settings > Security > Debug API"
    exit 1
fi

# ── Phase 3: Device Discovery ────────────────────────────────

section "PHASE 3: Device Discovery"

info "Triggering local_scan on both devices..."
api_debug "$BASE_A" "local_scan" > /dev/null
api_debug "$BASE_B" "local_scan" > /dev/null
sleep 3

# Check if A knows B
RESPONSE=$(api_debug "$BASE_A" "list_devices")
if echo "$RESPONSE" | jq -e ".devices[] | select(.callsign == \"$CALLSIGN_B\")" > /dev/null 2>&1; then
    pass "Device A knows Device B ($CALLSIGN_B)"
else
    warn "Device A does not know $CALLSIGN_B — attempting add_device"
    RESPONSE=$(api_debug "$BASE_A" "add_device" "\"callsign\": \"$CALLSIGN_B\", \"url\": \"$BASE_B\"")
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
    if [ "$SUCCESS" = "true" ]; then
        pass "Added Device B to Device A"
    else
        fail "Could not add Device B to Device A" "$(echo "$RESPONSE" | jq -r '.error // "unknown"')"
    fi
fi

# Check if B knows A
RESPONSE=$(api_debug "$BASE_B" "list_devices")
if echo "$RESPONSE" | jq -e ".devices[] | select(.callsign == \"$CALLSIGN_A\")" > /dev/null 2>&1; then
    pass "Device B knows Device A ($CALLSIGN_A)"
else
    warn "Device B does not know $CALLSIGN_A — attempting add_device"
    RESPONSE=$(api_debug "$BASE_B" "add_device" "\"callsign\": \"$CALLSIGN_A\", \"url\": \"$BASE_A\"")
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
    if [ "$SUCCESS" = "true" ]; then
        pass "Added Device A to Device B"
    else
        fail "Could not add Device A to Device B" "$(echo "$RESPONSE" | jq -r '.error // "unknown"')"
    fi
fi

# ── Phase 4: LAN Ping ────────────────────────────────────────

section "PHASE 4: LAN Ping"

# A → B via LAN
info "Pinging $CALLSIGN_B from Device A via LAN..."
RESPONSE=$(api_debug "$BASE_A" "device_ping" "\"callsign\": \"$CALLSIGN_B\", \"transport\": \"lan\"")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
TRANSPORT_USED=$(echo "$RESPONSE" | jq -r '.transport_used // "none"')
LATENCY=$(echo "$RESPONSE" | jq -r '.latency_ms // "?"')
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

if [ "$SUCCESS" = "true" ]; then
    pass "A→B LAN ping: ${LATENCY}ms via $TRANSPORT_USED"
else
    fail "A→B LAN ping failed" "$ERROR"
fi

# B → A via LAN
info "Pinging $CALLSIGN_A from Device B via LAN..."
RESPONSE=$(api_debug "$BASE_B" "device_ping" "\"callsign\": \"$CALLSIGN_A\", \"transport\": \"lan\"")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
TRANSPORT_USED=$(echo "$RESPONSE" | jq -r '.transport_used // "none"')
LATENCY=$(echo "$RESPONSE" | jq -r '.latency_ms // "?"')
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

if [ "$SUCCESS" = "true" ]; then
    pass "B→A LAN ping: ${LATENCY}ms via $TRANSPORT_USED"
else
    fail "B→A LAN ping failed" "$ERROR"
fi

# ── Phase 5: BLE Ping ────────────────────────────────────────

section "PHASE 5: BLE Ping"

# Ensure both devices are advertising
info "Ensuring BLE advertising on both devices..."
api_debug "$BASE_A" "ble_advertise" > /dev/null
api_debug "$BASE_B" "ble_advertise" > /dev/null
sleep 2

# Scan from both devices
info "Triggering ble_scan on both devices..."
api_debug "$BASE_A" "ble_scan" > /dev/null
api_debug "$BASE_B" "ble_scan" > /dev/null

info "Waiting 12s for BLE discovery..."
sleep 12

# HELLO handshake to establish BLE connections (target specific callsigns)
info "Triggering BLE HELLO handshake on both devices..."
api_debug "$BASE_A" "ble_hello" "\"device_id\": \"$CALLSIGN_B\"" > /dev/null
api_debug "$BASE_B" "ble_hello" "\"device_id\": \"$CALLSIGN_A\"" > /dev/null

info "Waiting 8s for HELLO handshake completion..."
sleep 8

# Try both directions — BLE is asymmetric across different hardware,
# so we count success if at least one direction works.
BLE_A_TO_B=false
BLE_B_TO_A=false

# A → B via BLE
info "Pinging $CALLSIGN_B from Device A via BLE..."
RESPONSE=$(api_debug "$BASE_A" "device_ping" "\"callsign\": \"$CALLSIGN_B\", \"transport\": \"ble\"")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
TRANSPORT_USED=$(echo "$RESPONSE" | jq -r '.transport_used // "none"')
LATENCY=$(echo "$RESPONSE" | jq -r '.latency_ms // "?"')
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

if [ "$SUCCESS" = "true" ]; then
    pass "A→B BLE ping: ${LATENCY}ms via $TRANSPORT_USED"
    BLE_A_TO_B=true
else
    warn "A→B BLE ping failed: $ERROR"
fi

# B → A via BLE
info "Pinging $CALLSIGN_A from Device B via BLE..."
RESPONSE=$(api_debug "$BASE_B" "device_ping" "\"callsign\": \"$CALLSIGN_A\", \"transport\": \"ble\"")
SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
TRANSPORT_USED=$(echo "$RESPONSE" | jq -r '.transport_used // "none"')
LATENCY=$(echo "$RESPONSE" | jq -r '.latency_ms // "?"')
ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

if [ "$SUCCESS" = "true" ]; then
    pass "B→A BLE ping: ${LATENCY}ms via $TRANSPORT_USED"
    BLE_B_TO_A=true
else
    warn "B→A BLE ping failed: $ERROR"
fi

# BLE overall verdict: pass if at least one direction works
if [ "$BLE_A_TO_B" = "true" ] && [ "$BLE_B_TO_A" = "true" ]; then
    pass "BLE bidirectional ping OK"
elif [ "$BLE_A_TO_B" = "true" ] || [ "$BLE_B_TO_A" = "true" ]; then
    pass "BLE unidirectional ping OK (asymmetric — may be hardware-specific)"
else
    fail "BLE ping failed in both directions"
fi

# ── Phase 6: Station (Internet) Ping ─────────────────────────

section "PHASE 6: Station (Internet) Ping"

# Check station status on both
info "Checking station status on Device A..."
RESPONSE_A=$(api_debug "$BASE_A" "station_status")
STATION_A=$(echo "$RESPONSE_A" | jq -r '.connected // false')
STATION_URL_A=$(echo "$RESPONSE_A" | jq -r '.station_url // "unknown"')

info "Checking station status on Device B..."
RESPONSE_B=$(api_debug "$BASE_B" "station_status")
STATION_B=$(echo "$RESPONSE_B" | jq -r '.connected // false')
STATION_URL_B=$(echo "$RESPONSE_B" | jq -r '.station_url // "unknown"')

info "Station A: connected=$STATION_A url=$STATION_URL_A"
info "Station B: connected=$STATION_B url=$STATION_URL_B"

if [ "$STATION_A" != "true" ] || [ "$STATION_B" != "true" ]; then
    warn "Skipping station ping — both devices must be connected to a station"
    if [ "$STATION_A" != "true" ]; then
        fail "Device A not connected to station"
    fi
    if [ "$STATION_B" != "true" ]; then
        fail "Device B not connected to station"
    fi
else
    # A → B via station
    info "Pinging $CALLSIGN_B from Device A via station..."
    RESPONSE=$(api_debug "$BASE_A" "device_ping" "\"callsign\": \"$CALLSIGN_B\", \"transport\": \"station\"")
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
    TRANSPORT_USED=$(echo "$RESPONSE" | jq -r '.transport_used // "none"')
    LATENCY=$(echo "$RESPONSE" | jq -r '.latency_ms // "?"')
    ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

    if [ "$SUCCESS" = "true" ]; then
        pass "A→B Station ping: ${LATENCY}ms via $TRANSPORT_USED"
    else
        fail "A→B Station ping failed" "$ERROR"
    fi

    # B → A via station
    info "Pinging $CALLSIGN_A from Device B via station..."
    RESPONSE=$(api_debug "$BASE_B" "device_ping" "\"callsign\": \"$CALLSIGN_A\", \"transport\": \"station\"")
    SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
    TRANSPORT_USED=$(echo "$RESPONSE" | jq -r '.transport_used // "none"')
    LATENCY=$(echo "$RESPONSE" | jq -r '.latency_ms // "?"')
    ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')

    if [ "$SUCCESS" = "true" ]; then
        pass "B→A Station ping: ${LATENCY}ms via $TRANSPORT_USED"
    else
        fail "B→A Station ping failed" "$ERROR"
    fi
fi

# ── Summary ───────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════════"
if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "         ${GREEN}ALL TESTS PASSED! ($TESTS_PASSED/$TESTS_RUN)${NC}"
else
    echo -e "         ${YELLOW}TESTS: $TESTS_PASSED passed, $TESTS_FAILED failed ($TESTS_RUN total)${NC}"
fi
echo "════════════════════════════════════════════════════════════════════════"
echo ""

exit $TESTS_FAILED
