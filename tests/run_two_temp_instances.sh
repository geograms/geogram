#!/bin/bash
# Run Two Temporary Geogram Instances
#
# This script launches two temporary Geogram instances with auto-generated
# identities for testing device-to-device communication.
#
# Features:
# - Creates fresh temp directories on each run
# - Uses different ports to avoid conflicts
# - Skips intro screens for immediate use
# - Keeps directories available after script ends
# - Sets instance names via --nickname
#
# Usage:
#   ./run_two_temp_instances.sh          # Run with defaults
#   ./run_two_temp_instances.sh --help   # Show help
#
# Default ports:
#   Instance A: 5577
#   Instance B: 5588
#
# Default temp directories:
#   /tmp/geogram-A-5577
#   /tmp/geogram-B-5588

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default configuration
PORT_A=5577
PORT_B=5588
TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"
NICKNAME_A="Instance-A"
NICKNAME_B="Instance-B"
SKIP_BUILD=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Show help
show_help() {
    echo "Run Two Temporary Geogram Instances"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --port-a=PORT     Port for Instance A (default: $PORT_A)"
    echo "  --port-b=PORT     Port for Instance B (default: $PORT_B)"
    echo "  --name-a=NAME     Nickname for Instance A (default: $NICKNAME_A)"
    echo "  --name-b=NAME     Nickname for Instance B (default: $NICKNAME_B)"
    echo "  --skip-build      Skip rebuilding the app (use existing binary)"
    echo "  --help            Show this help message"
    echo ""
    echo "Temp directories:"
    echo "  Instance A: /tmp/geogram-A-{PORT_A}"
    echo "  Instance B: /tmp/geogram-B-{PORT_B}"
    echo ""
    echo "Examples:"
    echo "  $0                              # Build latest code and use defaults"
    echo "  $0 --skip-build                 # Use existing binary without rebuilding"
    echo "  $0 --port-a=6000 --port-b=6001  # Custom ports"
    echo "  $0 --name-a=Alice --name-b=Bob  # Custom names"
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port-a=*)
            PORT_A="${1#*=}"
            TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
            shift
            ;;
        --port-b=*)
            PORT_B="${1#*=}"
            TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"
            shift
            ;;
        --name-a=*)
            NICKNAME_A="${1#*=}"
            shift
            ;;
        --name-b=*)
            NICKNAME_B="${1#*=}"
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "=============================================="
echo "Run Two Temporary Geogram Instances"
echo "=============================================="
echo ""

# Find flutter command
FLUTTER_CMD=""
if command -v flutter &> /dev/null; then
    FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/flutter/bin/flutter"
else
    echo -e "${RED}Error: flutter not found${NC}"
    echo "Please install Flutter or add it to your PATH"
    exit 1
fi

# Build the app with latest code
BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ "$SKIP_BUILD" = true ]; then
    echo -e "${YELLOW}Skipping build (using existing binary)...${NC}"
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}✗ Error: Binary not found at $BINARY_PATH${NC}"
        echo -e "${YELLOW}Run without --skip-build to build the app${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Using existing binary${NC}"
else
    echo -e "${YELLOW}Building Geogram with latest code...${NC}"
    cd "$PROJECT_DIR"
    $FLUTTER_CMD build linux --release
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Build complete${NC}"
    else
        echo -e "${RED}✗ Build failed${NC}"
        exit 1
    fi
fi
echo ""

# Clean up and create fresh temp directories
echo -e "${BLUE}Preparing temp directories...${NC}"

if [ -d "$TEMP_DIR_A" ]; then
    echo "  Removing existing: $TEMP_DIR_A"
    rm -rf "$TEMP_DIR_A"
fi
mkdir -p "$TEMP_DIR_A"
echo "  Created: $TEMP_DIR_A"

if [ -d "$TEMP_DIR_B" ]; then
    echo "  Removing existing: $TEMP_DIR_B"
    rm -rf "$TEMP_DIR_B"
fi
mkdir -p "$TEMP_DIR_B"
echo "  Created: $TEMP_DIR_B"

# Calculate scan range that includes both ports
SCAN_START=$((PORT_A < PORT_B ? PORT_A : PORT_B))
SCAN_END=$((PORT_A > PORT_B ? PORT_A : PORT_B))
SCAN_RANGE="${SCAN_START}-${SCAN_END}"

echo ""
echo -e "${CYAN}Configuration:${NC}"
echo "  Instance A: port=$PORT_A, dir=$TEMP_DIR_A, name=$NICKNAME_A"
echo "  Instance B: port=$PORT_B, dir=$TEMP_DIR_B, name=$NICKNAME_B"
echo "  Localhost scan range: $SCAN_RANGE"
echo ""

# Launch Instance A
echo -e "${YELLOW}Starting Instance A ($NICKNAME_A) on port $PORT_A...${NC}"
"$BINARY_PATH" \
    --port=$PORT_A \
    --data-dir="$TEMP_DIR_A" \
    --new-identity \
    --nickname="$NICKNAME_A" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=$SCAN_RANGE \
    &
PID_A=$!
echo "  PID: $PID_A"

# Launch Instance B
echo -e "${YELLOW}Starting Instance B ($NICKNAME_B) on port $PORT_B...${NC}"
"$BINARY_PATH" \
    --port=$PORT_B \
    --data-dir="$TEMP_DIR_B" \
    --new-identity \
    --nickname="$NICKNAME_B" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=$SCAN_RANGE \
    &
PID_B=$!
echo "  PID: $PID_B"

echo ""
echo -e "${GREEN}Both instances started!${NC}"
echo ""
echo "=============================================="
echo "Instance Information"
echo "=============================================="
echo ""
echo -e "${CYAN}Instance A ($NICKNAME_A):${NC}"
echo "  API: http://localhost:$PORT_A/api/status"
echo "  Data: $TEMP_DIR_A"
echo "  PID: $PID_A"
echo ""
echo -e "${CYAN}Instance B ($NICKNAME_B):${NC}"
echo "  API: http://localhost:$PORT_B/api/status"
echo "  Data: $TEMP_DIR_B"
echo "  PID: $PID_B"
echo ""
echo "=============================================="
echo "Useful Commands"
echo "=============================================="
echo ""
echo "# Check status:"
echo "  curl http://localhost:$PORT_A/api/status"
echo "  curl http://localhost:$PORT_B/api/status"
echo ""
echo "# Stop instances:"
echo "  kill $PID_A $PID_B"
echo ""
echo "# Clean up temp directories:"
echo "  rm -rf $TEMP_DIR_A $TEMP_DIR_B"
echo ""
echo -e "${YELLOW}Note: Temp directories are kept after script ends.${NC}"
echo -e "${YELLOW}Press Ctrl+C to exit (instances will keep running).${NC}"
echo ""

# Wait for user interrupt
wait
