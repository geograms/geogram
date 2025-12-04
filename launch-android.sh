#!/bin/bash

# Geogram Android Launch Script
# This script sets up the Flutter environment and launches the Android app

set -e

# Define Flutter path
FLUTTER_HOME="$HOME/flutter"
FLUTTER_BIN="$FLUTTER_HOME/bin/flutter"

# Define Android SDK paths
ANDROID_SDK="$HOME/Android/Sdk"
ADB="$ANDROID_SDK/platform-tools/adb"

# Check if Flutter is installed
if [ ! -f "$FLUTTER_BIN" ]; then
    echo "Flutter not found at $FLUTTER_HOME"
    echo "Please install Flutter or update FLUTTER_HOME in this script"
    exit 1
fi

# Check if ADB is available
if [ ! -f "$ADB" ]; then
    echo "ADB not found at $ADB"
    echo "Please install Android SDK or update ANDROID_SDK in this script"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Change to the geogram-desktop directory
cd "$SCRIPT_DIR"

echo "Launching Geogram on Android..."
echo "Working directory: $SCRIPT_DIR"

# Restart ADB server to ensure clean state (prevents memory/hang issues)
echo ""
echo "Restarting ADB server..."
"$ADB" kill-server 2>/dev/null || true
sleep 1
"$ADB" start-server

# Check device status
echo ""
echo "Checking connected devices..."
DEVICE_STATUS=$("$ADB" devices | tail -n +2 | grep -v "^$" | head -1)

if [ -z "$DEVICE_STATUS" ]; then
    echo "No Android device connected!"
    echo "Please connect your device and enable USB debugging"
    exit 1
fi

if echo "$DEVICE_STATUS" | grep -q "unauthorized"; then
    echo "Device is unauthorized!"
    echo "Please accept the USB debugging prompt on your device"
    echo "Then run this script again"
    exit 1
fi

if echo "$DEVICE_STATUS" | grep -q "offline"; then
    echo "Device is offline. Attempting to reconnect..."
    "$ADB" reconnect
    sleep 2
fi

# Extract device ID from status
DEVICE_ID=$(echo "$DEVICE_STATUS" | awk '{print $1}')
echo "Device found: $DEVICE_ID"

echo ""
echo "Flutter version:"
"$FLUTTER_BIN" --version

echo ""
echo "Available Android devices:"
"$FLUTTER_BIN" devices | grep -E "android|TANK|arm64" || echo "No Android devices detected by Flutter"

echo ""
echo "Starting app on Android device ($DEVICE_ID)..."
echo ""

# Run the app on the specific Android device
"$FLUTTER_BIN" run -d "$DEVICE_ID" "$@"
