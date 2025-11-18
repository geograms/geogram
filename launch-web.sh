#!/bin/bash

# Geogram Web Launch Script
# This script sets up the Flutter environment and launches the web app

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
echo "▶️  Starting app in Chrome..."
echo ""

# Run the app in Chrome
"$FLUTTER_BIN" run -d chrome "$@"
