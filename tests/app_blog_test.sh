#!/bin/bash
# Geogram Blog App Test Wrapper
#
# Simple wrapper to run the blog test
#
# Usage:
#   ./tests/app_blog_test.sh
#
# Prerequisites:
#   - Build the app: flutter build linux --release
#   - Internet connection (to access p2p.radio)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}=============================================="
echo "  Geogram Blog App Test"
echo -e "==============================================${NC}"
echo ""

# Change to project directory
cd "$PROJECT_DIR"

# Find Dart
DART_CMD=""

if command -v dart &> /dev/null; then
    DART_CMD="dart"
elif command -v flutter &> /dev/null; then
    FLUTTER_ROOT=$(flutter --version --machine 2>/dev/null | grep -o '"flutterRoot":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "$FLUTTER_ROOT" ] && [ -f "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" ]; then
        DART_CMD="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
    fi
elif [ -f "$HOME/flutter/bin/cache/dart-sdk/bin/dart" ]; then
    DART_CMD="$HOME/flutter/bin/cache/dart-sdk/bin/dart"
fi

if [ -z "$DART_CMD" ]; then
    echo -e "${RED}Error: dart command not found${NC}"
    echo "Please ensure Flutter/Dart SDK is installed and in your PATH"
    exit 1
fi

echo -e "${CYAN}Using Dart: $DART_CMD${NC}"
echo ""

# Check if desktop build exists
GEOGRAM="$PROJECT_DIR/build/linux/x64/release/bundle/geogram_desktop"
if [ ! -f "$GEOGRAM" ]; then
    echo -e "${RED}Desktop build not found at: $GEOGRAM${NC}"
    echo "Please run: flutter build linux --release"
    exit 1
fi

echo -e "${GREEN}Starting blog test...${NC}"
echo ""

# Run the test
$DART_CMD run tests/app_blog_test.dart "$@"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=============================================="
    echo "  Blog test passed!"
    echo -e "==============================================${NC}"
else
    echo ""
    echo -e "${RED}=============================================="
    echo "  Blog test failed!"
    echo -e "==============================================${NC}"
fi

exit $EXIT_CODE
