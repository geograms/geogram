#!/bin/bash

# Geogram Desktop Launch Script
# This script sets up the Flutter environment and launches the desktop app

set -e

# Define Flutter path
FLUTTER_HOME="$HOME/flutter"
FLUTTER_BIN="$FLUTTER_HOME/bin/flutter"

# Check if Flutter is installed
if [ ! -f "$FLUTTER_BIN" ]; then
    echo "❌ Flutter not found at $FLUTTER_HOME"
    echo "Please run ./install-flutter.sh to install Flutter"
    exit 1
fi

# Check Dart SDK version (must be >= 3.10.0 as required by pubspec.yaml)
DART_VERSION=$("$FLUTTER_BIN" --version 2>&1 | grep -oP 'Dart \K[0-9]+\.[0-9]+' | head -1)
DART_MAJOR=$(echo "$DART_VERSION" | cut -d. -f1)
DART_MINOR=$(echo "$DART_VERSION" | cut -d. -f2)

if [ "$DART_MAJOR" -lt 3 ] || ([ "$DART_MAJOR" -eq 3 ] && [ "$DART_MINOR" -lt 10 ]); then
    echo "❌ Dart version $DART_VERSION is too old"
    echo "This project requires Dart SDK ^3.10.0"
    echo "Please run ./install-flutter.sh to install the correct Flutter version (3.38.3+)"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Change to the geogram-desktop directory
cd "$SCRIPT_DIR"

echo "🚀 Launching Geogram Desktop..."
echo "📍 Working directory: $SCRIPT_DIR"
echo "🔧 Flutter version:"
"$FLUTTER_BIN" --version

echo ""
echo "🖥️  Available devices:"
"$FLUTTER_BIN" devices

echo ""
echo "▶️  Starting app on Linux desktop..."

# Kill any existing geogram_desktop processes to free up ports
if pgrep -f "geogram_desktop" > /dev/null 2>&1; then
    echo "🔄 Killing existing geogram_desktop processes..."
    pkill -f "geogram_desktop" 2>/dev/null || true
    sleep 1
fi

echo ""

# Run the app on Linux desktop
"$FLUTTER_BIN" run -d linux "$@"
