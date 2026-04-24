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

# Change to the geogram directory
cd "$SCRIPT_DIR"

GRADLEW="$SCRIPT_DIR/android/gradlew"

echo "Launching Geogram on Android..."
echo "Working directory: $SCRIPT_DIR"

# ── Gradle daemon management ─────────────────────────────────────────
# Stop ALL running Gradle daemons so we don't accumulate 2GB processes.
# The build will start a single fresh daemon that gets reused on next run.
echo ""
echo "Managing Gradle daemons..."
DAEMON_COUNT=$(pgrep -f 'GradleDaemon' | wc -l)
if [ "$DAEMON_COUNT" -gt 1 ]; then
    echo "Found $DAEMON_COUNT Gradle daemons running — stopping extras..."
    "$GRADLEW" --stop 2>/dev/null || true
    sleep 1
elif [ "$DAEMON_COUNT" -eq 1 ]; then
    echo "Reusing existing Gradle daemon (PID $(pgrep -f 'GradleDaemon' | head -1))"
else
    echo "No Gradle daemon running — one will start with the build"
fi

# ── Clean up OOM heap dumps ──────────────────────────────────────────
HPROF_FILES=("$SCRIPT_DIR/android/"java_pid*.hprof)
if [ -f "${HPROF_FILES[0]}" ]; then
    HPROF_SIZE=$(du -sh "$SCRIPT_DIR/android/"java_pid*.hprof 2>/dev/null | tail -1 | awk '{print $1}')
    echo "Cleaning up old heap dump files (${HPROF_SIZE})..."
    rm -f "$SCRIPT_DIR/android/"java_pid*.hprof
fi

# ── Offline mode ─────────────────────────────────────────────────────
# Avoid downloading dependencies on every build. If Gradle caches exist,
# build in offline mode. Pass --online flag to force online resolution.
if [ "${1:-}" = "--online" ]; then
    echo "Online mode forced — will resolve dependencies from network"
    export GRADLE_OFFLINE="false"
    shift
else
    if [ -d "$HOME/.gradle/caches/modules-2/files-2.1" ]; then
        echo "Gradle dependency cache found — building OFFLINE (use --online to override)"
        export GRADLE_OFFLINE="true"
    else
        echo "No Gradle cache found — must download dependencies (first build)"
        export GRADLE_OFFLINE="false"
    fi
fi

# ── ADB setup ────────────────────────────────────────────────────────
# Restart ADB server to ensure clean state (prevents memory/hang issues)
echo ""
echo "Restarting ADB server..."
"$ADB" kill-server 2>/dev/null || true
sleep 1
"$ADB" start-server
# Give adb a moment to enumerate USB devices after daemon start
sleep 2

# Check device status
echo ""
echo "Checking connected devices..."
# `|| true` so grep's empty match (no devices) doesn't trip `set -e`
DEVICE_LINES=$("$ADB" devices | tail -n +2 | grep -v "^$" || true)

if [ -z "$DEVICE_LINES" ]; then
    echo "No Android device connected!"
    echo "Please connect your device and enable USB debugging"
    exit 1
fi

# Collect all valid device IDs
DEVICE_IDS=()
while IFS= read -r line; do
    if [ -z "$line" ]; then
        continue
    fi

    DEVICE_ID=$(echo "$line" | awk '{print $1}')
    DEVICE_STATE=$(echo "$line" | awk '{print $2}')

    if [ "$DEVICE_STATE" = "unauthorized" ]; then
        echo "Device $DEVICE_ID is unauthorized - skipping"
        echo "  Please accept the USB debugging prompt on this device"
        continue
    fi

    if [ "$DEVICE_STATE" = "offline" ]; then
        echo "Device $DEVICE_ID is offline. Attempting to reconnect..."
        "$ADB" -s "$DEVICE_ID" reconnect
        sleep 2
        # Re-check status
        DEVICE_STATE=$("$ADB" devices | grep "^$DEVICE_ID" | awk '{print $2}')
        if [ "$DEVICE_STATE" != "device" ]; then
            echo "Device $DEVICE_ID still offline - skipping"
            continue
        fi
    fi

    if [ "$DEVICE_STATE" = "device" ]; then
        DEVICE_IDS+=("$DEVICE_ID")
        echo "Device found: $DEVICE_ID"
    fi
done <<< "$DEVICE_LINES"

if [ ${#DEVICE_IDS[@]} -eq 0 ]; then
    echo "No valid Android devices available!"
    exit 1
fi

echo ""
echo "Found ${#DEVICE_IDS[@]} device(s) ready for installation"

echo ""
echo "Flutter version:"
"$FLUTTER_BIN" --version

# ── Dependencies ─────────────────────────────────────────────────────
# Try offline first to avoid network access; fall back to online only if needed
echo ""
echo "Checking dependencies..."
if ! "$FLUTTER_BIN" pub get --offline 2>/dev/null; then
    echo "Offline pub get failed — fetching dependencies online..."
    "$FLUTTER_BIN" pub get
fi

# ── Build ────────────────────────────────────────────────────────────
# Build the APK once (debug build to enable run-as for android-sync.sh)
# --no-pub: skip pub get (already done above)
# GRADLE_OFFLINE env var is read by settings.gradle.kts to set offline mode
echo ""
if [ "$GRADLE_OFFLINE" = "true" ]; then
    echo "Building APK (offline — no dependency downloads)..."
else
    echo "Building APK..."
fi

# ── Resource throttling ─────────────────────────────────────────────
# Even with gradle.properties caps (org.gradle.workers.max=4,
# kotlin.daemon.jvmargs=-Xmx1536m, -XX:ActiveProcessorCount=4), a fresh
# build can still saturate CPU/IO and make the desktop unresponsive.
# Run gradle/flutter at the lowest CPU priority and in the idle I/O class
# so the interactive session keeps a clear line to the kernel. Override
# by setting GEOGRAM_NICE=0 before running this script.
NICE_CMD=()
if [ "${GEOGRAM_NICE:-1}" != "0" ]; then
    NICE_CMD+=("nice" "-n" "19")
    if command -v ionice >/dev/null 2>&1; then
        NICE_CMD+=("ionice" "-c" "3")
    fi
fi

"${NICE_CMD[@]}" "$FLUTTER_BIN" build apk --debug --no-pub

APK_PATH="$SCRIPT_DIR/build/app/outputs/flutter-apk/app-debug.apk"

if [ ! -f "$APK_PATH" ]; then
    echo "APK not found at $APK_PATH"
    exit 1
fi

echo ""
echo "Installing on all devices..."

# Install on each device.
# `adb install` is unreliable for large debug APKs (~500MB) — it can hang
# indefinitely with no output. Instead: push the APK to the device first
# (fast over USB) and then run `pm install` directly. Preserves user data
# via -r (replace) and -d (allow downgrade).
APK_SIZE_MB=$(du -m "$APK_PATH" | awk '{print $1}')
echo "APK size: ${APK_SIZE_MB} MB"

FAILED_DEVICES=()
for DEVICE_ID in "${DEVICE_IDS[@]}"; do
    echo ""
    echo "Installing on $DEVICE_ID..."
    REMOTE_APK="/data/local/tmp/geogram.apk"

    echo "  [1/2] Pushing APK to device..."
    if ! "$ADB" -s "$DEVICE_ID" push "$APK_PATH" "$REMOTE_APK"; then
        echo "  Failed to push APK to $DEVICE_ID"
        FAILED_DEVICES+=("$DEVICE_ID")
        continue
    fi

    echo "  [2/2] Running pm install on device..."
    if "$ADB" -s "$DEVICE_ID" shell "pm install -r -d $REMOTE_APK"; then
        echo "Successfully installed on $DEVICE_ID"
    else
        echo "Failed to install on $DEVICE_ID"
        FAILED_DEVICES+=("$DEVICE_ID")
    fi

    # Clean up tmp APK on device
    "$ADB" -s "$DEVICE_ID" shell "rm -f $REMOTE_APK" 2>/dev/null || true
done

echo ""
echo "Launching app on all devices..."

# Launch app on each device
for DEVICE_ID in "${DEVICE_IDS[@]}"; do
    echo "Launching on $DEVICE_ID..."
    "$ADB" -s "$DEVICE_ID" shell am start -n dev.geogram/.MainActivity
done

echo ""
echo "========================================"
echo "Installation complete!"
echo "Installed on ${#DEVICE_IDS[@]} device(s)"
if [ ${#FAILED_DEVICES[@]} -gt 0 ]; then
    echo "Failed on ${#FAILED_DEVICES[@]} device(s): ${FAILED_DEVICES[*]}"
fi
echo "========================================"
