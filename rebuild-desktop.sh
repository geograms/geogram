#!/bin/bash

# Geogram Desktop Rebuild Script
# This script performs a clean rebuild of the desktop app

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

echo "🧹 Cleaning previous build..."
"$FLUTTER_BIN" clean

echo ""
echo "🔨 Building Linux desktop app..."
"$FLUTTER_BIN" build linux

echo ""
echo "✅ Build complete!"
echo ""
echo "To run the app, use:"
echo "  ./launch-desktop.sh"
