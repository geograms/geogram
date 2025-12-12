#!/bin/bash
# Alerts API Test Script
# Tests the Alerts API endpoints via debug API
#
# Usage: ./tests/run_alerts_api_test.sh
#
# Prerequisites:
# - Build the app: flutter build linux --release
# - jq installed for JSON parsing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GEOGRAM="$PROJECT_DIR/build/linux/x64/release/bundle/geogram_desktop"

# Configuration
PORT=6200
DATA_DIR=/tmp/geogram-alerts-test
STARTUP_WAIT=10
API_WAIT=1

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${CYAN}[TEST]${NC} $1"
}

cleanup() {
    log_info "Cleaning up..."
    pkill -f "geogram_desktop.*--port=$PORT" 2>/dev/null || true
    sleep 2
    rm -rf "$DATA_DIR"
}

check_dependencies() {
    if [ ! -f "$GEOGRAM" ]; then
        log_error "Geogram binary not found at $GEOGRAM"
        log_error "Please build with: flutter build linux --release"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi
}

wait_for_api() {
    local port=$1
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://localhost:$port/api/status" > /dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    log_error "API not available on port $port after $max_attempts seconds"
    return 1
}

debug_action() {
    local action=$1
    shift
    local params="$@"

    local json="{\"action\": \"$action\""
    if [ -n "$params" ]; then
        json="$json, $params"
    fi
    json="$json}"

    curl -s -X POST "http://localhost:$PORT/api/debug" \
        -H "Content-Type: application/json" \
        -d "$json"
}

api_get() {
    local path=$1
    curl -s "http://localhost:$PORT$path"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $message"
        echo -e "    Expected: $expected"
        echo -e "    Actual: $actual"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local message="$2"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if [ -n "$value" ] && [ "$value" != "null" ] && [ "$value" != "" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $message (got empty or null)"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))

    if echo "$haystack" | grep -q "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $message"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $message"
        echo -e "    '$needle' not found in response"
        return 1
    fi
}

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local message="$4"

    local actual=$(echo "$json" | jq -r "$field")
    assert_equals "$expected" "$actual" "$message"
}

assert_json_field_not_empty() {
    local json="$1"
    local field="$2"
    local message="$3"

    local actual=$(echo "$json" | jq -r "$field")
    assert_not_empty "$actual" "$message"
}

# Main test flow
main() {
    log_info "=== Geogram Alerts API Test ==="
    echo ""

    check_dependencies
    cleanup

    # Create data directory
    mkdir -p "$DATA_DIR"

    log_info "Starting test instance on port $PORT..."
    "$GEOGRAM" --port=$PORT --data-dir="$DATA_DIR" \
        --new-identity --nickname="AlertsTest" --skip-intro \
        --http-api --debug-api &>/dev/null &
    PID=$!

    log_info "Waiting for instance to start..."
    sleep $STARTUP_WAIT

    if ! wait_for_api $PORT; then
        log_error "Instance failed to start"
        cleanup
        exit 1
    fi

    # Get instance info
    STATUS=$(api_get "/api/status")
    CALLSIGN=$(echo "$STATUS" | jq -r '.callsign')
    log_info "Instance callsign: $CALLSIGN"
    echo ""

    # ==========================================
    # Test 1: API endpoints listed in index
    # ==========================================
    log_test "Test 1: API endpoints listed in index"
    API_INDEX=$(api_get "/api/")

    assert_contains "$API_INDEX" "/api/alerts" "Alerts endpoint in API index"
    assert_contains "$API_INDEX" "/api/alerts/{alertId}" "Single alert endpoint in API index"
    assert_contains "$API_INDEX" "/api/alerts/{alertId}/files" "Alert files endpoint in API index"
    echo ""

    # ==========================================
    # Test 2: Empty alerts list initially
    # ==========================================
    log_test "Test 2: Empty alerts list initially"
    ALERTS_LIST=$(api_get "/api/alerts")

    assert_json_field "$ALERTS_LIST" ".total" "0" "Initial alerts count is 0"
    ALERTS_COUNT=$(echo "$ALERTS_LIST" | jq '.alerts | length')
    assert_equals "0" "$ALERTS_COUNT" "Initial alerts array is empty"
    echo ""

    # ==========================================
    # Test 3: Create alert via debug API
    # ==========================================
    log_test "Test 3: Create alert via debug API"
    CREATE_RESULT=$(debug_action "alert_create" \
        '"title": "Test Alert Broken Sidewalk"' \
        ', "description": "Large crack on the sidewalk near the bus stop"' \
        ', "latitude": 38.7223' \
        ', "longitude": -9.1393' \
        ', "severity": "urgent"' \
        ', "type": "infrastructure-broken"')

    assert_json_field "$CREATE_RESULT" ".success" "true" "Alert creation succeeds"
    ALERT_ID=$(echo "$CREATE_RESULT" | jq -r '.alert.id')
    assert_not_empty "$ALERT_ID" "Alert ID returned"
    assert_contains "$ALERT_ID" "test-alert-broken-sidewalk" "Alert ID contains slugified title"
    echo "  Created alert: $ALERT_ID"
    echo ""
    sleep $API_WAIT

    # ==========================================
    # Test 4: List alerts shows created alert
    # ==========================================
    log_test "Test 4: List alerts shows created alert"
    ALERTS_LIST=$(api_get "/api/alerts")

    assert_json_field "$ALERTS_LIST" ".total" "1" "Total alerts count is 1"
    FIRST_ALERT_ID=$(echo "$ALERTS_LIST" | jq -r '.alerts[0].id')
    assert_equals "$ALERT_ID" "$FIRST_ALERT_ID" "Created alert appears in list"

    FIRST_ALERT_TITLE=$(echo "$ALERTS_LIST" | jq -r '.alerts[0].title')
    assert_equals "Test Alert Broken Sidewalk" "$FIRST_ALERT_TITLE" "Alert title matches"

    FIRST_ALERT_SEVERITY=$(echo "$ALERTS_LIST" | jq -r '.alerts[0].severity')
    assert_equals "urgent" "$FIRST_ALERT_SEVERITY" "Alert severity matches"
    echo ""

    # ==========================================
    # Test 5: Get single alert by ID
    # ==========================================
    log_test "Test 5: Get single alert by ID"
    SINGLE_ALERT=$(api_get "/api/alerts/$ALERT_ID")

    assert_json_field "$SINGLE_ALERT" ".id" "$ALERT_ID" "Single alert ID matches"
    assert_json_field "$SINGLE_ALERT" ".title" "Test Alert Broken Sidewalk" "Single alert title matches"
    assert_json_field "$SINGLE_ALERT" ".description" "Large crack on the sidewalk near the bus stop" "Description matches"
    assert_json_field "$SINGLE_ALERT" ".severity" "urgent" "Severity matches"
    assert_json_field "$SINGLE_ALERT" ".type" "infrastructure-broken" "Type matches"
    assert_json_field "$SINGLE_ALERT" ".status" "open" "Default status is open"

    # Check coordinates (should be truncated to 4 decimals)
    ALERT_LAT=$(echo "$SINGLE_ALERT" | jq '.latitude')
    ALERT_LON=$(echo "$SINGLE_ALERT" | jq '.longitude')
    assert_not_empty "$ALERT_LAT" "Latitude present"
    assert_not_empty "$ALERT_LON" "Longitude present"
    echo ""

    # ==========================================
    # Test 6: Create second alert for filtering tests
    # ==========================================
    log_test "Test 6: Create second alert (different location)"
    CREATE_RESULT2=$(debug_action "alert_create" \
        '"title": "Pothole on Main Street"' \
        ', "description": "Deep pothole causing traffic issues"' \
        ', "latitude": 40.7128' \
        ', "longitude": -74.0060' \
        ', "severity": "info"' \
        ', "type": "road-damage"')

    assert_json_field "$CREATE_RESULT2" ".success" "true" "Second alert creation succeeds"
    ALERT_ID_2=$(echo "$CREATE_RESULT2" | jq -r '.alert.id')
    assert_not_empty "$ALERT_ID_2" "Second alert ID returned"
    echo "  Created alert: $ALERT_ID_2"
    echo ""
    sleep $API_WAIT

    # ==========================================
    # Test 7: List all alerts (should have 2)
    # ==========================================
    log_test "Test 7: List all alerts (should have 2)"
    ALERTS_LIST=$(api_get "/api/alerts")

    assert_json_field "$ALERTS_LIST" ".total" "2" "Total alerts count is 2"
    echo ""

    # ==========================================
    # Test 8: Filter by geographic location (near Lisbon)
    # ==========================================
    log_test "Test 8: Geographic filter (near Lisbon, 50km radius)"
    # Lisbon is at ~38.72, -9.14, first alert should match
    FILTERED=$(api_get "/api/alerts?lat=38.72&lon=-9.14&radius=50")

    FILTERED_COUNT=$(echo "$FILTERED" | jq '.alerts | length')
    assert_equals "1" "$FILTERED_COUNT" "Only Lisbon alert in 50km radius"

    FILTERED_ID=$(echo "$FILTERED" | jq -r '.alerts[0].id')
    assert_equals "$ALERT_ID" "$FILTERED_ID" "Correct alert returned (Lisbon)"

    # Verify filter info in response
    FILTER_LAT=$(echo "$FILTERED" | jq '.filters.lat')
    assert_equals "38.72" "$FILTER_LAT" "Filter lat in response"
    FILTER_RADIUS=$(echo "$FILTERED" | jq '.filters.radius_km')
    # API may return integer or float (50 or 50.0)
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$FILTER_RADIUS" = "50" ] || [ "$FILTER_RADIUS" = "50.0" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: Filter radius in response"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: Filter radius in response (expected 50 or 50.0, got $FILTER_RADIUS)"
    fi
    echo ""

    # ==========================================
    # Test 9: Geographic filter (near NYC)
    # ==========================================
    log_test "Test 9: Geographic filter (near NYC, 50km radius)"
    # NYC is at ~40.71, -74.01, second alert should match
    FILTERED=$(api_get "/api/alerts?lat=40.71&lon=-74.01&radius=50")

    FILTERED_COUNT=$(echo "$FILTERED" | jq '.alerts | length')
    assert_equals "1" "$FILTERED_COUNT" "Only NYC alert in 50km radius"

    FILTERED_ID=$(echo "$FILTERED" | jq -r '.alerts[0].id')
    assert_equals "$ALERT_ID_2" "$FILTERED_ID" "Correct alert returned (NYC)"
    echo ""

    # ==========================================
    # Test 10: Geographic filter (no results)
    # ==========================================
    log_test "Test 10: Geographic filter (middle of Atlantic, no results)"
    FILTERED=$(api_get "/api/alerts?lat=0&lon=0&radius=100")

    FILTERED_COUNT=$(echo "$FILTERED" | jq '.alerts | length')
    assert_equals "0" "$FILTERED_COUNT" "No alerts in middle of ocean"
    echo ""

    # ==========================================
    # Test 11: Create alert with specific status
    # ==========================================
    log_test "Test 11: Create alert with resolved status"
    CREATE_RESULT3=$(debug_action "alert_create" \
        '"title": "Fixed Streetlight"' \
        ', "description": "Streetlight was repaired"' \
        ', "latitude": 38.7300' \
        ', "longitude": -9.1500' \
        ', "severity": "info"' \
        ', "type": "lighting"' \
        ', "status": "resolved"')

    assert_json_field "$CREATE_RESULT3" ".success" "true" "Resolved alert creation succeeds"
    ALERT_ID_3=$(echo "$CREATE_RESULT3" | jq -r '.alert.id')
    echo "  Created alert: $ALERT_ID_3"
    echo ""
    sleep $API_WAIT

    # ==========================================
    # Test 12: Filter by status
    # ==========================================
    log_test "Test 12: Filter by status (open)"
    FILTERED=$(api_get "/api/alerts?status=open")

    FILTERED_COUNT=$(echo "$FILTERED" | jq '.alerts | length')
    assert_equals "2" "$FILTERED_COUNT" "Two open alerts"

    # Filter for resolved
    FILTERED=$(api_get "/api/alerts?status=resolved")
    FILTERED_COUNT=$(echo "$FILTERED" | jq '.alerts | length')
    assert_equals "1" "$FILTERED_COUNT" "One resolved alert"
    echo ""

    # ==========================================
    # Test 13: Combined filters (status + location)
    # ==========================================
    log_test "Test 13: Combined filters (status + location)"
    # Open alerts near Lisbon
    FILTERED=$(api_get "/api/alerts?status=open&lat=38.72&lon=-9.14&radius=50")

    FILTERED_COUNT=$(echo "$FILTERED" | jq '.alerts | length')
    assert_equals "1" "$FILTERED_COUNT" "One open alert near Lisbon"

    # Resolved alerts near Lisbon (should include the fixed streetlight)
    FILTERED=$(api_get "/api/alerts?status=resolved&lat=38.73&lon=-9.15&radius=10")
    FILTERED_COUNT=$(echo "$FILTERED" | jq '.alerts | length')
    assert_equals "1" "$FILTERED_COUNT" "One resolved alert near streetlight location"
    echo ""

    # ==========================================
    # Test 14: Delete alert
    # ==========================================
    log_test "Test 14: Delete alert via debug API"
    DELETE_RESULT=$(debug_action "alert_delete" "\"alert_id\": \"$ALERT_ID_3\"")

    assert_json_field "$DELETE_RESULT" ".success" "true" "Alert deletion succeeds"

    # Verify deleted
    ALERTS_LIST=$(api_get "/api/alerts")
    TOTAL_AFTER=$(echo "$ALERTS_LIST" | jq '.total')
    assert_equals "2" "$TOTAL_AFTER" "Two alerts remaining after delete"
    echo ""

    # ==========================================
    # Test 15: Get non-existent alert (404)
    # ==========================================
    log_test "Test 15: Get non-existent alert returns error"
    MISSING_ALERT=$(api_get "/api/alerts/non-existent-alert-id")

    MISSING_ERROR=$(echo "$MISSING_ALERT" | jq -r '.error // empty')
    assert_not_empty "$MISSING_ERROR" "Error returned for missing alert"
    echo ""

    # ==========================================
    # Test 16: Alert list via debug API
    # ==========================================
    log_test "Test 16: Alert list via debug API"
    LIST_RESULT=$(debug_action "alert_list")

    assert_json_field "$LIST_RESULT" ".success" "true" "Debug alert_list succeeds"
    DEBUG_COUNT=$(echo "$LIST_RESULT" | jq '.alerts | length')
    assert_equals "2" "$DEBUG_COUNT" "Debug list shows 2 alerts"
    echo ""

    # ==========================================
    # Test 17: Verify coordinate truncation (privacy)
    # ==========================================
    log_test "Test 17: Coordinates truncated to 4 decimal places"
    # Create alert with high-precision coords
    CREATE_RESULT=$(debug_action "alert_create" \
        '"title": "Precision Test Alert"' \
        ', "description": "Testing coordinate precision"' \
        ', "latitude": 38.7223456789' \
        ', "longitude": -9.1393456789' \
        ', "severity": "info"' \
        ', "type": "other"')

    PRECISION_ID=$(echo "$CREATE_RESULT" | jq -r '.alert.id')

    # Get the alert and check coordinates
    PRECISION_ALERT=$(api_get "/api/alerts/$PRECISION_ID")
    LAT=$(echo "$PRECISION_ALERT" | jq '.latitude')
    LON=$(echo "$PRECISION_ALERT" | jq '.longitude')

    # Count decimal places (should be at most 4)
    LAT_DECIMALS=$(echo "$LAT" | grep -o '\.[0-9]*' | tail -c +2 | wc -c)
    LON_DECIMALS=$(echo "$LON" | grep -o '\.[0-9]*' | tail -c +2 | wc -c)

    # 4 decimals + newline = 5, but allow for trailing zeros being removed
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$LAT_DECIMALS" -le 5 ] && [ "$LON_DECIMALS" -le 5 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: Coordinates properly truncated (lat: $LAT, lon: $LON)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: Coordinates have too many decimals (lat: $LAT, lon: $LON)"
    fi

    # Cleanup this test alert
    debug_action "alert_delete" "\"alert_id\": \"$PRECISION_ID\"" > /dev/null
    echo ""

    # ==========================================
    # Summary
    # ==========================================
    echo ""
    log_info "=== Test Summary ==="
    log_info "Instance: $CALLSIGN (port $PORT)"
    echo ""
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo -e "Total tests:  $TESTS_TOTAL"
    echo ""

    # Cleanup
    log_info "Cleaning up..."
    kill $PID 2>/dev/null || true

    if [ $TESTS_FAILED -gt 0 ]; then
        log_error "Some tests failed!"
        exit 1
    else
        log_info "All tests passed!"
        exit 0
    fi
}

# Run main with cleanup on exit
trap cleanup EXIT
main "$@"
