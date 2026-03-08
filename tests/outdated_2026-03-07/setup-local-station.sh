#!/bin/bash

# Setup local station as preferred in desktop app
# This adds ws://localhost:8080 to the station configuration

CONFIG_DIR="$HOME/.local/share/geogram_desktop"
CONFIG_FILE="$CONFIG_DIR/config.json"

echo "=================================================="
echo "  Setup Local Relay for Geogram Desktop"
echo "=================================================="
echo ""

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found. Please run the desktop app first."
    echo "Location: $CONFIG_FILE"
    exit 1
fi

echo "Adding local station to configuration..."
echo "URL: ws://localhost:8080"
echo "Name: Local Dev Relay"
echo ""

# Backup existing config
cp "$CONFIG_FILE" "$CONFIG_FILE.backup"
echo "Backed up config to: $CONFIG_FILE.backup"

# Note: The actual modification should be done through the app UI
# or by editing the JSON manually
echo ""
echo "To complete setup:"
echo "1. Start the desktop app"
echo "2. Go to 'Internet Relays' page"
echo "3. Click 'Add Relay' button"
echo "4. Enter:"
echo "   - Name: Local Dev Relay"
echo "   - URL: ws://localhost:8080"
echo "5. Click 'Set Preferred'"
echo "6. Click 'Test' to connect"
echo ""
echo "You should see hello messages in the app's log window!"
