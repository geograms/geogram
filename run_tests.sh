#!/bin/bash
# Run geogram-desktop tests
#
# Usage:
#   ./run_tests.sh          # Run relay API tests (default)
#   ./run_tests.sh relay    # Run relay API tests only
#   ./run_tests.sh tiles    # Run tile server tests (standalone)
#   ./run_tests.sh all      # Run all tests (relay + tiles)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Find dart executable
if command -v dart &> /dev/null; then
    DART="dart"
elif [ -x "$HOME/flutter/bin/dart" ]; then
    DART="$HOME/flutter/bin/dart"
elif [ -x "/usr/local/flutter/bin/dart" ]; then
    DART="/usr/local/flutter/bin/dart"
else
    echo "Error: dart not found. Please install Flutter/Dart SDK."
    exit 1
fi

echo "Using Dart: $DART"
echo ""

run_relay_tests() {
    echo "========================================"
    echo "Running Relay API Tests"
    echo "========================================"
    # Use flutter test since the relay depends on Flutter packages
    local FLUTTER=""
    if command -v flutter &> /dev/null; then
        FLUTTER="flutter"
    elif [ -x "$HOME/flutter/bin/flutter" ]; then
        FLUTTER="$HOME/flutter/bin/flutter"
    else
        echo "Error: flutter not found. Trying dart..."
        $DART bin/relay_api_test.dart
        return
    fi
    $FLUTTER test bin/relay_api_test.dart
}

run_tile_tests() {
    echo "========================================"
    echo "Running Tile Server Tests"
    echo "========================================"
    echo "This test will:"
    echo "  - Start a relay server on port 45690"
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
    echo "  - Start a relay server on port 45691"
    echo "  - Create a mock client with NOSTR keys"
    echo "  - Send an alert event to the relay"
    echo "  - Verify signature verification"
    echo "  - Verify alert storage on disk"
    echo "  - Verify EventBus notification"
    echo ""
    $DART bin/alert_sharing_test.dart
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
    echo "      Run './run_tests.sh relay' for actual API tests"
}

case "${1:-relay}" in
    relay)
        run_relay_tests
        ;;
    tiles)
        run_tile_tests
        ;;
    alerts)
        run_alert_tests
        ;;
    flutter|widget)
        run_flutter_tests
        ;;
    all)
        run_relay_tests
        echo ""
        run_tile_tests
        echo ""
        run_alert_tests
        ;;
    help|--help|-h)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  relay    Run relay API tests (standalone) [default]"
        echo "  tiles    Run tile server tests (standalone, tests caching)"
        echo "  alerts   Run alert sharing tests (NOSTR events, storage)"
        echo "  flutter  Run Flutter widget tests (placeholder)"
        echo "  all      Run relay + tile + alert tests"
        echo "  help     Show this help message"
        echo ""
        echo "Alert tests verify:"
        echo "  - NOSTR event creation and signing"
        echo "  - WebSocket communication with relay"
        echo "  - Alert event verification (BIP-340 Schnorr)"
        echo "  - Alert storage on relay disk"
        echo "  - EventBus notification to subscribers"
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
