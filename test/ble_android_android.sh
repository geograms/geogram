#!/bin/bash
# BLE Test: Android to Android
#
# Tests BLE communication between two Android devices running Geogram.
#
# Usage:
#   ./test/ble_android_android.sh 192.168.1.50 192.168.1.51
#
# Prerequisites:
#   - Geogram app must be running on both Android devices
#   - Both devices must be on the same network (for API access)
#   - Both devices must be in BLE range
#   - Both devices must have BLE advertising enabled
#
# Communication flow:
#   - Both devices can ADVERTISE (GATT Server)
#   - Both devices can SCAN and DISCOVER (GATT Client)
#   - Full bidirectional communication is possible
#
# This is the ideal BLE test scenario since both devices have full capabilities.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Geogram is running
check_geogram_running() {
    local host="${1:-localhost}"
    local port="${2:-3456}"

    if curl -s "http://${host}:${port}/api/debug" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Get callsign from device
get_callsign() {
    local host="${1:-localhost}"
    local port="${2:-3456}"
    curl -s "http://${host}:${port}/api/debug" 2>/dev/null | jq -r '.callsign // "unknown"'
}

# Main
print_header "BLE Test: Android to Android"

ANDROID1_IP="${1:-}"
ANDROID2_IP="${2:-}"

if [ -z "$ANDROID1_IP" ] || [ -z "$ANDROID2_IP" ]; then
    print_error "Usage: $0 ANDROID1_IP ANDROID2_IP"
    print_info ""
    print_info "Example: $0 192.168.1.50 192.168.1.51"
    print_info ""
    print_info "Make sure:"
    print_info "  1. Geogram app is running on both Android devices"
    print_info "  2. Both devices are on the same WiFi network"
    print_info "  3. Both devices have the debug API enabled"
    print_info "  4. Both devices are within BLE range of each other"
    exit 1
fi

print_info "Android device 1: $ANDROID1_IP"
print_info "Android device 2: $ANDROID2_IP"
print_info ""

# Check Android device 1
if ! check_geogram_running "$ANDROID1_IP" "3456"; then
    print_error "Cannot connect to Geogram on Android 1 at $ANDROID1_IP:3456"
    exit 1
fi
ANDROID1_CALLSIGN=$(get_callsign "$ANDROID1_IP" "3456")
print_success "Android 1: $ANDROID1_CALLSIGN"

# Check Android device 2
if ! check_geogram_running "$ANDROID2_IP" "3456"; then
    print_error "Cannot connect to Geogram on Android 2 at $ANDROID2_IP:3456"
    exit 1
fi
ANDROID2_CALLSIGN=$(get_callsign "$ANDROID2_IP" "3456")
print_success "Android 2: $ANDROID2_CALLSIGN"

print_info ""
print_info "Test scenario (Full bidirectional BLE):"
print_info "  1. Both devices can advertise (GATT Server)"
print_info "  2. Both devices can scan and discover (GATT Client)"
print_info "  3. Testing discovery in both directions"
print_info "  4. Testing HELLO handshakes in both directions"
print_info ""
print_success "This is the ideal BLE test - both devices have full capabilities!"
print_info ""

cd "$PROJECT_DIR"
dart run test/ble_api_test.dart \
    --device1="${ANDROID1_IP}:3456" \
    --device2="${ANDROID2_IP}:3456" \
    --verbose

print_info ""
print_info "Test complete."
