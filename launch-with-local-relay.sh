#!/bin/bash

# Launch Geogram Desktop with Local Relay for testing
# This script starts both the relay server and desktop app

set -e

# Try to add Flutter to PATH if not already available
if ! command -v flutter &> /dev/null; then
    # Check common Flutter installation locations
    if [ -d "$HOME/flutter/bin" ]; then
        export PATH="$PATH:$HOME/flutter/bin"
    elif [ -d "/opt/flutter/bin" ]; then
        export PATH="$PATH:/opt/flutter/bin"
    elif [ -d "/usr/local/flutter/bin" ]; then
        export PATH="$PATH:/usr/local/flutter/bin"
    fi
fi

echo "=================================================="
echo "  Geogram Desktop + Local Relay Development"
echo "=================================================="
echo ""

# Determine script directory and derive paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$SCRIPT_DIR"
RELAY_DIR="$(dirname "$SCRIPT_DIR")/geogram-relay"

# Check if relay exists
if [ ! -d "$RELAY_DIR" ]; then
    echo "Error: Relay directory not found at $RELAY_DIR"
    exit 1
fi

# Build relay (always rebuild to ensure latest code)
echo "[1/3] Building relay..."
cd "$RELAY_DIR"

# Check if source is newer than JAR
NEEDS_BUILD=false
if [ ! -f "target/geogram-relay-1.0.0.jar" ]; then
    NEEDS_BUILD=true
    echo "  JAR not found, need to build"
else
    # Check if any Java source files are newer than the JAR
    NEWEST_SOURCE=$(find src -name "*.java" -type f -newer target/geogram-relay-1.0.0.jar 2>/dev/null | head -1)
    if [ ! -z "$NEWEST_SOURCE" ]; then
        NEEDS_BUILD=true
        echo "  Source files changed, need to rebuild"
    fi
fi

if [ "$NEEDS_BUILD" = true ]; then
    echo "  Running: mvn clean package"
    mvn clean package -q
    if [ $? -ne 0 ]; then
        echo "  ✗ Relay build failed!"
        exit 1
    fi
    echo "✓ Relay built successfully"
else
    echo "✓ Relay already up to date"
fi

# Check if relay is already running on port 8080
echo ""
echo "[2/3] Starting local relay..."
echo "URL: ws://localhost:8080"

# Kill all existing relay processes with multiple methods
echo "  Checking for existing relay processes..."

# Method 1: Kill by port 8080
EXISTING_PIDS=$(lsof -ti:8080 2>/dev/null || true)
if [ ! -z "$EXISTING_PIDS" ]; then
    echo "  Found process(es) on port 8080: $EXISTING_PIDS"
    for PID in $EXISTING_PIDS; do
        echo "    Killing PID $PID..."
        kill -9 $PID 2>/dev/null || true
    done
fi

# Method 2: Kill by process name pattern
RELAY_PIDS=$(pgrep -f "geogram-relay.*\.jar" || true)
if [ ! -z "$RELAY_PIDS" ]; then
    echo "  Found relay process(es): $RELAY_PIDS"
    for PID in $RELAY_PIDS; do
        echo "    Killing PID $PID..."
        kill -9 $PID 2>/dev/null || true
    done
fi

# Method 3: Fallback - pkill
pkill -9 -f "geogram-relay" 2>/dev/null || true

# Wait a moment for processes to die
sleep 2

# Verify port 8080 is free
if lsof -ti:8080 >/dev/null 2>&1; then
    echo "  ✗ ERROR: Port 8080 is still in use!"
    echo "  Please manually stop the process:"
    lsof -ti:8080 | xargs ps -fp
    exit 1
fi

echo "  ✓ All relay processes stopped, port 8080 is free"

cd "$RELAY_DIR"
java -jar target/geogram-relay-1.0.0.jar > /tmp/geogram-relay.log 2>&1 &
RELAY_PID=$!
echo "✓ Relay started (PID: $RELAY_PID)"
echo "  Log: tail -f /tmp/geogram-relay.log"

# Wait for relay to start
echo "  Waiting for relay to initialize..."
sleep 3

# Check if relay is still running
if ! kill -0 $RELAY_PID 2>/dev/null; then
    echo "✗ Relay failed to start. Check log:"
    tail -20 /tmp/geogram-relay.log
    exit 1
fi

echo "✓ Relay is running"

# Build desktop if needed
echo ""
echo "[3/3] Starting desktop app..."
cd "$DESKTOP_DIR"

# Get Flutter packages - try offline first, fall back to online
echo "Checking dependencies..."
if ! flutter pub get --offline 2>/dev/null; then
    echo "Fetching dependencies online..."
    flutter pub get
fi

# Check if flutter is available
if ! command -v flutter &> /dev/null; then
    echo "Error: Flutter not found in PATH"
    echo ""
    echo "Please ensure Flutter is installed and in your PATH."
    echo "You can add it to your PATH by adding this to ~/.bashrc or ~/.zshrc:"
    echo "  export PATH=\"\$PATH:\$HOME/flutter/bin\""
    echo ""
    echo "Or run Flutter manually:"
    echo "  cd $DESKTOP_DIR"
    echo "  /path/to/flutter/bin/flutter run -d linux"
    echo ""
    echo "The relay is still running at ws://localhost:8080 (PID: $RELAY_PID)"
    echo "To stop it: kill $RELAY_PID"
    exit 1
fi

# Launch desktop app
echo "✓ Launching Geogram Desktop"
echo ""
echo "=================================================="
echo "  Setup Instructions"
echo "=================================================="
echo ""
echo "1. Desktop app will open shortly"
echo "2. Go to 'Internet Relays' page"
echo "3. Click '+ Add Relay' button"
echo "4. Enter:"
echo "   - Name: Local Dev Relay"
echo "   - URL: ws://localhost:8080"
echo "5. Click 'Add'"
echo "6. Click 'Set Preferred'"
echo "7. Click 'Test' to connect"
echo ""
echo "Watch the log window for hello messages!"
echo ""
echo "=================================================="
echo "  Running Services"
echo "=================================================="
echo ""
echo "Relay:   ws://localhost:8080 (PID: $RELAY_PID)"
echo "Logs:    tail -f /tmp/geogram-relay.log"
echo ""
echo "Press Ctrl+C to stop both services"
echo "=================================================="
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Stopping services..."
    if kill -0 $RELAY_PID 2>/dev/null; then
        kill $RELAY_PID
        echo "✓ Relay stopped"
    fi
    exit 0
}

trap cleanup EXIT INT TERM

# Launch desktop app (this will block until app exits)
# --no-pub skips pub get since we already ran it above
flutter run -d linux --no-pub

# Cleanup will happen automatically via trap
