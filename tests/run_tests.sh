#!/bin/bash
# Run geogram-desktop tests
#
# Usage:
#   ./run_tests.sh          # Run all local tests (default)
#   ./run_tests.sh local    # Run all local tests (no external hardware)
#   ./run_tests.sh chat     # Run chat API tests only
#   ./run_tests.sh dm       # Run DM (direct message) tests only
#   ./run_tests.sh tiles    # Run tile server tests
#   ./run_tests.sh alerts   # Run alert sharing tests
#   ./run_tests.sh ble      # Run BLE tests (requires Bluetooth hardware)
#   ./run_tests.sh all      # Run all tests including BLE

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Find dart executable
if command -v dart &> /dev/null; then
    DART="dart"
elif [ -x "$HOME/flutter/bin/dart" ]; then
    DART="$HOME/flutter/bin/dart"
elif [ -x "/usr/local/flutter/bin/dart" ]; then
    DART="/usr/local/flutter/bin/dart"
else
    echo -e "${RED}Error: dart not found. Please install Flutter/Dart SDK.${NC}"
    exit 1
fi

echo "Using Dart: $DART"
echo ""

run_chat_tests() {
    echo "========================================"
    echo "Running Chat API Tests"
    echo "========================================"
    echo "This test will:"
    echo "  - Build Geogram Desktop (if needed)"
    echo "  - Start a temporary instance on port 5678"
    echo "  - Test chat room listing"
    echo "  - Test message posting and retrieval"
    echo "  - Test file listing"
    echo "  - Clean up automatically"
    echo ""
    bash "$SCRIPT_DIR/run_chat_api_test.sh"
}

run_dm_tests() {
    echo "========================================"
    echo "Running DM (Direct Message) Tests"
    echo "========================================"
    echo "This test will:"
    echo "  - Build Geogram Desktop (if needed)"
    echo "  - Start two temporary instances (ports 5678, 5679)"
    echo "  - Create temporary identities for each"
    echo "  - Test DM conversation creation"
    echo "  - Test message sending between devices"
    echo "  - Test sync endpoints"
    echo "  - Clean up automatically"
    echo ""
    bash "$SCRIPT_DIR/run_dm_test.sh"
}

run_station_tests() {
    echo "========================================"
    echo "Running Relay API Tests"
    echo "========================================"
    # Use flutter test since the station depends on Flutter packages
    local FLUTTER=""
    if command -v flutter &> /dev/null; then
        FLUTTER="flutter"
    elif [ -x "$HOME/flutter/bin/flutter" ]; then
        FLUTTER="$HOME/flutter/bin/flutter"
    else
        echo "Error: flutter not found. Trying dart..."
        $DART bin/station_api_test.dart
        return
    fi
    $FLUTTER test bin/station_api_test.dart
}

run_tile_tests() {
    echo "========================================"
    echo "Running Tile Server Tests"
    echo "========================================"
    echo "This test will:"
    echo "  - Start a station server on port 45690"
    echo "  - Clear tile cache for clean results"
    echo "  - Test tile fetching from OSM"
    echo "  - Verify caching works (memory + disk)"
    echo "  - Verify cache hits on repeated requests"
    echo ""
    $DART bin/tile_server_test.dart
}

run_alert_tests() {
    echo "========================================"
    echo "Running Alert Sharing Tests"
    echo "========================================"
    echo "This test will:"
    echo "  - Start a station server on port 45691"
    echo "  - Create a mock client with NOSTR keys"
    echo "  - Send an alert event to the station"
    echo "  - Verify signature verification"
    echo "  - Verify alert storage on disk"
    echo "  - Verify EventBus notification"
    echo ""
    $DART bin/alert_sharing_test.dart
}

run_alert_api_tests() {
    echo "========================================"
    echo "Running Alert API Filter Tests"
    echo "========================================"
    echo "This test will:"
    echo "  - Start a station server on port 45692"
    echo "  - Create alerts at different locations (Lisbon, Sintra, Porto)"
    echo "  - Test radius-based filtering (20km, 50km, 500km)"
    echo "  - Test timestamp-based filtering (since parameter)"
    echo "  - Test status filtering (open, resolved)"
    echo "  - Verify distance calculation accuracy"
    echo "  - Test combined filters"
    echo ""
    $DART bin/alert_api_test.dart
}

run_flutter_tests() {
    echo "========================================"
    echo "Running Flutter Widget Tests"
    echo "========================================"
    local FLUTTER=""
    if command -v flutter &> /dev/null; then
        FLUTTER="flutter"
    elif [ -x "$HOME/flutter/bin/flutter" ]; then
        FLUTTER="$HOME/flutter/bin/flutter"
    else
        echo "Warning: flutter not found, skipping widget tests"
        return
    fi

    # Note: widget_test.dart is an outdated template that doesn't match the app
    # Skip for now until proper widget tests are written
    echo "Note: Flutter widget tests are placeholder templates"
    echo "      Run './run_tests.sh local' for actual API tests"
}

run_ble_tests() {
    echo "========================================"
    echo "Running BLE Tests (requires Bluetooth)"
    echo "========================================"
    echo "This test requires:"
    echo "  - Bluetooth hardware enabled"
    echo "  - Two test instances for full testing"
    echo ""
    bash "$SCRIPT_DIR/ble_linux_linux.sh"
}

run_local_tests() {
    echo "========================================"
    echo "Running All Local Tests"
    echo "========================================"
    echo "These tests do not require external hardware."
    echo ""

    local TOTAL_PASSED=0
    local TOTAL_FAILED=0

    # Chat API tests
    echo ""
    if run_chat_tests; then
        echo -e "${GREEN}✓ Chat API tests passed${NC}"
        TOTAL_PASSED=$((TOTAL_PASSED + 1))
    else
        echo -e "${RED}✗ Chat API tests failed${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi

    # DM tests
    echo ""
    if run_dm_tests; then
        echo -e "${GREEN}✓ DM tests passed${NC}"
        TOTAL_PASSED=$((TOTAL_PASSED + 1))
    else
        echo -e "${RED}✗ DM tests failed${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi

    # Summary
    echo ""
    echo "========================================"
    echo "Local Test Summary"
    echo "========================================"
    echo -e "Passed: ${GREEN}$TOTAL_PASSED${NC}"
    echo -e "Failed: ${RED}$TOTAL_FAILED${NC}"

    if [ $TOTAL_FAILED -eq 0 ]; then
        echo -e "${GREEN}All local tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed${NC}"
        return 1
    fi
}

case "${1:-local}" in
    local)
        run_local_tests
        ;;
    chat)
        run_chat_tests
        ;;
    dm)
        run_dm_tests
        ;;
    station)
        run_station_tests
        ;;
    tiles)
        run_tile_tests
        ;;
    alerts)
        run_alert_tests
        ;;
    alert-api|alertapi)
        run_alert_api_tests
        ;;
    flutter|widget)
        run_flutter_tests
        ;;
    ble)
        run_ble_tests
        ;;
    all)
        run_local_tests
        echo ""
        echo "========================================"
        echo "Running BLE Tests (requires Bluetooth)"
        echo "========================================"
        run_ble_tests
        ;;
    help|--help|-h)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  local      Run all local tests (no hardware required) [default]"
        echo "  chat       Run chat API tests (launches temp instance)"
        echo "  dm         Run DM tests (launches two temp instances)"
        echo "  station    Run station API tests (standalone)"
        echo "  tiles      Run tile server tests (standalone, tests caching)"
        echo "  alerts     Run alert sharing tests (NOSTR events, storage)"
        echo "  alert-api  Run alert API filter tests (radius, timestamp, status)"
        echo "  flutter    Run Flutter widget tests (placeholder)"
        echo "  ble        Run BLE tests (requires Bluetooth hardware)"
        echo "  all        Run all tests including BLE"
        echo "  help       Show this help message"
        echo ""
        echo "Local tests (no external hardware):"
        echo "  - Chat API: room listing, message posting, file listing"
        echo "  - DM: device-to-device messaging between two instances"
        echo ""
        echo "BLE tests (require Bluetooth):"
        echo "  - ble_linux_linux.sh: Two Linux instances"
        echo "  - ble_linux_android.sh: Linux to Android (requires device)"
        echo ""
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run '$0 help' for usage"
        exit 1
        ;;
esac

echo ""
echo "Done."
