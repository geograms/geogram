#!/bin/bash

# Geogram Web Launch Script
# This script sets up the Flutter environment and launches the web app
#
# Usage:
#   ./launch-web.sh          # Launch in Chrome
#   ./launch-web.sh server   # Launch web server on port 8080
#   ./launch-web.sh server 3000  # Launch web server on custom port

set -e

# Define Flutter path
FLUTTER_HOME="$HOME/flutter"
FLUTTER_BIN="$FLUTTER_HOME/bin/flutter"

# Check if Flutter is installed
if [ ! -f "$FLUTTER_BIN" ]; then
    echo "❌ Flutter not found at $FLUTTER_HOME"
    echo "Please install Flutter or update FLUTTER_HOME in this script"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Change to the geogram-desktop directory
cd "$SCRIPT_DIR"

echo "🚀 Launching Geogram Web..."
echo "📍 Working directory: $SCRIPT_DIR"
echo "🔧 Flutter version:"
"$FLUTTER_BIN" --version

echo ""

# Get dependencies - try offline first, fall back to online
echo "📦 Checking dependencies..."
if ! "$FLUTTER_BIN" pub get --offline 2>/dev/null; then
    echo "📡 Fetching dependencies online..."
    "$FLUTTER_BIN" pub get
fi

# Check for server mode
if [ "$1" = "server" ]; then
    PORT="${2:-8080}"

    # Kill any existing process on the port
    echo "🔍 Checking for existing processes on port $PORT..."
    if lsof -i :"$PORT" -t >/dev/null 2>&1; then
        echo "⚠️  Found process on port $PORT, killing it..."
        lsof -i :"$PORT" -t | xargs kill -9 2>/dev/null || true
        sleep 2
    fi

    # Also kill any flutter web-server processes
    pkill -f "flutter.*web-server" 2>/dev/null || true
    sleep 1

    echo "▶️  Starting web server on http://localhost:$PORT ..."
    echo ""
    "$FLUTTER_BIN" run -d web-server --web-port="$PORT" --web-hostname=0.0.0.0 --no-pub
else
    echo "▶️  Starting app in Chrome..."
    echo ""
    "$FLUTTER_BIN" run -d chrome --no-pub "$@"
fi
