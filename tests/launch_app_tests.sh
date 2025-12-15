#!/bin/bash
# Geogram App Test Launcher
#
# This script launches the app test suites (Alert, IRC Bridge, Blog).
#
# Usage:
#   ./tests/launch_app_tests.sh
#
# Prerequisites:
#   - Build the app: flutter build linux --release

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=============================================="
echo "  Geogram App Test Suite"
echo -e "==============================================${NC}"
echo ""

# Change to project directory
cd "$PROJECT_DIR"

# Find Flutter/Dart
FLUTTER_CMD=""
DART_CMD=""

if command -v flutter &> /dev/null; then
    FLUTTER_CMD="flutter"
    # Get Dart from Flutter SDK
    FLUTTER_ROOT=$(flutter --version --machine 2>/dev/null | grep -o '"flutterRoot":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "$FLUTTER_ROOT" ] && [ -f "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" ]; then
        DART_CMD="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
    fi
elif [ -f "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/flutter/bin/flutter"
    if [ -f "$HOME/flutter/bin/cache/dart-sdk/bin/dart" ]; then
        DART_CMD="$HOME/flutter/bin/cache/dart-sdk/bin/dart"
    fi
fi

# Try direct dart command as fallback
if [ -z "$DART_CMD" ]; then
    if command -v dart &> /dev/null; then
        DART_CMD="dart"
    fi
fi

if [ -z "$FLUTTER_CMD" ]; then
    echo -e "${RED}Error: flutter command not found${NC}"
    echo "Please ensure Flutter SDK is installed and in your PATH"
    exit 1
fi

if [ -z "$DART_CMD" ]; then
    echo -e "${RED}Error: dart command not found${NC}"
    echo "Please ensure Flutter SDK is properly installed"
    exit 1
fi

echo -e "${CYAN}Using Flutter: $FLUTTER_CMD${NC}"
echo -e "${CYAN}Using Dart: $DART_CMD${NC}"
echo ""

# Check if CLI build exists
GEOGRAM_CLI="$PROJECT_DIR/build/geogram-cli"
if [ ! -f "$GEOGRAM_CLI" ]; then
    echo -e "${YELLOW}CLI build not found. Building...${NC}"
    ./launch-cli.sh --build-only
    echo -e "${GREEN}CLI build complete${NC}"
    echo ""
fi

# Check if desktop build exists
GEOGRAM="$PROJECT_DIR/build/linux/x64/release/bundle/geogram_desktop"
if [ ! -f "$GEOGRAM" ]; then
    echo -e "${YELLOW}Desktop build not found. Building...${NC}"
    $FLUTTER_CMD build linux --release
    echo -e "${GREEN}Desktop build complete${NC}"
    echo ""
fi

echo -e "${CYAN}Configuration:${NC}"
echo "  Station (CLI):     /tmp/geogram-alert-station (port 16000)"
echo "  Client A (GUI):    /tmp/geogram-alert-clientA (port 16100)"
echo ""

echo -e "${GREEN}Starting test suite...${NC}"
echo ""

# Track overall exit code
OVERALL_EXIT_CODE=0

# Run app alert test
echo -e "${CYAN}Running app alert tests...${NC}"
$DART_CMD run tests/app_alert_test.dart
APP_ALERT_EXIT=$?
if [ $APP_ALERT_EXIT -ne 0 ]; then
    OVERALL_EXIT_CODE=1
fi

# Run IRC bridge test
echo ""
echo -e "${CYAN}Running IRC bridge tests...${NC}"
$DART_CMD run tests/bridge-irc_test.dart
IRC_BRIDGE_EXIT=$?
if [ $IRC_BRIDGE_EXIT -ne 0 ]; then
    OVERALL_EXIT_CODE=1
fi

# Run blog app test
echo ""
echo -e "${CYAN}Running blog app tests...${NC}"
echo -e "${YELLOW}Note: This test requires internet connection (p2p.radio)${NC}"
$DART_CMD run tests/app_blog_test.dart
APP_BLOG_EXIT=$?
if [ $APP_BLOG_EXIT -ne 0 ]; then
    OVERALL_EXIT_CODE=1
fi

# Set final exit code
EXIT_CODE=$OVERALL_EXIT_CODE

echo ""
echo -e "${CYAN}Test Suite Summary:${NC}"
echo "  App Alert Tests:    $([ $APP_ALERT_EXIT -eq 0 ] && echo -e "${GREEN}PASSED${NC}" || echo -e "${RED}FAILED${NC}")"
echo "  IRC Bridge Tests:   $([ $IRC_BRIDGE_EXIT -eq 0 ] && echo -e "${GREEN}PASSED${NC}" || echo -e "${RED}FAILED${NC}")"
echo "  App Blog Tests:     $([ $APP_BLOG_EXIT -eq 0 ] && echo -e "${GREEN}PASSED${NC}" || echo -e "${RED}FAILED${NC}")"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}=============================================="
    echo "  All tests passed!"
    echo -e "==============================================${NC}"
else
    echo -e "${RED}=============================================="
    echo "  Some tests failed!"
    echo -e "==============================================${NC}"
    echo ""
    echo "Data directories preserved for inspection:"
    echo "  Station (CLI): /tmp/geogram-alert-station"
    echo "  Client A:      /tmp/geogram-alert-clientA"
    echo "  Blog Client:   /tmp/geogram-blog-client"
fi

exit $EXIT_CODE
