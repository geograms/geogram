#!/bin/bash

# Geogram Android Launch Script
# This script sets up the Flutter environment and launches the Android app

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

echo "🚀 Launching Geogram on Android..."
echo "📍 Working directory: $SCRIPT_DIR"
echo "🔧 Flutter version:"
"$FLUTTER_BIN" --version

echo ""
echo "📱 Available Android devices:"
"$FLUTTER_BIN" devices | grep -E "android|TANK"

echo ""
echo "▶️  Starting app on Android device..."
echo ""

# Run the app on Android device (or emulator if specified)
"$FLUTTER_BIN" run -d android "$@"
