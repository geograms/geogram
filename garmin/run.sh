#!/usr/bin/env bash
#
# Build the Geogram Garmin app and launch it in the simulator.
# Usage: ./run.sh [device]
#   device  — Connect IQ device target (default: fenix7pro)
#
set -euo pipefail
cd "$(dirname "$0")"

SDK="$HOME/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-8.4.1-2026-02-03-e9f77eeaa"
MONKEYC="$SDK/bin/monkeyc"
CONNECTIQ="$SDK/bin/connectiq"
MONKEYDO="$SDK/bin/monkeydo"

DEVICE="${1:-fenix7pro}"
KEY="developer_key.der"
OUT="bin/geogram.prg"

# Generate developer key if missing
if [ ! -f "$KEY" ]; then
    echo "Generating developer key..."
    openssl genrsa -out developer_key.pem 4096 2>/dev/null
    openssl pkcs8 -topk8 -inform PEM -outform DER \
        -in developer_key.pem -out "$KEY" -nocrypt
fi

mkdir -p bin

# Compile
echo "Building for $DEVICE..."
"$MONKEYC" -d "$DEVICE" -f monkey.jungle -o "$OUT" -y "$KEY" -w
echo "Build successful: $OUT"

# Start simulator if not already running
if ! pgrep -f "connectiq" > /dev/null 2>&1; then
    echo "Starting simulator..."
    "$CONNECTIQ" &
    sleep 3
fi

# Launch app in simulator
echo "Launching in simulator ($DEVICE)..."
"$MONKEYDO" "$OUT" "$DEVICE"
