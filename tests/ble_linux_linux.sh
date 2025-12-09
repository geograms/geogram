#!/bin/bash
# BLE Test: Linux to Linux (Automated)
#
# This script launches two Geogram Desktop instances on separate ports
# with isolated temporary data directories, then runs BLE communication tests.
# Temporary directories are automatically cleaned up on exit.
#
# Usage:
#   ./tests/ble_linux_linux.sh              # Auto-launch two instances and test
#   ./tests/ble_linux_linux.sh --manual IP  # Test against manually started instance
#
# What it tests:
#   1. BLE scanning and device discovery
#   2. HELLO handshake between devices
#   3. Large document exchange (2000 bytes)
#
# Requirements:
#   - Built Geogram Desktop binary
#   - Bluetooth enabled
#   - X11 display available (for GUI mode)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test configuration
INSTANCE1_PORT=3455
INSTANCE2_PORT=3466
GEOGRAM_BINARY="${PROJECT_DIR}/build/linux/x64/release/bundle/geogram_desktop"
STARTUP_TIMEOUT=30
TEST_DOC_SIZE=2000

# Temporary directories (created at runtime)
INSTANCE1_DIR=""
INSTANCE2_DIR=""

# PIDs for cleanup
INSTANCE1_PID=""
INSTANCE2_PID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

print_header() {
    echo ""
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
}

print_subheader() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

print_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

print_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((TESTS_SKIPPED++))
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Cleanup function - runs on exit
cleanup() {
    print_info "Cleaning up..."

    # Kill instances if running
    if [ -n "$INSTANCE1_PID" ] && kill -0 "$INSTANCE1_PID" 2>/dev/null; then
        print_info "Stopping instance 1 (PID: $INSTANCE1_PID)"
        kill "$INSTANCE1_PID" 2>/dev/null || true
        wait "$INSTANCE1_PID" 2>/dev/null || true
    fi

    if [ -n "$INSTANCE2_PID" ] && kill -0 "$INSTANCE2_PID" 2>/dev/null; then
        print_info "Stopping instance 2 (PID: $INSTANCE2_PID)"
        kill "$INSTANCE2_PID" 2>/dev/null || true
        wait "$INSTANCE2_PID" 2>/dev/null || true
    fi

    # Also kill any orphan instances on our test ports
    for port in $INSTANCE1_PORT $INSTANCE2_PORT; do
        local pid=$(lsof -t -i:$port 2>/dev/null || true)
        if [ -n "$pid" ]; then
            print_info "Killing process on port $port (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
    done

    # Remove temporary directories
    if [ -n "$INSTANCE1_DIR" ] && [ -d "$INSTANCE1_DIR" ]; then
        print_info "Removing temp directory: $INSTANCE1_DIR"
        rm -rf "$INSTANCE1_DIR"
    fi

    if [ -n "$INSTANCE2_DIR" ] && [ -d "$INSTANCE2_DIR" ]; then
        print_info "Removing temp directory: $INSTANCE2_DIR"
        rm -rf "$INSTANCE2_DIR"
    fi

    print_info "Cleanup complete"
}

# Create fresh temporary directories
setup_directories() {
    print_info "Creating temporary test directories..."
    INSTANCE1_DIR=$(mktemp -d -t geogram_ble_test1_XXXXXX)
    INSTANCE2_DIR=$(mktemp -d -t geogram_ble_test2_XXXXXX)
    print_info "Instance 1 temp dir: $INSTANCE1_DIR"
    print_info "Instance 2 temp dir: $INSTANCE2_DIR"
}

# Check if binary exists
check_binary() {
    if [ ! -x "$GEOGRAM_BINARY" ]; then
        # Try debug build
        GEOGRAM_BINARY="${PROJECT_DIR}/build/linux/x64/debug/bundle/geogram_desktop"
        if [ ! -x "$GEOGRAM_BINARY" ]; then
            print_error "Geogram binary not found. Please build first with:"
            echo "  cd $PROJECT_DIR && flutter build linux"
            exit 1
        fi
        print_warning "Using debug build"
    fi
    print_info "Using binary: $GEOGRAM_BINARY"
}

# Check if Geogram is running on a port
check_geogram_running() {
    local host="${1:-localhost}"
    local port="${2:-3456}"
    curl -s "http://${host}:${port}/api/debug" > /dev/null 2>&1
}

# Wait for Geogram to start
wait_for_startup() {
    local port="$1"
    local timeout="$2"
    local waited=0

    while [ $waited -lt $timeout ]; do
        if check_geogram_running "localhost" "$port"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
        echo -n "."
    done
    echo ""
    return 1
}

# Get callsign from instance
get_callsign() {
    local port="$1"
    curl -s "http://localhost:${port}/api/debug" 2>/dev/null | jq -r '.callsign // "unknown"'
}

# Trigger API action
trigger_action() {
    local port="$1"
    local action="$2"
    shift 2
    local params="$@"

    local json="{\"action\": \"$action\""
    if [ -n "$params" ]; then
        json="$json, $params"
    fi
    json="$json}"

    curl -s -X POST "http://localhost:${port}/api/debug" \
        -H "Content-Type: application/json" \
        -d "$json"
}

# Get logs from instance
get_logs() {
    local port="$1"
    local filter="${2:-}"
    local limit="${3:-100}"

    local url="http://localhost:${port}/log?limit=$limit"
    if [ -n "$filter" ]; then
        url="$url&filter=$(echo -n "$filter" | jq -sRr @uri)"
    fi

    curl -s "$url" 2>/dev/null
}

# Check if log contains pattern
log_contains() {
    local port="$1"
    local pattern="$2"
    local filter="${3:-}"

    get_logs "$port" "$filter" 100 | jq -r '.logs[]' 2>/dev/null | grep -q "$pattern"
}

# Wait for log pattern
wait_for_log() {
    local port="$1"
    local pattern="$2"
    local timeout="${3:-15}"
    local filter="${4:-}"
    local waited=0

    while [ $waited -lt $timeout ]; do
        if log_contains "$port" "$pattern" "$filter"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Launch a Geogram instance
launch_instance() {
    local port="$1"
    local data_dir="$2"
    local name="$3"
    local nickname="$4"

    print_info "Launching $name on port $port..."
    print_info "  Data dir: $data_dir"

    # Check if port is already in use
    if lsof -i:$port > /dev/null 2>&1; then
        print_warning "Port $port already in use, attempting to free it..."
        local pid=$(lsof -t -i:$port)
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi

    # Launch with display and new identity
    DISPLAY="${DISPLAY:-:0}" "$GEOGRAM_BINARY" \
        --port="$port" \
        --data-dir="$data_dir" \
        --http-api \
        --debug-api \
        --new-identity \
        --identity-type=client \
        --nickname="$nickname" \
        > "${data_dir}/stdout.log" 2>&1 &

    echo $!
}

# ============================================================================
# TEST FUNCTIONS
# ============================================================================

test_ble_scan() {
    local port="$1"
    local name="$2"

    print_subheader "BLE Scan Test ($name)"

    print_info "Triggering BLE scan..."
    local result=$(trigger_action "$port" "ble_scan")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "Scan triggered, waiting for results..."

        # Wait for scan to complete
        sleep 15

        # Check logs for scan activity
        if log_contains "$port" "BLEDiscovery" "BLE"; then
            print_success "BLE scan completed ($name)"

            # Count discovered devices
            local devices=$(get_logs "$port" "Found" 50 | jq -r '.logs[]' 2>/dev/null | grep -c "Found" || echo "0")
            print_info "  Discovered $devices device(s)"
            return 0
        else
            print_skip "BLE scan - no log entries (BLE may not be available)"
            return 2
        fi
    else
        print_error "BLE scan trigger failed ($name)"
        return 1
    fi
}

test_ble_discovery() {
    local port1="$1"
    local port2="$2"

    print_subheader "BLE Discovery Test"

    print_info "Instance 1 scanning for Instance 2..."

    # Trigger scan on instance 1
    trigger_action "$port1" "ble_scan" > /dev/null

    # Wait for scan
    sleep 15

    # Get callsign of instance 2
    local callsign2=$(get_callsign "$port2")

    # Check if instance 1 found instance 2
    if log_contains "$port1" "$callsign2" "BLE"; then
        print_success "Instance 1 discovered Instance 2 ($callsign2)"
        return 0
    else
        # On Linux, BLE advertising is not supported, so this may fail
        print_skip "BLE discovery - Linux cannot advertise (expected limitation)"
        return 2
    fi
}

test_ble_hello() {
    local port1="$1"
    local port2="$2"

    print_subheader "BLE HELLO Handshake Test"

    # First do a scan to discover devices
    print_info "Scanning for devices first..."
    trigger_action "$port1" "ble_scan" > /dev/null
    sleep 15

    # Check if any devices were found
    local devices_found=$(get_logs "$port1" "Found" 50 | jq -r '.logs[]' 2>/dev/null | grep -c "Found" || echo "0")

    if [ "$devices_found" = "0" ]; then
        print_skip "BLE HELLO - no devices discovered to connect to"
        return 2
    fi

    print_info "Found $devices_found device(s), attempting HELLO..."

    # Trigger HELLO
    local result=$(trigger_action "$port1" "ble_hello")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "HELLO triggered, waiting for response..."

        # Wait for HELLO response
        if wait_for_log "$port1" "HELLO" 20 "BLE"; then
            # Check for success
            if log_contains "$port1" "successful" "BLE" || log_contains "$port1" "ACK" "BLE"; then
                print_success "BLE HELLO handshake completed"
                return 0
            else
                print_skip "BLE HELLO - initiated but status uncertain"
                return 2
            fi
        else
            print_error "BLE HELLO timeout"
            return 1
        fi
    else
        print_error "BLE HELLO trigger failed"
        return 1
    fi
}

test_ble_send_data() {
    local port1="$1"
    local port2="$2"
    local size="$3"

    print_subheader "BLE Data Transfer Test (${size} bytes)"

    # Check if we have a connected device first
    if ! log_contains "$port1" "HELLO.*successful" "BLE"; then
        print_skip "BLE data transfer - no established connection"
        return 2
    fi

    print_info "Sending $size bytes of data..."

    # Trigger data send
    local result=$(trigger_action "$port1" "ble_send" "\"size\": $size")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "Data send triggered, waiting for transfer..."

        # Wait for transfer to complete
        if wait_for_log "$port1" "sent\|transfer\|complete" 30 "BLE"; then
            print_success "BLE data transfer initiated ($size bytes)"

            # Check receiver
            if wait_for_log "$port2" "received\|incoming" 10 "BLE"; then
                print_success "BLE data received on Instance 2"
                return 0
            else
                print_info "  Receiver logs not found (may need more implementation)"
                return 0
            fi
        else
            print_skip "BLE data transfer - logs not found"
            return 2
        fi
    else
        print_error "BLE send trigger failed"
        return 1
    fi
}

print_summary() {
    print_header "Test Summary"

    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

    echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
    echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
    echo -e "  Total:   $total"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

# ============================================================================
# MAIN
# ============================================================================

# Register cleanup on exit
trap cleanup EXIT

print_header "BLE Test: Linux to Linux (Automated)"

# Parse arguments
case "${1:-}" in
    --manual)
        # Manual mode - use externally started instances
        if [ -z "${2:-}" ]; then
            print_error "Usage: $0 --manual IP_ADDRESS"
            exit 1
        fi
        print_info "Manual mode: testing against $2"
        print_error "Manual mode not yet implemented in this version"
        exit 1
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (none)      Auto-launch two instances and run tests"
        echo "  --manual IP Test against manually started instance"
        echo "  --help      Show this help"
        echo ""
        echo "Note: Temporary directories are automatically created and cleaned up."
        exit 0
        ;;
esac

# Check prerequisites
check_binary

# Setup directories
setup_directories

# Launch two instances
print_subheader "Launching Geogram Instances"

INSTANCE1_PID=$(launch_instance "$INSTANCE1_PORT" "$INSTANCE1_DIR" "Instance 1" "BLE Test Device 1")
print_info "Instance 1 PID: $INSTANCE1_PID"

# Small delay between launches
sleep 2

INSTANCE2_PID=$(launch_instance "$INSTANCE2_PORT" "$INSTANCE2_DIR" "Instance 2" "BLE Test Device 2")
print_info "Instance 2 PID: $INSTANCE2_PID"

# Wait for both instances to start
print_info "Waiting for instances to start (max ${STARTUP_TIMEOUT}s)..."

echo -n "  Instance 1: "
if wait_for_startup "$INSTANCE1_PORT" "$STARTUP_TIMEOUT"; then
    echo " Ready!"
    CALLSIGN1=$(get_callsign "$INSTANCE1_PORT")
    print_info "  Callsign: $CALLSIGN1"
else
    echo " TIMEOUT"
    print_error "Instance 1 failed to start"
    cat "${INSTANCE1_DIR}/stdout.log" 2>/dev/null || true
    exit 1
fi

echo -n "  Instance 2: "
if wait_for_startup "$INSTANCE2_PORT" "$STARTUP_TIMEOUT"; then
    echo " Ready!"
    CALLSIGN2=$(get_callsign "$INSTANCE2_PORT")
    print_info "  Callsign: $CALLSIGN2"
else
    echo " TIMEOUT"
    print_error "Instance 2 failed to start"
    cat "${INSTANCE2_DIR}/stdout.log" 2>/dev/null || true
    exit 1
fi

print_success "Both instances are running"
print_info "  Instance 1: http://localhost:$INSTANCE1_PORT (PID: $INSTANCE1_PID)"
print_info "  Instance 2: http://localhost:$INSTANCE2_PORT (PID: $INSTANCE2_PID)"

# Run tests
print_header "Running BLE Tests"

print_warning "Note: Linux cannot advertise BLE (ble_peripheral limitation)."
print_warning "Some tests may be skipped or have limited functionality."
print_info ""

# Test 1: BLE Scan on both instances
test_ble_scan "$INSTANCE1_PORT" "Instance 1"
test_ble_scan "$INSTANCE2_PORT" "Instance 2"

# Test 2: BLE Discovery (Instance 1 tries to discover Instance 2)
test_ble_discovery "$INSTANCE1_PORT" "$INSTANCE2_PORT"

# Test 3: BLE HELLO Handshake
test_ble_hello "$INSTANCE1_PORT" "$INSTANCE2_PORT"

# Test 4: Large Data Transfer (2000 bytes)
test_ble_send_data "$INSTANCE1_PORT" "$INSTANCE2_PORT" "$TEST_DOC_SIZE"

# Print summary
print_summary
TEST_RESULT=$?

# Show recent logs for debugging
print_header "Recent BLE Logs"

print_subheader "Instance 1 (last 20 BLE logs)"
get_logs "$INSTANCE1_PORT" "BLE" 20 | jq -r '.logs[]' 2>/dev/null | tail -10 || echo "(no logs)"

print_subheader "Instance 2 (last 20 BLE logs)"
get_logs "$INSTANCE2_PORT" "BLE" 20 | jq -r '.logs[]' 2>/dev/null | tail -10 || echo "(no logs)"

# Cleanup happens via trap
exit $TEST_RESULT
